# Concurrency-safety guarantees — the multi-threading correctness layer.
#
# All value-free (`Base.code_typed` IR scans), like `trimsafe.jl`/`scheduling.jl`/`inlining.jl`: no
# AllocCheck/JET backend needed.

public _UnanalyzableSignature

"""
    _UnanalyzableSignature <: Exception

Raised when a scan cannot obtain typed IR for a signature at all. `concurrency_findings`,
`threadid_state_findings` and `pool_balance_report` all raise it rather than returning an empty
result: "could not check" and "is fine" would otherwise render identically, on guarantees that GATE
(see `_guarantee_gates` in report.jl). Returning `_ConcViol[]` here is the vacuous-green shape this
package exists to remove.

The findings pipeline catches it and records `:fail` with the error text, so a sweep is not stopped
by one unreadable signature. A caller using these functions directly handles it itself, which is why
the name is `public`.
"""
struct _UnanalyzableSignature <: Exception
    guarantee::Symbol
    target::String
    signature::String
    why::String
end

_UnanalyzableSignature(g::Symbol, @nospecialize(f), @nospecialize(types::Tuple), why::AbstractString) =
    _UnanalyzableSignature(g, _func_name(f), _sig_string(types), String(why))

function Base.showerror(io::IO, e::_UnanalyzableSignature)
    print(
        io, "StrictMode @", e.guarantee, ": could not analyze `", e.target, e.signature,
        "` — the guarantee is UNKNOWN, not satisfied. ", e.why
    )
    return nothing
end
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

# The direct-field positions of a CONTAINER operand, or `nothing` if it is not one. A container is
# an object built around a plan value: reading the positions that received one gives the plan back,
# reading any other gives whatever the method put there itself.
function _direct_fields(@nospecialize(op), cset::BitSet, cflds::Dict{Int, Set{Int}}, cargs)
    if op isa Core.SSAValue
        return (op.id in cset) ? get(cflds, op.id, nothing) : nothing
    elseif op isa Core.Argument
        return get(cargs, op.n, nothing)
    end
    return nothing
end

# Which field a projection reads, as a 1-based position, or `nothing` when it is not a constant
# field read (a runtime index, a `getindex` on a container with no fields). `getfield(x, :name)`
# needs the source type to turn the name into a position.
function _proj_field_index(dataargs, pos::Int, @nospecialize(srcT))
    length(dataargs) >= pos + 1 || return nothing
    f = dataargs[pos + 1]
    f isa QuoteNode && (f = f.value)
    f isa Int && return f
    f isa Symbol || return nothing
    T = _widen_taint(srcT)
    T isa DataType || return nothing
    return try
        Int(Base.fieldindex(T, f))
    catch
        nothing
    end
end

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
    # The atomic and once-only writes are builtins like the plain stores above, and they write the
    # same first argument. They must be named here because a resolved builtin callee is otherwise
    # read as non-mutating.
    :swapfield! => 1, :modifyfield! => 1, :replacefield! => 1, :setfieldonce! => 1,
    :memoryrefswap! => 1, :memoryrefmodify! => 1, :memoryrefreplace! => 1,
    :memoryrefsetonce! => 1,
)
const _CARRY_OPS = Set{Symbol}((:tuple, :ifelse))   # value-carrying: taint result if any operand tainted

# Is this dynamic callee a builtin or intrinsic that cannot mutate? A builtin cannot dispatch, so
# it is not the unresolved call the conservative record is for — but `_STORE_OPS` and
# `_BASE_MUTATORS` name the ones that DO write, and those must keep their records.
# Resolved names that must never be cleared, and are not in `_STORE_OPS` or `_BASE_MUTATORS`.
# `_STORE_OPS` means "the container is at position N", and these do not fit that: a global write's
# container is a Module, which is never tainted, and an atomic pointer write is a store through a
# raw pointer rather than through a tracked container. They belong here instead, because
# `_is_readonly_builtin` clears by exclusion — anything a table does not name is treated as unable
# to mutate, so an unnamed write is a silent pass.
const _NEVER_READONLY = Set{Symbol}(
    (
        :setglobal!, :swapglobal!, :modifyglobal!, :replaceglobal!, :setglobalonce!,
        :atomic_pointerset, :atomic_pointerswap, :atomic_pointermodify, :atomic_pointerreplace,
    )
)

function _is_readonly_builtin(@nospecialize(callee))
    callee isa GlobalRef || return false
    isconst(callee.mod, callee.name) || return false
    v = try
        getglobal(callee.mod, callee.name)
    catch
        return false
    end
    (v isa Core.Builtin || v isa Core.IntrinsicFunction) || return false
    # Judged on the RESOLVED name, not the spelling at the call site: `import Core: setfield! as
    # st!` reaches the same builtin under a name no table lists, and clearing it would be a silent
    # pass on a write.
    true_name = try
        nameof(v)
    catch
        return false
    end
    return !(
        haskey(_STORE_OPS, true_name) || true_name in _BASE_MUTATORS ||
            true_name in _NEVER_READONLY
    )
end
const _BASE_MUTATORS = Set{Symbol}(
    (
        :push!, :pushfirst!, :append!, :prepend!, :resize!, :sizehint!, :empty!, :deleteat!, :insert!,
        :splice!, :copyto!, :copy!, :unsafe_copyto!, :fill!, :map!, :_growend!, :_growbeg!,
        :_deleteend!, :_deletebeg!,
    )
)

# `certain` separates a write this scan READ from one it could not rule out. StrictMode throws only
# where it is 100% sure and warns otherwise, so the two cannot share a verdict. The default is
# `false`: an unclassified record warns, which is the safe direction.
struct _ConcViol
    message::String
    file::String
    line::Int
    certain::Bool
    # An ATOMIC write is race-free and the author plainly intended concurrent access, so it is not a
    # build failure — but it is still shared mutable state, and atomicity does not make sharing
    # safe: two tasks bumping an `@atomic` cursor on one plan corrupt each other's work even though
    # no single write tears. So it is reported and does not raise, which is a different fact from
    # `certain = false` ("the scan could not see"), and the two must not share a flag.
    deliberate::Bool
end

# The memory orders a store carries when it is atomic. `:not_atomic` is what an ordinary array store
# carries, so the presence of an order argument is not enough on its own.
const _ATOMIC_ORDERS = Set{Symbol}(
    (:unordered, :monotonic, :acquire, :release, :acquire_release, :sequentially_consistent)
)

# The store builtins that exist only in atomic form.
const _ATOMIC_STORES = Set{Symbol}(
    (
        :modifyfield!, :swapfield!, :replacefield!, :setfieldonce!,
        :memoryrefmodify!, :memoryrefswap!, :memoryrefreplace!, :memoryrefsetonce!,
    )
)

# Is this store atomic? Three shapes: the `:invoke_modify` head that `@atomic x.f += v` lowers to,
# a builtin that is atomic by name, and a plain `setfield!`/`memoryrefset!` carrying a real memory
# order — `@atomic x.f = v` becomes `setfield!(x, :f, v, :sequentially_consistent)`, where the plain
# form has no fourth argument at all.
function _is_atomic_store(st, nm, dataargs)
    Meta.isexpr(st, :invoke_modify) && return true
    nm isa Symbol && nm in _ATOMIC_STORES && return true
    for a in dataargs
        v = a isa QuoteNode ? a.value : a
        v isa Symbol && v in _ATOMIC_ORDERS && return true
    end
    return false
end

# ── the scan ──────────────────────────────────────────────────────────────────────────────────

struct _Frame
    name::String
    file::String
    line::Int
end

function _record!(
        out::Vector{_ConcViol}, seen::Set{String}, chain::Vector{String}, msg::String, fr::_Frame;
        certain::Bool = false, deliberate::Bool = false,
    )
    full = isempty(chain) ? msg : msg * " (reached via " * join(chain, " → ") * ")"
    key = full * "@" * fr.file * ":" * string(fr.line)
    key in seen && return nothing
    push!(seen, key)
    push!(out, _ConcViol(full, fr.file, fr.line, certain, deliberate))
    return nothing
end

# Scan one CodeInfo. `targs` = tainted argument slots (Core.Argument `.n` values). Returns whether
# the method may RETURN a plan-reachable reference (so the caller can keep tainting).
function _taint_scan_ci(
        ci, targs::Set{Int}, chain::Vector{String}, fr::_Frame, depth::Int, max_depth::Int,
        memo::Dict{Any, Bool}, out::Vector{_ConcViol}, seen::Set{String};
        cargs::Dict{Int, Set{Int}} = Dict{Int, Set{Int}}(),
    )
    code = ci.code
    types = ci.ssavaluetypes
    n = length(code)
    tset = BitSet()
    # Two levels, because "is the plan" and "holds a reference to the plan" are different facts and
    # one set cannot hold both. A factorization `F = Factor(sym, …)` points at the plan; the plan
    # does not point at `F`, so writing `F.ok` writes `F`. With one level, `F` either WAS the plan —
    # and every field it initializes reported — or was invisible, losing a store through `F` into the
    # plan's own arrays. `cset` holds such containers, and `cflds` records WHICH field positions of
    # each received a plan value, so reading that field back is direct and reading any other is not.
    cset = BitSet()
    cflds = Dict{Int, Set{Int}}()
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
            elseif Meta.isexpr(st, :new)
                # A struct built from a tainted value carries the taint. Without this the scan
                # stops at every wrapper: `Threads.@spawn` captures its closed-over variables as
                # fields of a closure struct, so a task writing a captured buffer reads as no write
                # at all. `args[1]` is the type; the rest are the field values.
                # Only a PROJECTION of the plan carries the taint into the new object, never the
                # plan argument itself. A struct built AROUND the plan is a different object: a
                # factorization `F = Factor(sym, …)` points at `sym`, `sym` does not point at `F`,
                # and writing `F.ok` writes `F`. Tainting from the argument made every method that
                # allocates a fresh wrapper around its plan report its own initialization as a
                # write to the plan. A value read OUT of the plan — `W(plan.buf)` — is the plan's
                # own memory, so a store through that wrapper still counts.
                # A struct built from a plan value is a CONTAINER, not the plan. Record which field
                # positions received one, so a later read of that field is direct and a read of a
                # freshly-built sibling field is not.
                fields = Set{Int}()
                for (k, a) in enumerate(@view st.args[2:end])
                    (_op_tainted(a, tset, targs) || !isnothing(_direct_fields(a, cset, cflds, cargs))) &&
                        push!(fields, k)
                end
                # Report a change only when one happened. Setting the flag unconditionally keeps the
                # fixed point from ever converging early, so every frame runs the full statement
                # budget: measured as a 7 s sweep turning into a 900 s timeout on a package whose
                # entry point is large.
                if !isempty(fields) && get(cflds, i, nothing) != fields
                    push!(cset, i)
                    cflds[i] = fields
                    changed = true
                end
                continue
            elseif Meta.isexpr(st, :foreigncall) && _fcall_name(st) === :jl_new_task
                # `Threads.@spawn` and `Threads.@threads` lower to a closure built by `:new` and
                # handed to `jl_new_task`; `Task(f)` reaches the same call. The body runs elsewhere,
                # so following it is the only way to see what the task writes.
                #
                # The ccall arguments begin at index 6 — after the function spec, return type,
                # argument-type `svec`, the required-argument count and the convention. The first
                # of them is the task's function.
                for a in @view st.args[6:end]
                    # A task closure is a CONTAINER of its captures, so follow it at either level:
                    # the body is where the write is, and the closure itself is never written.
                    (
                        _op_tainted(a, tset, targs) ||
                            !isnothing(_direct_fields(a, cset, cflds, cargs))
                    ) || continue
                    _recurse_task_body(
                        _operand_type(a, types), chain, depth, max_depth, memo, out, seen, fr
                    )
                    break
                end
                continue
            end

            # `:invoke_modify` is the third call head, and it is the one the atomic
            # read-modify-write forms use: `@atomic p.x += 1` lowers to
            # `Expr(:invoke_modify, ci, modifyfield!, …)`. It carries an `:invoke`'s layout —
            # callee second, data from the third — so it is read the same way. Omitting it reports
            # a clean pass on a plan whose field an apply atomically increments.
            (Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke) || Meta.isexpr(st, :invoke_modify)) ||
                continue
            isinvoke = st.head === :invoke || st.head === :invoke_modify
            callee = isinvoke ? st.args[2] : st.args[1]
            dataargs = isinvoke ? st.args[3:end] : st.args[2:end]
            nm = _callee_name(callee)

            # store into a tainted container → violation
            if nm !== nothing && haskey(_STORE_OPS, nm)
                pos = _STORE_OPS[nm]
                if 1 <= pos <= length(dataargs) && _op_tainted(dataargs[pos], tset, targs)
                    atomic = _is_atomic_store(st, nm, dataargs)
                    _record!(
                        out, seen, chain,
                        _store_msg(nm, isinvoke, dataargs, targs) *
                            (
                            atomic ?
                                " — the write is ATOMIC, so it cannot tear, but the plan is still " *
                                "shared mutable state and atomicity does not make sharing safe" : ""
                        ), fr; certain = true, deliberate = atomic
                    )
                end
                continue
            end

            # projection: derive a (maybe-shared) reference
            if !isnothing(nm) && haskey(_PROJECT_OPS, nm)
                pos = _PROJECT_OPS[nm]
                if 1 <= pos <= length(dataargs)
                    src = dataargs[pos]
                    # a memoryref is a *writable handle* into its buffer — always a live reference
                    isref = (nm === :memoryrefnew || nm === :memoryref) ? true : _may_ref(types[i])
                    if _op_tainted(src, tset, targs)
                        settaint(isref)
                    else
                        # Reading a field back OUT of a container: direct only for the positions
                        # that received a plan value. `F.sym` is the plan; `F.stats`, built fresh
                        # beside it, is not, and a store into that is this method's own business.
                        flds = _direct_fields(src, cset, cflds, cargs)
                        if !isnothing(flds)
                            # The source's type has to come from the right table: an argument's is
                            # in `slottypes`, and without it the field name cannot be turned into a
                            # position, which would send every read of a container back to the
                            # conservative answer.
                            srcT = if src isa Core.Argument
                                slots = ci.slottypes
                                (slots isa Vector && 1 <= src.n <= length(slots)) ?
                                    slots[src.n] : nothing
                            else
                                _operand_type(src, types)
                            end
                            idx = _proj_field_index(dataargs, pos, srcT)
                            (isnothing(idx) || idx in flds) && settaint(isref)
                        end
                    end
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
            # Container arguments travel too, with their field map: the writes that matter often
            # happen in a callee that received the fresh wrapper, so losing the distinction at the
            # call boundary loses it entirely.
            cpos = Dict{Int, Set{Int}}()
            for k in eachindex(dataargs)
                flds = _direct_fields(dataargs[k], cset, cflds, cargs)
                isnothing(flds) || (cpos[k] = flds)
            end
            (isempty(tainted_pos) && isempty(cpos)) && continue

            if isinvoke
                mi = _invoke_mi(st.args[1])
                m = mi === nothing ? nothing : mi.def
                if m isa Method && !_is_base_core(m.module)
                    rt = _recurse(mi, m, tainted_pos, chain, depth, max_depth, memo, out, seen; cpos)
                    settaint(rt && _may_ref(types[i]))
                elseif nm !== nothing && nm in _BASE_MUTATORS
                    _record!(
                        out, seen, chain,
                        "hands a plan-reachable value to `$nm`, a mutating operation", fr;
                        certain = true
                    )
                end
                # other Base/Core invokes (reads, `throw_boundserror`, …) are treated as non-mutating
                continue
            else
                # dynamic `:call`
                if nm !== nothing && nm in _BASE_MUTATORS
                    _record!(
                        out, seen, chain,
                        "hands a plan-reachable value to `$nm`, a mutating operation", fr;
                        certain = true
                    )
                elseif _is_readonly_builtin(callee)
                    # A builtin or intrinsic, which cannot dispatch and cannot mutate unless it is
                    # one of the named writes. Classified by what the callee RESOLVES to, never by
                    # the module its binding came through: optimized IR spells a builtin through
                    # whichever module resolved the binding, so `===` imported into a package reads
                    # as `GlobalRef(ThatPackage, :(===))` and a module test calls it dynamic
                    # dispatch. The getfield family is handled above.
                else
                    # `kwcall(kwargs, f, args…)` is Julia's keyword lowering, not a function
                    # anybody wrote, so naming it tells a reader nothing. The callee they wrote is
                    # the second argument; name that when it resolves.
                    tgt = if nm === :kwcall && length(dataargs) >= 2
                        inner = _callee_name(dataargs[2])
                        isnothing(inner) ?
                            "a keyword call whose callee is not resolvable" :
                            "`$inner` (through a keyword call)"
                    elseif isnothing(nm)
                        "an unresolved callee"
                    else
                        "`$nm`"
                    end
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

# The inferred type of an operand, when the scan can know one. A closure arrives as the result of
# `:new`, so for that operand this is the closure's own concrete type.
function _operand_type(@nospecialize(a), types)
    a isa Core.SSAValue || return nothing
    (1 <= a.id <= length(types)) || return nothing
    T = types[a.id]
    return (T isa DataType && isconcretetype(T)) ? T : nothing
end

# A task's body is a method of its own, reached through `jl_new_task` rather than through a call, so
# the main scan never enters it and a write to a captured buffer reads as no write at all.
#
# Scanned with the CLOSURE ITSELF tainted: a capture is read as `getfield(self, …)` and
# `_PROJECT_OPS` carries the taint on from there, so every captured value counts as plan-reachable.
# That is field-insensitive, like the rest of this scan — a task that captures both a shared buffer
# and a private one is reported for writing either. Anything it cannot resolve is RECORDED rather
# than skipped: a task body that could not be read is not a task body that writes nothing.
function _recurse_task_body(
        @nospecialize(T), chain::Vector{String}, depth::Int, max_depth::Int,
        memo::Dict{Any, Bool}, out::Vector{_ConcViol}, seen::Set{String}, caller::_Frame,
    )
    held = "spawns a task holding a plan-reachable value"
    if isnothing(T)
        _record!(
            out, seen, chain,
            "$held whose closure type could not be resolved — not followed; flagged conservatively",
            caller
        )
        return nothing
    end
    key = (T, :task)
    haskey(memo, key) && return nothing
    memo[key] = false
    if depth >= max_depth
        _record!(
            out, seen, chain,
            "$held at recursion depth $depth (≥ max_depth=$max_depth) — not followed; flagged " *
                "conservatively", caller
        )
        return nothing
    end
    cts = try
        Base.code_typed_by_type(Tuple{T}; optimize = true)
    catch err
        _record!(
            out, seen, chain,
            "$held whose body could not be analyzed ($(sprint(showerror, err))) — flagged " *
                "conservatively", caller
        )
        return nothing
    end
    if isempty(cts)
        _record!(
            out, seen, chain, "$held whose body has no typed IR — flagged conservatively", caller
        )
        return nothing
    end
    fr = try
        m = which(Tuple{T})
        _Frame("task closure", string(m.file), Int(m.line))
    catch
        caller
    end
    _taint_scan_ci(
        cts[1].first, Set{Int}(1), vcat(chain, "task closure"), fr, depth + 1, max_depth,
        memo, out, seen
    )
    return nothing
end

function _recurse(
        mi::Core.MethodInstance, m::Method, tainted_pos::Vector{Int}, chain::Vector{String},
        depth::Int, max_depth::Int, memo::Dict{Any, Bool}, out::Vector{_ConcViol}, seen::Set{String};
        cpos::Dict{Int, Set{Int}} = Dict{Int, Set{Int}}(),
    )
    # Canonical, and comparable: sorting the pairs directly falls through to comparing the `Set`
    # values whenever two keys tie, and `isless` has no method for `Set`. Measured on a real
    # package: every `cholesky!` signature came back unanalyzable with a `MethodError` from the
    # memo key rather than from anything about the method.
    key = (mi, sort(tainted_pos), [k => sort!(collect(v)) for (k, v) in sort!(collect(cpos); by = first)])
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
    callee_cargs = Dict{Int, Set{Int}}(p + 1 => v for (p, v) in cpos)
    fr = _Frame(label, string(m.file), Int(m.line))
    rt = _taint_scan_ci(
        ci, callee_targs, vcat(chain, label), fr, depth + 1, max_depth, memo, out, seen;
        cargs = callee_cargs
    )
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
    catch err
        throw(_UnanalyzableSignature(:concurrency_safe, f, types, sprint(showerror, err)))
    end
    isempty(cts) && throw(
        _UnanalyzableSignature(
            :concurrency_safe, f, types,
            "`Base.code_typed` returned no method instance for this signature"
        )
    )
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
    # Seed the plan slot only if it can hold a reference. An `isbits` plan argument is a COPY, so
    # nothing is reachable "only through it" and no store the caller's value could observe exists —
    # the guarantee holds trivially. Seeding it anyway taints every INDEX derived from it, and a
    # `memoryrefnew` on a buffer the method allocated itself then reads as plan-reachable: measured
    # on a method whose first argument is an `Int` and whose only stores go into its own fresh
    # arrays, which reported a write to the plan.
    out = _ConcViol[]
    (1 <= self_arg <= length(types) && _may_ref(types[self_arg])) || return out
    targs = Set{Int}((self_arg + 1,))   # user arg `self_arg` ↔ Core.Argument(self_arg+1)
    _taint_scan_ci(ci, targs, String[], fr, 0, max_depth, Dict{Any, Bool}(), out, Set{String}())
    return out
end

function _assert_concurrency_safe(target, @nospecialize(f), @nospecialize(types::Tuple); self_arg::Int = 1, max_depth::Int = 4)
    vs = concurrency_findings(f, types; self_arg, max_depth)
    isempty(vs) && return nothing
    io = IOBuffer()
    # The headline has to match what the scan actually established, or the warn path states as fact
    # the very thing the certainty split says it could not see.
    # Raise only on a write that is both READ by the scan and not a deliberate atomic one.
    sure = any(v -> v.certain && !v.deliberate, vs)
    println(
        io,
        sure ?
            "plan argument is mutated during apply — NOT safe to share across concurrent tasks" :
            "cannot establish that the plan argument is read-only — sharing it across concurrent " *
            "tasks is unproven, not disproven",
        " ($(length(vs)) site(s)):"
    )
    for (i, v) in enumerate(vs)
        print(io, "  [", i, "] ", v.message)
        v.file != "" && print(io, "\n        at ", v.file, ":", v.line)
        i < length(vs) && println(io)
    end
    # Throws only where the scan READ a write; a record it could not rule out warns instead, which
    # is the same rule `@assert_typestable` and `@assert_trusted` apply to their own uncertain
    # signals. A single certain record is enough to fail: the others do not weaken it.
    _fail(:concurrency_safe, target, String(take!(io)); gates = sure)
    return nothing
end

"""
    @assert_concurrency_safe f(plan, args...)

Raise, or warn where the scan cannot be sure, unless `f` treats its **plan** argument (the first, by default) as read-only for the whole
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

**Failing and warning are different outcomes here, and which one you get follows how sure the scan
is.** A write it READ — a store whose container is plan-reachable, or a hand-off to a known Base
mutator — raises `StrictViolation`. A record it could only *not rule out* warns instead: a callee
behind dynamic dispatch, a task body whose closure type did not resolve, or a chain that reached
`max_depth` and stopped. So a real write far enough down the call chain warns rather than fails,
because the scan never saw it — raise `max_depth` to reach it, or assert on the inner method
directly.

The proof tier does not remove that uncertainty: no backend decides whether an argument is
written, so `StrictModeTest` runs this same scan and inherits the same split — an uncertain record
is informational there too. That is unlike `@test_noalloc`, where AllocCheck replaces the guess.

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
# `buf[threadid()] = …` shape (including via a local), and a store into an object loaded back OUT
# of such a slot — `buf[threadid()].field = …`, `buf[threadid()][i] = …`, `rand(rngs[threadid()])`
# — because the mark carries through a `_PROJECT_OPS` read whose result can hold a reference. A
# scalar copied out of a slot does not carry it: an `Int` can never be a store's container.
#
# Three documented limits. It does NOT track a threadid stashed into another array and reused
# later. It does not follow `:invoke`, so a write inside a callee the optimizer left out of line is
# missed, and no other signature catches that one either — the taint is in the caller and the store
# is in the callee. And a lock STRIPED by thread (`lock(locks[threadid()])`) is reported: the
# inlined fast path writes a field of a lock chosen by `threadid()`, which is literally what this
# flags. It is not a data race, since a `ReentrantLock` is owned by the task rather than the
# thread, but striping locks that way buys nothing under migration, so the report is a lead.
# scalar ops that carry a threadid-derived index forward (lowered forms)
const _TID_CARRY = Set{Symbol}(
    (
        :+, :-, :*, :add_int, :sub_int, :mul_int, :and_int, :or_int, :sext_int, :zext_int, :trunc_int,
    )
)
# Normalize a `:foreigncall` target to its function-name Symbol (or `nothing`). Julia 1.13 emits the
# `(fname,)` / `(fname, lib)` form as `Expr(:tuple, QuoteNode(:jl_threadid))`, where 1.12 and earlier
# emitted a bare `QuoteNode(:jl_threadid)`. Note it is an `Expr(:tuple, …)`, NOT a `Tuple` value. The
# `occursin`-on-`string(args[1])` matchers elsewhere (effects.jl, static_ownership.jl) survive both
# forms by accident since the name stays a substring; this one needs the actual Symbol.
function _fcall_name(st)
    (Meta.isexpr(st, :foreigncall) && !isempty(st.args)) || return nothing
    fn = st.args[1]
    Meta.isexpr(fn, :tuple) && !isempty(fn.args) && (fn = fn.args[1])
    fn isa QuoteNode && (fn = fn.value)
    fn isa Tuple && !isempty(fn) && (fn = fn[1])
    return fn isa Symbol ? fn : nothing
end

function _is_threadid_foreigncall(st)
    fn = _fcall_name(st)
    return fn !== nothing && occursin("threadid", String(fn))
end

function threadid_state_findings(@nospecialize(f), @nospecialize(types::Tuple))
    cts = try
        Base.code_typed(f, types; optimize = true)
    catch err
        throw(_UnanalyzableSignature(:no_threadid_state, f, types, sprint(showerror, err)))
    end
    isempty(cts) && throw(
        _UnanalyzableSignature(
            :no_threadid_state, f, types,
            "`Base.code_typed` returned no method instance for this signature"
        )
    )
    ci = cts[1].first
    code = ci.code
    sts = ci.ssavaluetypes
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
            # `:invoke_modify` as above: `@atomic BUF[Threads.threadid()].value += 1` is the
            # canonical shape of this hazard and the one most likely to be written atomically, and
            # this guarantee GATES, so missing the head is a silent pass rather than a quiet report.
            (Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke) || Meta.isexpr(st, :invoke_modify)) ||
                continue
            isinvoke = st.head === :invoke || st.head === :invoke_modify
            callee = isinvoke ? st.args[2] : st.args[1]
            dataargs = isinvoke ? st.args[3:end] : st.args[2:end]
            nm = _resolve_callee_name(callee, code)
            nm === nothing && continue
            if nm in _TID_CARRY
                any(a -> _op_tainted(a, tid, ()), dataargs) && mark(tid, true)
                continue
            end
            # A handle built from a threadid-derived INDEX. This is the seed; it no longer ends the
            # statement, because `memoryrefnew` is also a projection and a handle built from another
            # threadid-reachable handle has to carry the mark on.
            if (nm === :memoryrefnew || nm === :memoryref || nm === :arrayref) &&
                    any(a -> _op_tainted(a, tid, ()), dataargs)
                mark(tidref, true)
            end
            if haskey(_PROJECT_OPS, nm)
                # A value projected OUT of a threadid-reachable handle is itself threadid-reachable.
                # `buf[threadid()].field = …` stores into the object loaded from the slot, and
                # without this its container sits in no set at all — a silent pass, on a guarantee
                # that gates. Only a result that can carry a reference propagates: an `Int` read out
                # of a slot is a copy and can never be a store's container.
                pos = _PROJECT_OPS[nm]
                if 1 <= pos <= length(dataargs) && _op_tainted(dataargs[pos], tidref, ())
                    T = (sts isa Vector && 1 <= i <= length(sts)) ? sts[i] : nothing
                    _may_ref(T) && mark(tidref, true)
                end
                continue
            elseif haskey(_STORE_OPS, nm)
                pos = _STORE_OPS[nm]
                idx_tid = any(a -> _op_tainted(a, tid, ()), dataargs)
                cont_tid = 1 <= pos <= length(dataargs) && _op_tainted(dataargs[pos], tidref, ())
                if idx_tid || cont_tid
                    _record!(
                        out, seen, String[],
                        "writes mutable state indexed by `Threads.threadid()` (`$nm`) — unsafe under task " *
                            "migration; index by a captured task-local id or a per-task buffer instead", fr;
                        certain = true
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
task-local id.

Detects a store to `buf[threadid()]`, and a store into an object loaded out of such a slot —
`buf[threadid()].field = …`, `buf[threadid()][i] = …`, `rand(rngs[threadid()])`. A scalar read out
of a slot and stored elsewhere is a copy, not the hazard, and stays clean.

It does not track a threadid stashed into another array and reused later, and it does not follow
calls: a write inside a callee the optimizer left out of line is missed, and no other signature
catches it either, since the threadid is in the caller and the store is in the callee. A lock
striped by thread (`lock(locks[threadid()])`) IS reported — the inlined fast path writes a field of
a lock chosen by `threadid()`. That is not a data race, because a `ReentrantLock` belongs to the
task rather than the thread, but striping locks by thread buys nothing once tasks migrate.

Not part of [`@strict`](@ref). Disabled builds expand to the bare call.
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

A signature whose IR cannot be read raises `_UnanalyzableSignature` rather than returning a count
of zero, which `balanced` would have reported as true: "nothing to count" and "counted, and they
match" must not render alike. The other two checks in this file raise for the same reason.
"""
function pool_balance_report(@nospecialize(f), @nospecialize(types::Tuple))
    cts = try
        Base.code_typed(f, types; optimize = false)   # keep source-level `take!`/`put!` names
    catch err
        throw(_UnanalyzableSignature(:pool_balanced, f, types, sprint(showerror, err)))
    end
    isempty(cts) && throw(
        _UnanalyzableSignature(
            :pool_balanced, f, types, "no typed IR for this signature, so nothing was counted."
        )
    )
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

# `:no_threadid_state`'s verdict for one signature, shared by BOTH tiers through
# `_compiled_output_finding`. There is no proving counterpart: AllocCheck, JET and TrimCheck say
# nothing about a threadid-indexed store, so a second copy in `StrictModeTest` could only drift.
#
# `notaskstate` PROVES the absence and costs only inference, so the taint scan runs only where the
# compiler could not clear the signature. `false` means unproven rather than present — a non-`const`
# global read and a dynamic call both report it — which is why it falls through to the scan instead
# of failing there.
function _threadid_state_finding(
        @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg; tier::Symbol = :report
    )
    eff = try
        effects(f, types)
    catch
        nothing
    end
    if !isnothing(eff) && effect_holds(eff, :notaskstate)
        return _mkfinding(
            md, fn, sg, :no_threadid_state, false,
            "no task-local state (compiler effects: `notaskstate`)", "", 0; tier
        )
    end
    vs = try
        threadid_state_findings(f, types)
    catch
        nothing
    end
    tloc = _method_loc(f, types)
    isnothing(vs) && return _unevaluated(
        md, fn, sg, :no_threadid_state,
        "the compiler could not prove `notaskstate` and the threadid scan could not read this " *
            "signature"; tier, file = tloc[1], line = tloc[2]
    )
    fail = !isempty(vs)
    return _mkfinding(
        md, fn, sg, :no_threadid_state, fail,
        fail ?
            "threadid-indexed mutable state ($(length(vs)) site(s)): " *
            join((v.message for v in vs), "; ") :
            "no threadid-indexed mutable state (value-free IR scan)",
        fail ? vs[1].file : "", fail ? vs[1].line : 0,
        fail ? "index by a captured task-local id, or give each task its own buffer" : ""; tier
    )
end

# `:concurrency_safe`'s verdict for one signature, shared by BOTH tiers through
# `_compiled_output_finding`. No backend has anything to add: AllocCheck, JET and TrimCheck say
# nothing about whether an argument is written.
#
# The status follows the records' certainty, which is the same rule `_assert_concurrency_safe`
# applies: a write this scan READ is `:fail`, and a record it only failed to rule out is `:info`.
# A sweep cannot be told which argument holds the plan, so it reads argument 1 — which is why
# `:concurrency_safe` is absent from the `:all` policy set and cannot stop a module loading.
function _concurrency_safe_finding(
        @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg; tier::Symbol = :report
    )
    vs = try
        concurrency_findings(f, types)
    catch
        nothing
    end
    loc = _method_loc(f, types)
    isnothing(vs) && return _unevaluated(
        md, fn, sg, :concurrency_safe, "the concurrency scan could not read this signature";
        tier, file = loc[1], line = loc[2]
    )
    isempty(vs) && return _mkfinding(
        md, fn, sg, :concurrency_safe, false, "argument 1 is not written (value-free IR scan)",
        "", 0; tier
    )
    # A `!` name DECLARES that argument 1 is written — `mul!(C, A, B)`, `copyto!(dest, src)` — so
    # finding that write is not finding a defect, it is reading the convention back. The sweep
    # cannot be told which argument holds the shared object, so for these it cannot ask the question
    # the guarantee is about, and it says so as `:info` rather than failing. It must not report
    # `:pass`: "could not check here" and "is read-only" are different answers. Measured in the
    # field before this: 92 of 134 sweep failures on one package were `!` methods writing their own
    # first argument, which buried the 42 that were not.
    if endswith(fn, "!")
        return StrictFinding(
            md, fn, sg, :concurrency_safe, :info, vs[1].file, vs[1].line,
            "a `!` name declares that argument 1 is written, so the sweep cannot tell a shared " *
                "plan from the intended output ($(length(vs)) site(s))",
            "assert this at a call site with `@assert_concurrency_safe self=N f(…)`, naming the " *
                "argument that is actually shared across tasks",
            tier, _code(:concurrency_safe)
        )
    end
    certain = any(v -> v.certain && !v.deliberate, vs)
    return StrictFinding(
        md, fn, sg, :concurrency_safe, certain ? :fail : :info,
        vs[1].file, vs[1].line,
        (
            certain ? "argument 1 is written during the call ($(length(vs)) site(s)): " :
                "cannot prove argument 1 is read-only ($(length(vs)) site(s)): "
        ) *
            join((v.message for v in vs), "; "),
        _suggestion(:concurrency_safe), tier, _code(:concurrency_safe)
    )
end
