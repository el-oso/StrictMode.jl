# Concurrency-safety guarantees — the multi-threading correctness layer.
#
# All value-free (`Base.code_typed` IR scans), like `trimsafe`/`scheduling`/`inlining`: no
# AllocCheck/JET backend needed, works in `:fast` and `:full` alike.
#
# ── `:concurrency_safe` (PRIORITY) ────────────────────────────────────────────────────────────
# Contract (PureFFT MT Phase 1):
#     @assert_concurrency_safe apply_unnormalized!(plan, x, alloc_scratch(plan))
# Asserts the callee treats its *plan* argument (the first arg by default) as READ-ONLY during
# apply: it writes no field of the plan, and mutates no state reachable *only through* the plan.
# The other args (`x`, the passed scratch) are the mutable outputs — writing them is fine. If the
# plan is immutable during apply, one plan can be shared across concurrent tasks without a race.
#
# DESIGN — forward reference-taint over the optimized IR (sound-for-common-cases, documented):
#   * Seed taint on the plan argument. Propagate taint through *projections* that derive a
#     shared reference from a tainted value — `getfield` / `memoryref(new|get)` / `arrayref` /
#     `getindex` / `Pi`/`Phi` / `tuple`/`ifelse` — BUT ONLY when the result may alias mutable
#     heap state (`!isbitstype`). Reading `plan.n::Int` yields a *copy* (isbits) → not tainted, so
#     arithmetic on it never trips the check; reading `plan.scratch::Buf` yields a *shared*
#     reference → tainted. This scalar-vs-reference distinction is what makes it precise.
#   * FLAG a store (`setfield!` / `memoryrefset!` / `arrayset` / `unsafe_store!` / `setindex!`)
#     whose CONTAINER operand is tainted. This catches the shallow case (`setfield!` on the plan)
#     AND the real composite race: a store into `plan.children[i].scratch.data` — a heap store
#     reachable from the plan through a getfield/memoryref chain, which a naive "no setfield! on
#     self" scan misses.
#   * INTERPROCEDURAL (the load-bearing part): when a tainted (plan-reachable) value is passed to
#     a call, follow it. A user (`:invoke`) callee is scanned recursively with the taint mapped to
#     its parameters (bounded depth, memoised) — so a plan that accidentally calls a child's
#     *convenience/embedded-scratch path* (`child_apply!(child_plan)` that writes
#     `child_plan.default_scratch.data`) is caught even though the store is one frame down. A
#     tainted value handed to a *known Base mutator* (`push!`/`resize!`/`copyto!`/…) is flagged; a
#     tainted value handed to an *unresolved dynamic dispatch* is flagged (prefer a false positive
#     over a confident false pass).
#
# WHAT IT CANNOT CATCH (honest limits — PureFFT's runtime concurrency test is the load-bearing
# backstop; this static proof is complementary):
#   * ALIASING: if the mutable output (`x`/scratch) is the *same* buffer the plan also references,
#     writing "x" is really writing the plan. No alias analysis is done — a caller passing
#     `alloc_scratch(plan)` (a fresh buffer) is fine; deliberately aliasing plan-owned storage is
#     not detected.
#   * Base/Core mutation is caught only for a KNOWN set of mutating functions; a plan-reachable
#     buffer mutated by some other non-inlined Base method is out of scope.
#   * Recursion is depth-bounded (`max_depth`, default 4); beyond it a still-tainted call is
#     flagged conservatively rather than followed.
#   * `foreigncall`/`llvmcall` stores (e.g. raw `memmove` into a tainted pointer) are not modelled
#     (modern Julia lowers array writes to `memoryrefset!`, which IS modelled).
#   * Taint does not flow through the *return value* of an opaque (Base/Core/unresolved) call.

# ── taint primitives ──────────────────────────────────────────────────────────────────────────

@inline _op_tainted(@nospecialize(op), tset::BitSet, targs) =
    op isa Core.SSAValue ? (op.id in tset) :
    op isa Core.Argument ? (op.n in targs) : false

_widen_taint(@nospecialize(T)) =
    T isa Core.Const ? Core.Typeof(T.val) :
    (T isa Core.PartialStruct ? T.typ : T)

# A value MAY alias mutable heap state unless it is a plain bits value (a copy). Conservative
# (ref = true) for anything not resolved to a concrete `Type`.
function _may_ref(@nospecialize(T))
    W = _widen_taint(T)
    return W isa Type ? !isbitstype(W) : true
end

# Callee name symbol from a `:call`/`:invoke` callee slot.
function _callee_name(@nospecialize(x))
    x isa GlobalRef && return x.name
    x isa Core.IntrinsicFunction && return nameof(x)
    x isa Function && return nameof(x)
    return nothing
end

# Callee name in UNOPTIMIZED IR, where a call is `(%k)(args...)` with `%k` an SSA holding a
# `GlobalRef`. Resolve one SSA hop back to the name. (Optimized IR uses direct GlobalRefs, so the
# `:concurrency_safe` scan doesn't need this; the source-pattern Phase-2 lints do.)
function _resolve_callee_name(@nospecialize(callee), code)
    callee isa Core.SSAValue || return _callee_name(callee)
    0 < callee.id <= length(code) || return nothing
    stmt = code[callee.id]
    stmt isa Core.SSAValue && return nothing   # avoid chains/cycles; one hop is enough here
    return _callee_name(stmt)
end

function _invoke_mi(@nospecialize(a1))
    mi = a1 isa Core.CodeInstance ? a1.def : a1
    return mi isa Core.MethodInstance ? mi : nothing
end

# Typed IR for an `:invoke` target's MethodInstance (via its concrete singleton + arg types).
function _mi_codeinfo(mi::Core.MethodInstance)
    params = (mi.specTypes::DataType).parameters
    (isempty(params) || !isdefined(params[1], :instance)) && return nothing
    f = params[1].instance
    argts = Tuple(params[2:end])
    cts = try
        Base.code_typed(f, argts; optimize = true)
    catch
        return nothing
    end
    return isempty(cts) ? nothing : cts[1].first
end

# Container-operand position (1-based among the call's DATA args, i.e. after the callee).
const _PROJECT_OPS = Dict(
    :getfield => 1, :getproperty => 1, :memoryrefget => 1, :memoryrefnew => 1,
    :memoryref => 1, :pointerref => 1, :unsafe_load => 1, :getindex => 1, :arrayref => 2,
)
const _STORE_OPS = Dict(
    :setfield! => 1, :setproperty! => 1, :memoryrefset! => 1, :memoryset! => 1,
    :unsafe_store! => 1, :pointerset => 1, :setindex! => 1, :arrayset => 2,
)
const _CARRY_OPS = Set{Symbol}((:tuple, :ifelse))   # value-carrying: taint result if any operand tainted
const _BASE_MUTATORS = Set{Symbol}(
    (
        :push!, :pushfirst!, :append!, :prepend!, :resize!, :sizehint!, :empty!, :deleteat!, :insert!,
        :splice!, :copyto!, :copy!, :unsafe_copyto!, :fill!, :map!, :_growend!, :_growbeg!,
        :_deleteend!, :_deletebeg!,
    )
)

struct _ConcViol
    message::String
    file::String
    line::Int
end

# ── the scan ──────────────────────────────────────────────────────────────────────────────────

struct _Frame
    name::String
    file::String
    line::Int
end

function _record!(out::Vector{_ConcViol}, seen::Set{String}, chain::Vector{String}, msg::String, fr::_Frame)
    full = isempty(chain) ? msg : msg * " (reached via " * join(chain, " → ") * ")"
    key = full * "@" * fr.file * ":" * string(fr.line)
    key in seen && return nothing
    push!(seen, key)
    push!(out, _ConcViol(full, fr.file, fr.line))
    return nothing
end

# Scan one CodeInfo. `targs` = tainted argument slots (Core.Argument `.n` values). Returns whether
# the method may RETURN a plan-reachable reference (so the caller can keep tainting).
function _taint_scan_ci(
        ci, targs::Set{Int}, chain::Vector{String}, fr::_Frame, depth::Int, max_depth::Int,
        memo::Dict{Any, Bool}, out::Vector{_ConcViol}, seen::Set{String},
    )
    code = ci.code
    types = ci.ssavaluetypes
    n = length(code)
    tset = BitSet()
    returns_tainted = false
    changed = true
    passes = 0
    while changed && passes <= n + 2
        changed = false
        passes += 1
        for (i, st) in enumerate(code)
            settaint(b) = (b && !(i in tset)) ? (push!(tset, i); changed = true; true) : false

            if st isa Core.PiNode
                isdefined(st, :val) && _op_tainted(st.val, tset, targs) && settaint(true)
                continue
            elseif st isa Core.PhiNode || st isa Core.PhiCNode
                any(v -> _op_tainted(v, tset, targs), st.values) && settaint(true)
                continue
            elseif st isa Core.UpsilonNode
                isdefined(st, :val) && _op_tainted(st.val, tset, targs) && settaint(true)
                continue
            elseif st isa Core.ReturnNode
                isdefined(st, :val) && _op_tainted(st.val, tset, targs) && (returns_tainted = true)
                continue
            end

            (Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke)) || continue
            isinvoke = st.head === :invoke
            callee = isinvoke ? st.args[2] : st.args[1]
            dataargs = isinvoke ? st.args[3:end] : st.args[2:end]
            nm = _callee_name(callee)

            # store into a tainted container → violation
            if nm !== nothing && haskey(_STORE_OPS, nm)
                pos = _STORE_OPS[nm]
                if 1 <= pos <= length(dataargs) && _op_tainted(dataargs[pos], tset, targs)
                    _record!(out, seen, chain, _store_msg(nm, isinvoke, dataargs, targs), fr)
                end
                continue
            end

            # projection: derive a (maybe-shared) reference
            if nm !== nothing && haskey(_PROJECT_OPS, nm)
                pos = _PROJECT_OPS[nm]
                if 1 <= pos <= length(dataargs) && _op_tainted(dataargs[pos], tset, targs)
                    # a memoryref is a *writable handle* into its buffer — always a live reference
                    isref = (nm === :memoryrefnew || nm === :memoryref) ? true : _may_ref(types[i])
                    settaint(isref)
                end
                continue
            end

            # value-carrying op (tuple/ifelse): result may carry the reference forward
            if nm !== nothing && nm in _CARRY_OPS
                any(a -> _op_tainted(a, tset, targs), dataargs) && settaint(true)
                continue
            end

            # a plain call that receives a tainted (plan-reachable) reference: follow it
            tainted_pos = Int[k for k in eachindex(dataargs) if _op_tainted(dataargs[k], tset, targs)]
            isempty(tainted_pos) && continue

            if isinvoke
                mi = _invoke_mi(st.args[1])
                m = mi === nothing ? nothing : mi.def
                if m isa Method && !_is_base_core(m.module)
                    rt = _recurse(mi, m, tainted_pos, chain, depth, max_depth, memo, out, seen)
                    settaint(rt && _may_ref(types[i]))
                elseif nm !== nothing && nm in _BASE_MUTATORS
                    _record!(out, seen, chain, "hands a plan-reachable value to `$nm`, a mutating operation", fr)
                end
                # other Base/Core invokes (reads, `throw_boundserror`, …) are treated as non-mutating
                continue
            else
                # dynamic `:call`
                if nm !== nothing && nm in _BASE_MUTATORS
                    _record!(out, seen, chain, "hands a plan-reachable value to `$nm`, a mutating operation", fr)
                elseif callee isa GlobalRef && _is_base_core(callee.mod)
                    # a Base/Core intrinsic/read (getfield-family handled above) — non-mutating
                else
                    tgt = nm === nothing ? "an unresolved callee" : "`$nm`"
                    _record!(
                        out, seen, chain,
                        "hands a plan-reachable value to $tgt via dynamic dispatch — StrictMode cannot " *
                            "prove it treats the plan as read-only (flagged conservatively)", fr
                    )
                end
                continue
            end
        end
    end
    return returns_tainted
end

function _store_msg(nm::Symbol, isinvoke::Bool, dataargs, targs)
    if nm === :setfield!
        # setfield!(obj, field, val): name the field when it's a literal
        fld = length(dataargs) >= 2 ? dataargs[2] : nothing
        fld isa QuoteNode && (fld = fld.value)
        selfarg = length(dataargs) >= 1 && dataargs[1] isa Core.Argument
        where = selfarg ? "the plan argument directly" : "a value reachable from the plan"
        return "writes field `$(fld === nothing ? "?" : fld)` of $where (`setfield!`) — the plan is mutated during apply"
    end
    return "stores into a buffer reachable from the plan (`$nm`) — a heap write the plan can observe"
end

function _recurse(
        mi::Core.MethodInstance, m::Method, tainted_pos::Vector{Int}, chain::Vector{String},
        depth::Int, max_depth::Int, memo::Dict{Any, Bool}, out::Vector{_ConcViol}, seen::Set{String},
    )
    key = (mi, sort(tainted_pos))
    haskey(memo, key) && return memo[key]
    label = string(m.name)
    if depth >= max_depth
        _record!(
            out, seen, chain,
            "hands a plan-reachable value to `$label` at recursion depth $depth (≥ max_depth=$max_depth) — " *
                "not followed; flagged conservatively", _Frame(label, string(m.file), Int(m.line))
        )
        memo[key] = false
        return false
    end
    memo[key] = false   # cycle guard: assume non-tainting return until proven
    ci = _mi_codeinfo(mi)
    ci === nothing && return false
    # user param k (1-based) ↔ Core.Argument(k+1)
    callee_targs = Set{Int}(p + 1 for p in tainted_pos)
    fr = _Frame(label, string(m.file), Int(m.line))
    rt = _taint_scan_ci(ci, callee_targs, vcat(chain, label), fr, depth + 1, max_depth, memo, out, seen)
    memo[key] = rt
    return rt
end

# ── entry point ─────────────────────────────────────────────────────────────────────────────

"""
    StrictMode.concurrency_findings(f, types; self_arg = 1, max_depth = 4) -> Vector

Scan the optimized IR of `f(::types...)` and return the concurrency-safety violations: writes to
the `self_arg`-th argument (the *plan*, first by default) or to any state reachable only through
it. Empty ⇒ the plan is treated as read-only during the call and may be shared across tasks.
Powers [`@assert_concurrency_safe`](@ref); see that macro for the guarantee's scope and limits.
"""
function concurrency_findings(@nospecialize(f), @nospecialize(types::Tuple); self_arg::Int = 1, max_depth::Int = 4)
    cts = try
        Base.code_typed(f, types; optimize = true)
    catch
        return _ConcViol[]
    end
    isempty(cts) && return _ConcViol[]
    ci = cts[1].first
    m = try
        which(f, types)
    catch
        nothing
    end
    fr = _Frame(
        _func_name(f) * _sig_string(types),
        m isa Method ? string(m.file) : "", m isa Method ? Int(m.line) : 0
    )
    targs = Set{Int}((self_arg + 1,))   # user arg `self_arg` ↔ Core.Argument(self_arg+1)
    out = _ConcViol[]
    _taint_scan_ci(ci, targs, String[], fr, 0, max_depth, Dict{Any, Bool}(), out, Set{String}())
    return out
end

function _assert_concurrency_safe(target, @nospecialize(f), @nospecialize(types::Tuple); self_arg::Int = 1, max_depth::Int = 4)
    vs = concurrency_findings(f, types; self_arg, max_depth)
    isempty(vs) && return nothing
    io = IOBuffer()
    println(
        io, "plan argument is mutated during apply — NOT safe to share across concurrent tasks ",
        "($(length(vs)) site(s)):"
    )
    for (i, v) in enumerate(vs)
        print(io, "  [", i, "] ", v.message)
        v.file != "" && print(io, "\n        at ", v.file, ":", v.line)
        i < length(vs) && println(io)
    end
    _fail(:concurrency_safe, target, String(take!(io)))
    return nothing
end

"""
    @assert_concurrency_safe f(plan, args...)

Fail unless `f` treats its **plan** argument (the first, by default) as read-only for the whole
call — writing no field of the plan and mutating no state reachable *only* through it. When it
holds, one plan may be shared across concurrent tasks (each with its own outputs/scratch) with no
data race. The intended use is an FFT-style apply:

```julia
@assert_concurrency_safe apply_unnormalized!(plan, x, alloc_scratch(plan))
# x and the scratch are the mutable outputs (writing them is fine); `plan` must be read-only.
```

StrictMode forward-propagates a *reference taint* from the plan through the optimized IR
(`getfield`/`memoryref`/… that derive a **shared** reference — scalar field reads like
`plan.n::Int` are copies and are ignored) and fails on any store (`setfield!`/`memoryrefset!`/…)
whose container is plan-reachable. It **follows calls**: a plan-reachable value passed to a
non-inlined child method is scanned recursively (bounded by `max_depth`), so a plan that
accidentally calls a child's embedded-scratch *convenience path* — mutating
`plan.children[i].scratch.data` one frame down — is still caught; a plan-reachable value handed to
a known Base mutator or to dynamic dispatch is flagged conservatively.

This is a **complementary static proof**, not a total one: it does no alias analysis (if the
scratch you pass secretly aliases plan-owned storage it will not notice), models Base mutation
only for a known set, and bounds recursion depth — so pair it with a runtime concurrency test.
It prefers false positives over a confident false pass. Value-free (no AllocCheck/JET backend);
each argument is evaluated once; disabled builds expand to the bare call.

Options: `@assert_concurrency_safe self=2 f(out, plan)` picks a different plan slot;
`max_depth=N` bounds interprocedural recursion (default 4).
"""
macro assert_concurrency_safe(args...)
    pos, opts = _macro_call(args, (:self, :max_depth, :types))
    self_arg = haskey(opts, :self) ? opts[:self]::Int : 1
    max_depth = haskey(opts, :max_depth) ? opts[:max_depth]::Int : 4
    isempty(pos) && throw(ArgumentError("@assert_concurrency_safe needs a call expression"))
    call = pos[1]
    target = string(call)
    p = _call_parts(call; types = get(opts, :types, nothing))
    checked = quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_assert_concurrency_safe)($target, $(p.checkfn), $(p.types); self_arg = $self_arg, max_depth = $max_depth)
        _val
    end
    return _gate(checked, esc(call))
end

# ── Phase 2 lints (lower priority) ─────────────────────────────────────────────────────────────

# `:no_threadid_state` — flag `Threads.threadid()`-indexed MUTABLE state. Under Julia's task
# migration a task can move between threads mid-run, so `state[threadid()]` is a race hazard. We
# taint the `threadid()` result (+ integer arithmetic on it, + a `memoryrefnew(mem, tid_idx)`
# handle built from it) and flag any store whose container/index is threadid-derived.
#
# Best-effort, value-free. Scans OPTIMIZED IR (pure SSA — no slots to lose taint through). A
# `threadid()` call lowers to a `jl_threadid` foreigncall, which we seed; taint flows through the
# lowered index arithmetic into a `memoryrefnew` index and out to the store. Detects the common
# `buf[threadid()] = …` shape (including via a local); it does NOT track a threadid stashed into
# another array and reused later (documented limit).
# scalar ops that carry a threadid-derived index forward (lowered forms)
const _TID_CARRY = Set{Symbol}(
    (
        :+, :-, :*, :add_int, :sub_int, :mul_int, :and_int, :or_int, :sext_int, :zext_int, :trunc_int,
    )
)
_is_threadid_foreigncall(st) =
    Meta.isexpr(st, :foreigncall) && !isempty(st.args) &&
    (
    let fn = st.args[1] isa QuoteNode ? st.args[1].value : st.args[1]
        fn isa Symbol && occursin("threadid", String(fn))
    end
)

function threadid_state_findings(@nospecialize(f), @nospecialize(types::Tuple))
    cts = try
        Base.code_typed(f, types; optimize = true)
    catch
        return _ConcViol[]
    end
    isempty(cts) && return _ConcViol[]
    ci = cts[1].first
    code = ci.code
    m = try
        which(f, types)
    catch nothing end
    fr = _Frame(
        _func_name(f) * _sig_string(types),
        m isa Method ? string(m.file) : "", m isa Method ? Int(m.line) : 0
    )
    tid = BitSet()          # threadid-derived scalar values
    tidref = BitSet()       # ref handles indexed by a threadid-derived value
    out = _ConcViol[]
    seen = Set{String}()
    changed = true
    while changed
        changed = false
        for (i, st) in enumerate(code)
            mark(s::BitSet, b) = (b && !(i in s)) ? (push!(s, i); changed = true) : nothing
            if _is_threadid_foreigncall(st)
                mark(tid, true); continue
            elseif st isa Core.PiNode
                isdefined(st, :val) && _op_tainted(st.val, tid, ()) && mark(tid, true)
                continue
            elseif st isa Core.PhiNode
                any(v -> _op_tainted(v, tid, ()), st.values) && mark(tid, true)
                continue
            end
            (Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke)) || continue
            isinvoke = st.head === :invoke
            callee = isinvoke ? st.args[2] : st.args[1]
            dataargs = isinvoke ? st.args[3:end] : st.args[2:end]
            nm = _resolve_callee_name(callee, code)
            nm === nothing && continue
            if nm in _TID_CARRY
                any(a -> _op_tainted(a, tid, ()), dataargs) && mark(tid, true)
                continue
            elseif nm === :memoryrefnew || nm === :memoryref || nm === :arrayref
                any(a -> _op_tainted(a, tid, ()), dataargs) && mark(tidref, true)
                continue
            elseif haskey(_STORE_OPS, nm)
                pos = _STORE_OPS[nm]
                idx_tid = any(a -> _op_tainted(a, tid, ()), dataargs)
                cont_tid = 1 <= pos <= length(dataargs) && _op_tainted(dataargs[pos], tidref, ())
                if idx_tid || cont_tid
                    _record!(
                        out, seen, String[],
                        "writes mutable state indexed by `Threads.threadid()` (`$nm`) — unsafe under task " *
                            "migration; index by a captured task-local id or a per-task buffer instead", fr
                    )
                end
                continue
            end
        end
    end
    return out
end

function _assert_no_threadid_state(target, @nospecialize(f), @nospecialize(types::Tuple))
    vs = threadid_state_findings(f, types)
    isempty(vs) && return nothing
    io = IOBuffer()
    println(io, "threadid-indexed mutable state ($(length(vs)) site(s)):")
    for (i, v) in enumerate(vs)
        print(io, "  [", i, "] ", v.message)
        v.file != "" && print(io, "\n        at ", v.file, ":", v.line)
        i < length(vs) && println(io)
    end
    _fail(:no_threadid_state, target, String(take!(io)))
    return nothing
end

"""
    @assert_no_threadid_state f(args...)

Fail if `f` writes **mutable state indexed by `Threads.threadid()`** (best-effort, value-free IR
scan). Because a Julia task can migrate between OS threads mid-execution, `buffer[threadid()] = …`
is a data-race hazard — two tasks can hit the same slot. Prefer a per-task buffer or a captured
task-local id. Detects the direct `store buf[threadid()]` shape; it does not track a threadid
stashed into another array and reused later. Not part of [`@strict`](@ref). Disabled builds expand
to the bare call.
"""
macro assert_no_threadid_state(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_no_threadid_state needs a call expression"))
    call = pos[1]
    checked = _guarantee_expr(call, _assert_no_threadid_state; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
end

# `:pool_balanced` — best-effort STATIC gross-imbalance check: count `take!`/`put!` (and
# `acquire`/`release`) sites in `f`'s own optimized IR and flag a mismatch. It does NOT do
# per-control-flow-path matching, so it cannot see a `put!` that is skipped on an *error* path
# (the real resource-leak case) — for that, use the runtime test-assert `@test`-in-a-try/finally
# in your suite. This catches the coarse "forgot the `put!` entirely / obvious imbalance" mistake.
const _POOL_TAKE = Set{Symbol}((:take!, :acquire, :lock, :wait))
const _POOL_PUT = Set{Symbol}((:put!, :release, :unlock, :notify))

"""
    pool_balance_report(f, types) -> NamedTuple

Count acquire-like (`take!`/`acquire`/`lock`) vs release-like (`put!`/`release`/`unlock`) calls in
`f`'s optimized IR. Returns `(; takes, puts, balanced)`. **Best-effort and coarse** — a *static
count*, not a per-path match, so it cannot detect a `put!` skipped on an error branch (wrap the
acquire/release in `try/finally` and assert balance at runtime for that). Use it as a smoke test
for a forgotten release.
"""
function pool_balance_report(@nospecialize(f), @nospecialize(types::Tuple))
    cts = try
        Base.code_typed(f, types; optimize = false)   # keep source-level `take!`/`put!` names
    catch
        return (; takes = 0, puts = 0, balanced = true)
    end
    isempty(cts) && return (; takes = 0, puts = 0, balanced = true)
    code = cts[1].first.code
    takes = 0; puts = 0
    for st0 in code
        # unopt IR wraps a call result in `_slot = call(...)`; unwrap to see the call
        st = Meta.isexpr(st0, :(=)) ? st0.args[2] : st0
        (Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke)) || continue
        nm = _resolve_callee_name(st.head === :invoke ? st.args[2] : st.args[1], code)
        nm === nothing && continue
        nm in _POOL_TAKE && (takes += 1)
        nm in _POOL_PUT && (puts += 1)
    end
    return (; takes, puts, balanced = takes == puts)
end
