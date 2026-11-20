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
#     tainted value at the destination position of a *known Base mutator* (`push!`/`resize!`/
#     `copyto!`/…) is flagged; a tainted value handed to an *unresolved dynamic dispatch* is
#     flagged (prefer a false positive over a confident false pass).
#   * BASE CALLEES are read like a package's own when the name declares a write (`sort!`,
#     `reverse!`, `delete!`) or the result can be a reference into an argument (`get`,
#     `reshape`, `unsafe_wrap`), `_BASE_EXTRA_DEPTH` frames past `max_depth`. The body says which
#     argument is written, so `mul!(out, plan.A, x)` and `copyto!(out, plan.buf)` read the plan
#     and `sort!(copy(plan.buf))` writes a fresh buffer. Any other Base callee is treated as
#     non-mutating.
#   * FOREIGN CALLS follow Go's rule for cgo: a C function is assumed to write through every
#     pointer it is given. `_FCALL_WRITES` names the ones whose effect is known (`memmove` writes
#     its first argument and reads its second; `memcmp` writes nothing), and a store through one
#     of those is a write the scan read. A plan pointer handed to any other foreign function —
#     every BLAS and LAPACK routine among them — is a record that reports and does not raise.
#     `_FCALL_ALIASES` names the ones whose result is the same memory under another type.
#   * A LOCK, a condition, an event, a channel or a semaphore read out of the plan carries no
#     taint: what `lock(plan.lk)` writes is the synchronization. A `Threads.Atomic` does carry
#     it: `Threads.atomic_add!(plan.ctr, 1)` and `plan.ctr[] = v` are atomic writes to shared
#     state, reported as an `@atomic` field write is, read and deliberate.
#   * A Base callee entered for what it RETURNS and not read (past its depth, or no typed IR) is
#     recorded as undecided, and its result is marked as possibly the plan's (`mset`). A store
#     through such a value is a record the scan could not rule out, never a write it read; the
#     value is not followed into a callee.
#
# WHAT IT CANNOT CATCH (honest limits — PureFFT's runtime concurrency test is the load-bearing
# backstop; this static proof is complementary):
#   * ALIASING: if the mutable output (`x`/scratch) is the *same* buffer the plan also references,
#     writing "x" is really writing the plan. No alias analysis is done — a caller passing
#     `alloc_scratch(plan)` (a fresh buffer) is fine; deliberately aliasing plan-owned storage is
#     not detected.
#   * A Base callee whose name does not end in `!` and whose result cannot hold a reference is
#     not read, so a write it makes is missed: `write(plan.io, x)`, `put!`-free channel traffic.
#   * Recursion is depth-bounded (`max_depth`, default 4); beyond it a still-tainted call is
#     flagged conservatively rather than followed. A Base callee past its own bound is flagged
#     only when its name ends in `!`.
#   * An `llvmcall` is read only for whether its IR holds an atomic instruction or a store; a
#     plain store through a plan pointer there is undecided.
#   * A callee returning a struct BUILT AROUND a plan value (a wrapper, not a projection) returns
#     no taint, and neither does a callee the walk did not read or a dynamic call.

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

# The SSA values an element reference is built from — the array, its `ref` or `mem` field, and the
# `memoryrefnew` into it — walked back from the reference. Only those steps: a `getfield` of any
# other field leaves the array for the object that holds it, which the element store does not touch.
function _ref_chain(@nospecialize(x), code::Vector{Any})
    ids = Int[]
    for _ in 1:8
        x isa Core.SSAValue || break
        push!(ids, x.id)
        s = code[x.id]
        (Meta.isexpr(s, :call) && length(s.args) >= 2) || break
        c = s.args[1]
        nm = c isa GlobalRef ? c.name : nothing
        if nm === :memoryrefnew
        elseif nm === :getfield && length(s.args) >= 3 && _field_sym(s.args[3]) in (:ref, :mem)
        else
            break
        end
        x = s.args[2]
    end
    return ids
end

_field_sym(@nospecialize(f)) = f isa QuoteNode ? f.value : f

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

# A `PhiNode`/`PhiCNode` slot is UNDEFINED where the variable it merges is not defined along that
# incoming edge, so each one is asked with `isassigned` before it is read. Iterating the values
# directly raises `UndefRefError` from `getindex`, which the scan reports as a signature it could
# not read. Measured on a real package: a `!` method whose first argument is a struct, passing two
# of its array fields to `mul!` inside a loop, builds exactly such a phi.
_any_phi_tainted(st, set::BitSet, targs) = any(
    j -> isassigned(st.values, j) && _op_tainted(st.values[j], set, targs),
    eachindex(st.values)
)

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
        _code_typed(f, argts; optimize = true)
    catch
        return nothing
    end
    return isempty(cts) ? nothing : cts[1].first
end

# The same for a callee that need not be a singleton function: a constructor, a callable object.
function _mi_codeinfo_by_type(mi::Core.MethodInstance)
    cts = try
        _code_typed_by_type(mi.specTypes; optimize = true)
    catch
        return nothing
    end
    return isempty(cts) ? nothing : cts[1].first
end

# How many frames of Base the walk reads beyond `max_depth`. Base reaches its stores through more
# layers than a package's kernel does: `sort!(v)` is five calls above the first element it moves.
const _BASE_EXTRA_DEPTH = 8

# Whether a call's result can be a reference into one of its arguments. A `String`, a `Symbol` and
# a plain-data value are copies; a pointer is not.
function _may_alias_result(@nospecialize(T))
    W = _widen_taint(T)
    W isa Type || return true
    W === Union{} && return false
    # An exception is built to be thrown, and what it holds is only printed.
    W <: Exception && return false
    W <: Union{AbstractString, Symbol, Nothing, Missing, Type, Module, Function} && return false
    return !isbitstype(W) || _holds_ptr(W)
end

# Foreign functions whose effect on their pointer arguments is known, by the positions (among the
# declared arguments) they write through. An empty tuple reads only. A foreign function this does
# not name is assumed to write through every pointer it is given.
const _FCALL_WRITES = Dict{Symbol, Tuple{Vararg{Int}}}(
    :memmove => (1,), :memcpy => (1,), :memset => (1,),
    :jl_genericmemory_copyto => (1, 2),
    :memcmp => (), :memchr => (), :strlen => (), :memhash => (), :memhash_seed => (),
    :memhash32_seed => (), :jl_object_id => (), :jl_egal => (), :jl_types_equal => (),
    :jl_genericmemory_copy_slice => (), :jl_genericmemory_copy => (), :jl_array_copy => (),
    :jl_pchar_to_string => (), :jl_symbol_n => (), :jl_eqtable_get => (), :jl_eqtable_put => (1,), :jl_eqtable_pop => (1,),
    :jl_eqtable_nextind => (), :jl_string_ptr => (), :jl_gc_add_finalizer_th => (),
    :jl_stored_inline => (), :jl_array_isassigned => (),
)

# Foreign functions whose result is the memory a pointer argument names, under another type.
const _FCALL_ALIASES = Set{Symbol}(
    (
        :jl_ptr_to_genericmemory, :jl_ptr_to_array, :jl_ptr_to_array_1d, :jl_value_ptr,
        :jl_pointer_to_objref, :jl_genericmemory_slice, :jl_reshape_array,
    )
)

# Foreign functions returning a value stored in the table they are given as their first argument.
const _FCALL_RETURNS_STORED = Set{Symbol}((:jl_eqtable_get, :jl_eqtable_pop))

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
# Value-carrying: the result holds its operands, so it is tainted if any is. `svec` is how optimized
# IR packs the collections of a splatted call, and `compilerbarrier` (`Base.inferencebarrier`)
# returns its argument.
const _CARRY_OPS = Set{Symbol}((:tuple, :ifelse, :svec, :compilerbarrier))

# Builtins that call a function they are handed: the position of that function among the data
# arguments, and the position the arguments it is called with start at. `_apply_iterate` splats each
# collection from there on; `finalizer` calls its function on the object later.
const _CALLING_BUILTIN_ARGS = Dict{Symbol, Tuple{Int, Int}}(
    :_apply_iterate => (2, 3), :_call_latest => (1, 2), :invokelatest => (1, 2), :invoke => (1, 3),
    :invoke_in_world => (2, 3), :_call_in_world => (2, 3), :_call_in_world_total => (2, 3),
    :finalizer => (1, 2),
)

# The arguments a calling builtin passes to its function, as far as the IR states them. A splatted
# collection is read when it is a literal `tuple`/`svec`; the list stops before the first one that
# is not, since what follows it lands at positions the IR does not give.
function _called_args(bn::Symbol, dataargs, astart::Int, code)
    astart <= length(dataargs) || return Any[]
    bn === :_apply_iterate || return collect(Any, @view dataargs[astart:end])
    args = Any[]
    for c in @view dataargs[astart:end]
        s = c isa Core.SSAValue ? code[c.id] : nothing
        (Meta.isexpr(s, :call) && _callee_name(s.args[1]) in (:tuple, :svec)) || break
        append!(args, @view s.args[2:end])
    end
    return args
end

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

# The name of the builtin or intrinsic a callee resolves to, or `nothing` when it is neither.
function _builtin_name(@nospecialize(callee))
    # Optimized IR names a builtin through a binding or holds the builtin itself as the callee.
    v = if callee isa Core.Builtin || callee isa Core.IntrinsicFunction
        callee
    elseif callee isa GlobalRef && isconst(callee.mod, callee.name)
        try
            getglobal(callee.mod, callee.name)
        catch
            return nothing
        end
    else
        return nothing
    end
    (v isa Core.Builtin || v isa Core.IntrinsicFunction) || return nothing
    return try
        nameof(v)
    catch
        nothing
    end
end

function _is_readonly_builtin(@nospecialize(callee))
    # Judged on the RESOLVED name, not the spelling at the call site: `import Core: setfield! as
    # st!` reaches the same builtin under a name no table lists, and clearing it would be a silent
    # pass on a write. A builtin that calls the function it is handed does whatever that does.
    true_name = _builtin_name(callee)
    isnothing(true_name) && return false
    return !(
        haskey(_STORE_OPS, true_name) || true_name in _BASE_MUTATORS ||
            true_name in _NEVER_READONLY || haskey(_CALLING_BUILTIN_ARGS, true_name)
    )
end
const _BASE_MUTATORS = Set{Symbol}(
    (
        :push!, :pushfirst!, :append!, :prepend!, :resize!, :sizehint!, :empty!, :deleteat!, :insert!,
        :splice!, :copyto!, :copy!, :unsafe_copyto!, :fill!, :map!, :_growend!, :_growbeg!,
        :_deleteend!, :_deletebeg!,
    )
)

# Which argument a named mutator writes. A plan value at any other position is a source:
# `copyto!(out, plan.buf)` reads the plan.
_mutator_dest(nm::Symbol) = nm === :map! ? 2 : 1

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
    # The write is to state every caller shares through a constant global, not to the plan. The
    # headline of a report names the plan only when a record is about it.
    global_state::Bool
end
_ConcViol(message, file, line, certain, deliberate) = _ConcViol(message, file, line, certain, deliberate, false)

# The memory orders a store carries when it is atomic. `:not_atomic` is what an ordinary array store
# carries, so the presence of an order argument is not enough on its own.
const _ATOMIC_ORDERS = Set{Symbol}(
    (:unordered, :monotonic, :acquire, :release, :acquire_release, :sequentially_consistent)
)

# Is this store atomic? Only when it carries a real memory order: `@atomic x.f = v` becomes
# `setfield!(x, :f, v, :sequentially_consistent)`, and `@atomic x.f += v` an `:invoke_modify` ending in
# the same order. Neither the name nor the `:invoke_modify` head decides it: `modifyfield!(p, :n, +, 1)`
# on a plain field lowers to `:invoke_modify` with no order, is not atomic, and two tasks running it
# lose increments.
# Where each store builtin takes its (first) memory order, counted in its data arguments. Only that
# position is read: a field named `release`, or a stored value `:acquire`, is not an order.
const _ORDER_POSITION = Dict{Symbol, Int}(
    :setfield! => 4, :swapfield! => 4, :modifyfield! => 5, :replacefield! => 5, :setfieldonce! => 4,
    :setglobal! => 4, :swapglobal! => 4, :modifyglobal! => 5, :replaceglobal! => 5,
    :memoryrefset! => 3, :memoryrefswap! => 3, :memoryrefmodify! => 4, :memoryrefreplace! => 4,
    :memoryrefsetonce! => 3,
)

function _is_atomic_store(st, nm, dataargs)
    pos = get(_ORDER_POSITION, nm, 0)
    1 <= pos <= length(dataargs) || return false
    a = dataargs[pos]
    v = a isa QuoteNode ? a.value : a
    return v isa Symbol && v in _ATOMIC_ORDERS
end

# ── the scan ──────────────────────────────────────────────────────────────────────────────────

struct _Frame
    name::String
    file::String
    line::Int
end

function _record!(
        out::Vector{_ConcViol}, seen::Set{String}, chain::Vector{String}, msg::String, fr::_Frame;
        certain::Bool = false, deliberate::Bool = false, global_state::Bool = false,
    )
    full = isempty(chain) ? msg : msg * " (reached via " * join(chain, " → ") * ")"
    key = full * "@" * fr.file * ":" * string(fr.line)
    key in seen && return nothing
    push!(seen, key)
    push!(out, _ConcViol(full, fr.file, fr.line, certain, deliberate, global_state))
    return nothing
end

# Scan one CodeInfo. `targs` = tainted argument slots (Core.Argument `.n` values). Returns whether
# the method may RETURN a plan-reachable reference (so the caller can keep tainting).
function _taint_scan_ci(
        ci, targs::Set{Int}, chain::Vector{String}, fr::_Frame, depth::Int, max_depth::Int,
        memo::Dict{Any, Any}, out::Vector{_ConcViol}, seen::Set{String};
        cargs::Dict{Int, Set{Int}} = Dict{Int, Set{Int}}(), gargs::Set{Int} = Set{Int}(),
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
    # A third level: an array whose ELEMENTS are plan values — an array literal or a fresh array a
    # plan buffer was stored into. Reading an element back is the plan; storing into the array is
    # the method's own write, so it is not reported.
    eset = BitSet()
    einset(@nospecialize(a)) = a isa Core.SSAValue && a.id in eset
    setelem(j) = (j in eset) ? false : (push!(eset, j); changed = true; true)
    returns_tainted = false
    # Values a Base callee the walk did not read may have returned from the plan. Undecided, so a
    # store through one is recorded as a site the scan could not rule out, never as a write it
    # read, and such a value is not followed into a callee.
    mset = BitSet()
    maybe(@nospecialize(a)) = a isa Core.SSAValue && a.id in mset
    setmaybe(j) = (j in mset || j in tset) ? false : (push!(mset, j); changed = true; true)
    # Values reachable from a mutable constant global. Every caller shares it, so a store into one
    # is shared state whatever argument the check was told is shared. `gargs` are the arguments
    # a caller passed such a value in.
    gset = BitSet()
    gtainted(@nospecialize(a)) = (a isa Core.SSAValue && a.id in gset) ||
        (a isa Core.Argument && a.n in gargs) || _is_mutable_global(a)
    changed = true
    passes = 0
    while changed && passes <= n + 2
        changed = false
        passes += 1
        for (i, st) in enumerate(code)
            settaint(b) = (b && !(i in tset)) ? (push!(tset, i); changed = true; true) : false

            if st isa Core.PiNode
                isdefined(st, :val) && maybe(st.val) && setmaybe(i)
                isdefined(st, :val) && einset(st.val) && setelem(i)
                isdefined(st, :val) && gtainted(st.val) && !(i in gset) && (push!(gset, i); changed = true)
                # A value narrowed to a lock or a condition is a synchronization object from here on.
                isdefined(st, :val) && _op_tainted(st.val, tset, targs) &&
                    settaint(!_is_lock_type(Core.Compiler.widenconst(types[i])))
                continue
            elseif st isa Core.PhiNode || st isa Core.PhiCNode
                any(k -> isassigned(st.values, k) && maybe(st.values[k]), eachindex(st.values)) && setmaybe(i)
                st isa Core.PhiNode && any(k -> isassigned(st.values, k) && einset(st.values[k]), eachindex(st.values)) && setelem(i)
                _any_phi_tainted(st, tset, targs) && settaint(true)
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
                    (_op_tainted(a, tset, targs) || einset(a) || !isnothing(_direct_fields(a, cset, cflds, cargs))) &&
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
                # A closure built from a plan value is a function that will be called — by a Base
                # higher-order function, a generator, a task spawned from it — and its body is where
                # any write happens. Reading it here does not depend on following the call that
                # eventually runs it through Base.
                !isempty(fields) && _recurse_closure_body(types[i], fields, chain, depth, max_depth, memo, out, seen, fr)
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
                    # A closure that IS a plan value taints all of it; one built from plan values taints
                    # the captures that received them.
                    tflds = _op_tainted(a, tset, targs) ? nothing : _direct_fields(a, cset, cflds, cargs)
                    _recurse_task_body(
                        _operand_type(a, types), chain, depth, max_depth, memo, out, seen, fr; fields = tflds
                    )
                    break
                end
                continue
            elseif Meta.isexpr(st, :foreigncall)
                # The declared arguments only: what follows them are the values kept alive for the
                # call, which the foreign function never receives.
                argtypes = st.args[3]
                nfargs = argtypes isa Core.SimpleVector ? length(argtypes) : length(st.args) - 5
                fargs = @view st.args[6:min(lastindex(st.args), 5 + nfargs)]
                # The address of a global is the global: `pointer_from_objref` of a constant
                # `Threads.Atomic` is how it is written.
                _fcall_name(st) in _FCALL_ALIASES && any(gtainted, fargs) && !(i in gset) &&
                    (push!(gset, i); changed = true)
                fname = _fcall_name(st)
                # An `IdDict` lookup returns a value its table holds: the plan's when the table is.
                if fname in _FCALL_RETURNS_STORED && !isempty(fargs)
                    _op_tainted(fargs[1], tset, targs) && settaint(_may_ref(types[i]))
                    gtainted(fargs[1]) && _may_ref(types[i]) && !(i in gset) && (push!(gset, i); changed = true)
                end
                handed = Int[k for k in eachindex(fargs) if _op_tainted(fargs[k], tset, targs)]
                isempty(handed) && continue
                if fname in _FCALL_ALIASES
                    settaint(true)
                    continue
                end
                written = get(_FCALL_WRITES, fname, nothing)
                if isnothing(written)
                    # Go's rule for cgo: a C function is assumed to keep and use the pointers it
                    # is given. Nothing here read a store, so this reports and does not raise.
                    _record!(
                        out, seen, chain,
                        "hands a plan-reachable pointer to " *
                            (isnothing(fname) ? "a foreign function" : "the foreign function `$fname`") *
                            " — a foreign function is assumed to write through the pointers it is " *
                            "given, and StrictMode cannot read it (flagged conservatively)", fr
                    )
                elseif any(in(written), handed)
                    _record!(
                        out, seen, chain,
                        "stores into a buffer reachable from the plan (`$fname` writes its " *
                            "destination) — a heap write the plan can observe", fr; certain = true
                    )
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
                # A plan value stored into a fresh container makes the container hold it — a reassigned
                # local's `Core.Box`, a struct field, an array literal's memory — so a later read back
                # out of it is the plan. A field store records WHICH field, as building the struct does;
                # an element store taints the memory, since elements are not told apart.
                if nm === :setfield! && length(dataargs) >= 3 && dataargs[1] isa Core.SSAValue &&
                        _op_tainted(dataargs[3], tset, targs) && !(dataargs[1].id in tset)
                    idx = _proj_field_index(dataargs, 1, _operand_type(dataargs[1], types))
                    if !isnothing(idx)
                        c = dataargs[1].id
                        flds = get(cflds, c, Set{Int}())
                        if !(idx in flds)
                            cflds[c] = union(flds, Set{Int}(idx)); push!(cset, c); changed = true
                        end
                    end
                elseif (nm === :memoryrefset! || nm === :memoryset! || nm === :setindex! || nm === :arrayset) &&
                        length(dataargs) >= 2 && _op_tainted(dataargs[nm === :arrayset ? 3 : 2], tset, targs)
                    tgt = dataargs[nm === :arrayset ? 2 : 1]
                    tgt isa Core.SSAValue && !(tgt.id in tset) && foreach(setelem, _ref_chain(tgt, code))
                end
                if 1 <= pos <= length(dataargs) && gtainted(dataargs[pos])
                    gatomic = _is_atomic_store(st, nm, dataargs)
                    _record!(
                        out, seen, chain,
                        "writes process-global state (`$nm` into a mutable constant global) — every " *
                            "concurrent call shares it; pass the buffer in, or own it per task" *
                            (gatomic ? " (the write is atomic, so it cannot tear, but the global is still shared)" : ""),
                        fr; certain = true, deliberate = gatomic, global_state = true
                    )
                end
                if 1 <= pos <= length(dataargs) && maybe(dataargs[pos]) && !_op_tainted(dataargs[pos], tset, targs)
                    _record!(
                        out, seen, chain,
                        "stores into a value (`$nm`) that a Base callee the scan did not read may " *
                            "have returned from the plan — not read, so not established", fr
                    )
                end
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
                    maybe(src) && (
                        nm === :memoryrefnew || nm === :memoryref || _may_ref(types[i]) ||
                            _holds_ptr(Core.Compiler.widenconst(types[i]))
                    ) && setmaybe(i)
                    if gtainted(src) && _may_ref(types[i]) && !_is_lock_type(Core.Compiler.widenconst(types[i])) && !(i in gset)
                        push!(gset, i); changed = true
                    end
                    # a memoryref is a *writable handle* into its buffer — always a live reference —
                    # and so is a raw pointer read out of one (`ptr_or_offset`), though it is bits
                    if einset(src) && !_op_tainted(src, tset, targs)
                        # Walking toward an element keeps the element level; reading one is the plan.
                        if nm === :memoryrefnew || nm === :memoryref ||
                                (nm === :getfield && length(dataargs) >= 2 && _field_sym(dataargs[2]) in (:ref, :mem))
                            setelem(i)
                        elseif nm in (:memoryrefget, :getindex, :arrayref, :unsafe_load)
                            settaint(_may_ref(types[i]) || _holds_ptr(Core.Compiler.widenconst(types[i])))
                        end
                        continue
                    end
                    isref = (nm === :memoryrefnew || nm === :memoryref) ? true :
                        (_may_ref(types[i]) || _holds_ptr(Core.Compiler.widenconst(types[i])))
                    # A lock, a condition or a channel read out of the plan is how the tasks
                    # sharing it synchronize, and what `lock` writes inside it is the
                    # synchronization, not shared data.
                    isref = isref && !_is_lock_type(Core.Compiler.widenconst(types[i]))
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

            # An array literal holding a plan value: its elements are the plan, the array is not.
            if nm === :vect
                any(a -> _op_tainted(a, tset, targs), dataargs) && setelem(i)
                continue
            end

            # value-carrying op (tuple/ifelse): result may carry the reference forward
            if nm !== nothing && nm in _CARRY_OPS
                any(maybe, dataargs) && setmaybe(i)
                any(a -> _op_tainted(a, tset, targs), dataargs) && settaint(true)
                continue
            end

            # A raw pointer into the plan writes the plan: `pointer(x)` lowers to
            # `bitcast(Ptr{T}, getfield(getfield(x, :ref), :ptr_or_offset))`, and an offset from it
            # to `add_ptr`, ending in a `pointerset`. Only the pointer operand carries the taint — an
            # offset read from the plan must not make a pointer into another array look like it.
            if nm === :bitcast && length(dataargs) == 2
                gtainted(dataargs[2]) && !(i in gset) && (push!(gset, i); changed = true)
                maybe(dataargs[2]) && setmaybe(i)
                _op_tainted(dataargs[2], tset, targs) && settaint(true)
                continue
            elseif (nm === :add_ptr || nm === :sub_ptr) && !isempty(dataargs)
                gtainted(dataargs[1]) && !(i in gset) && (push!(gset, i); changed = true)
                maybe(dataargs[1]) && setmaybe(i)
                _op_tainted(dataargs[1], tset, targs) && settaint(true)
                continue
            end

            # An atomic write through a pointer into the plan: what `Threads.atomic_add!` and
            # `x[] = v` on a `Threads.Atomic` become. It is the same fact as an `@atomic` field
            # write and is reported the same way: read, and deliberate.
            # Inline LLVM IR handed a pointer into the plan, which is how `Threads.Atomic` is
            # written before Julia 1.13. An atomic instruction is the same fact as the intrinsic
            # below. Any other store is not read, and is recorded as undecided.
            if nm === :llvmcall && length(dataargs) >= 4 && any(gtainted, @view dataargs[4:end]) &&
                    !any(a -> _op_tainted(a, tset, targs), @view dataargs[4:end])
                ir = _llvmcall_text(dataargs[1])
                (occursin("atomicrmw", ir) || occursin("cmpxchg", ir) || occursin("store atomic", ir)) &&
                    _record!(out, seen, chain, _GLOBAL_ATOMIC_WRITE, fr; certain = true, deliberate = true, global_state = true)
                continue
            end
            if nm === :llvmcall && length(dataargs) >= 4 &&
                    any(a -> _op_tainted(a, tset, targs), @view dataargs[4:end])
                ir = _llvmcall_text(dataargs[1])
                if occursin("atomicrmw", ir) || occursin("cmpxchg", ir) || occursin("store atomic", ir)
                    _record!(
                        out, seen, chain,
                        "stores into a buffer reachable from the plan (an atomic instruction in " *
                            "`llvmcall`) — a heap write the plan can observe — the write is ATOMIC, " *
                            "so it cannot tear, but the plan is still shared mutable state and " *
                            "atomicity does not make sharing safe", fr; certain = true, deliberate = true
                    )
                elseif occursin("store", ir)
                    _record!(
                        out, seen, chain,
                        "hands a plan-reachable pointer to inline LLVM IR that stores (`llvmcall`) " *
                            "— StrictMode does not read it (flagged conservatively)", fr
                    )
                end
                continue
            end
            if nm !== nothing && nm in _ATOMIC_POINTER_WRITES && !isempty(dataargs)
                gtainted(dataargs[1]) &&
                    _record!(out, seen, chain, _GLOBAL_ATOMIC_WRITE, fr; certain = true, deliberate = true, global_state = true)
                _op_tainted(dataargs[1], tset, targs) && _record!(
                    out, seen, chain,
                    "stores into a buffer reachable from the plan (`$nm`) — a heap write the plan " *
                        "can observe — the write is ATOMIC, so it cannot tear, but the plan is still " *
                        "shared mutable state and atomicity does not make sharing safe", fr;
                    certain = true, deliberate = true
                )
                continue
            end

            # a plain call that receives a tainted (plan-reachable) reference: follow it
            tainted_pos = Int[k for k in eachindex(dataargs) if _op_tainted(dataargs[k], tset, targs)]
            # A plan value typed `Any` here and narrowed to a lock in the callee is still a lock.
            if isinvoke
                mi0 = _invoke_mi(st.args[1])
                if !isnothing(mi0) && mi0.specTypes isa DataType
                    ps = mi0.specTypes.parameters
                    filter!(k -> !(k + 1 <= length(ps) && _is_lock_type(ps[k + 1])), tainted_pos)
                end
            end
            # Container arguments travel too, with their field map: the writes that matter often
            # happen in a callee that received the fresh wrapper, so losing the distinction at the
            # call boundary loses it entirely.
            cpos = Dict{Int, Set{Int}}()
            for k in eachindex(dataargs)
                flds = _direct_fields(dataargs[k], cset, cflds, cargs)
                isnothing(flds) || (cpos[k] = flds)
            end
            # A global handed to a callee is as shared inside it as here: a helper that bumps the
            # counter it was given writes the global. A lock is written by everyone who takes it.
            gpos = Int[]
            if isinvoke
                mi0 = _invoke_mi(st.args[1])
                ps = (!isnothing(mi0) && mi0.specTypes isa DataType) ? mi0.specTypes.parameters : nothing
                for k in eachindex(dataargs)
                    gtainted(dataargs[k]) || continue
                    (!isnothing(ps) && k + 1 <= length(ps) && _is_lock_type(ps[k + 1])) && continue
                    push!(gpos, k)
                end
            end
            (isempty(tainted_pos) && isempty(cpos) && isempty(gpos)) && continue

            if isinvoke
                mi = _invoke_mi(st.args[1])
                m = mi === nothing ? nothing : mi.def
                if m isa Method && !_is_base_core(m.module)
                    rt = _recurse(mi, m, tainted_pos, chain, depth, max_depth, memo, out, seen; cpos, gpos)
                    settaint(rt === true && _may_ref(types[i]))
                elseif nm !== nothing && nm in _BASE_MUTATORS && _mutator_dest(nm) in tainted_pos
                    _record!(
                        out, seen, chain,
                        "hands a plan-reachable value to `$nm`, a mutating operation", fr;
                        certain = true
                    )
                elseif m isa Method
                    # A Base callee is read when its name declares a write (`sort!`, `delete!`) or
                    # when what it returns can be a reference into the plan (`get`, `reshape`,
                    # `unsafe_wrap`): the body says which argument is written and whether the
                    # result is the plan's memory or a fresh copy. Any other Base callee (a
                    # reduction, a `throw_boundserror`) is treated as non-mutating.
                    bang = endswith(String(_demangle(m.name)), "!")
                    if bang || (_may_alias_result(types[i]) && !(isempty(tainted_pos) && isempty(cpos)))
                        rt = _recurse(
                            mi, m, tainted_pos, chain, depth, max_depth, memo, out, seen;
                            cpos, gpos, base = true, bang
                        )
                        settaint(rt === true && _may_ref(types[i]))
                        rt === :maybe && _may_alias_result(types[i]) && setmaybe(i)
                    end
                end
                continue
            else
                # dynamic `:call`
                if nm !== nothing && nm in _BASE_MUTATORS && _mutator_dest(nm) in tainted_pos
                    _record!(
                        out, seen, chain,
                        "hands a plan-reachable value to `$nm`, a mutating operation", fr;
                        certain = true
                    )
                elseif haskey(_CALLING_BUILTIN_ARGS, something(_builtin_name(callee), :_))
                    # `invokelatest(fill!, plan.buf, 0.0)`, `push!(plan.log, xs...)`: the call is
                    # the function handed in, on the arguments that follow it.
                    bn = _builtin_name(callee)
                    fpos, astart = _CALLING_BUILTIN_ARGS[bn]
                    inner = fpos <= length(dataargs) ? _callee_name(dataargs[fpos]) : nothing
                    iargs = _called_args(bn, dataargs, astart, code)
                    if !isnothing(inner) && inner in _BASE_MUTATORS &&
                            _mutator_dest(inner) <= length(iargs) &&
                            _op_tainted(iargs[_mutator_dest(inner)], tset, targs)
                        _record!(
                            out, seen, chain,
                            "hands a plan-reachable value to `$inner` (through `$bn`), a mutating operation", fr;
                            certain = true
                        )
                    else
                        _record!(
                            out, seen, chain,
                            "hands a plan-reachable value to " *
                                (isnothing(inner) ? "a function it does not resolve" : "`$inner`") *
                                " through `$bn` — StrictMode cannot prove it treats the plan as " *
                                "read-only (flagged conservatively)", fr
                        )
                    end
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

# Whether a value of type `T` can carry a raw pointer: a `Ptr`, or a plain-data struct with one in a
# field. Such a value is a copy, yet a store through the pointer it holds writes the memory it was
# read from, so it carries the taint as a reference does.
function _holds_ptr(@nospecialize(T), depth::Int = 0)
    T isa DataType || return false
    T <: Ptr && return true
    (depth < 4 && isbitstype(T)) || return false
    return any(F -> _holds_ptr(F, depth + 1), fieldtypes(T))
end

# A constant global holding a mutable value, as optimized code spells it: the value itself, quoted
# or bare, or a `GlobalRef` to a constant binding. A string or symbol is not shared state.
function _is_mutable_global(@nospecialize(a))
    (a isa Core.SSAValue || a isa Core.Argument || a isa Core.SlotNumber || a isa Expr) && return false
    v = if a isa QuoteNode
        a.value
    elseif a isa GlobalRef
        (isdefined(a.mod, a.name) && isconst(a.mod, a.name)) ? getglobal(a.mod, a.name) : return false
    else
        a
    end
    (v isa String || v isa Symbol || v isa Module || v isa Type || v isa Function) && return false
    # A lock, a condition, an event, a channel or a semaphore is how tasks synchronize: its
    # internal writes are the synchronization, not shared data. A `Threads.Atomic` is data that is
    # written atomically, and stays, so a write to it is reported as an atomic write.
    (_is_sync_object(v) && !(v isa Threads.Atomic)) && return false
    # Mutable state anywhere inside the value counts: an immutable struct or tuple holding a vector.
    return _holds_mutable(v)
end

_is_sync_object(@nospecialize(v)) =
    v isa Base.AbstractLock || v isa Threads.Atomic || v isa Base.GenericCondition ||
    v isa Base.Event || v isa Channel || v isa Base.Semaphore

# The synchronization types a plan may hold without their writes counting as writes to the plan:
# a lock, a condition, an event, a channel, a semaphore. A `Threads.Atomic` is not one of them.
# Writing it is an atomic write to shared state, reported as an `@atomic` field write is.
_is_lock_type(@nospecialize(T)) = _is_sync_type(T) && !(T <: Threads.Atomic)

# The IR an `llvmcall` carries: a string, or a `(module IR, entry name)` tuple.
function _llvmcall_text(@nospecialize(a))
    a isa QuoteNode && (a = a.value)
    a isa AbstractString && return String(a)
    a isa Tuple || return ""
    return join((String(x) for x in a if x isa AbstractString), "\n")
end

const _GLOBAL_ATOMIC_WRITE = "writes process-global state (an atomic write into a constant " *
    "global `Threads.Atomic`) — the write is atomic, so it cannot tear, but every concurrent call " *
    "shares the global"

const _ATOMIC_POINTER_WRITES = (
    :atomic_pointerset, :atomic_pointerswap, :atomic_pointermodify, :atomic_pointerreplace,
)

# A type whose objects are how tasks synchronize; a value of it read out of a global is not shared data.
_is_sync_type(@nospecialize(T)) = T isa Type && (
    T <: Base.AbstractLock || T <: Threads.Atomic ||
        T <: Base.GenericCondition || T <: Base.Event || T <: Channel || T <: Base.Semaphore
)

# The call methods of a closure, or of any struct with a call method of its own, built from a plan
# value. Each is scanned with only the captured fields that received a plan value tainted, so a fresh
# buffer captured beside them stays the closure's own. A struct with no call method has no body to read.
function _recurse_closure_body(
        @nospecialize(T), fields::Set{Int}, chain::Vector{String}, depth::Int, max_depth::Int,
        memo::Dict{Any, Any}, out::Vector{_ConcViol}, seen::Set{String}, caller::_Frame,
    )
    T = Core.Compiler.widenconst(T)
    # A closure, or any struct with a call method of its own: both are functions that carry state.
    (T isa DataType && isconcretetype(T)) || return nothing
    key = (T, :closure, fields)
    haskey(memo, key) && return nothing
    memo[key] = false
    ms = Base._methods_by_ftype(Tuple{T, Vararg{Any}}, -1, Base.get_world_counter())
    ms isa Vector || return nothing
    # A struct with no call method of its own is data, not a closure: there is no body to read,
    # at any depth.
    any(match -> !_is_base_core(match.method.module), ms) || return nothing
    if depth >= max_depth
        _record!(
            out, seen, chain,
            "builds a closure holding a plan-reachable value at recursion depth $depth (≥ " *
                "max_depth=$max_depth) — not read, so not established; pass a larger `max_depth` to check it", caller
        )
        return nothing
    end
    for match in ms
        m = match.method
        # The closure's own call methods only: a generic method on `Function` matches too.
        _is_base_core(m.module) && continue
        # A compiled specialization for this closure type has concrete argument types, so a task
        # it spawns has a concrete closure type; the declared signature is the fallback.
        sigs = Any[
            mi.specTypes for mi in Base.specializations(m)
                if mi isa Core.MethodInstance && mi.specTypes isa DataType && mi.specTypes.parameters[1] === T
        ]
        isempty(sigs) && push!(sigs, Tuple{T, Base.unwrap_unionall(m.sig).parameters[2:end]...})
        for sig in sigs
            cts = try
                _code_typed_by_type(sig; optimize = true)
            catch
                continue
            end
            isempty(cts) && continue
            fr = _Frame("closure", string(m.file), Int(m.line))
            # Only the captures that received a plan value are the plan; a fresh buffer captured
            # beside them is the closure's own.
            _taint_scan_ci(
                cts[1].first, Set{Int}(), vcat(chain, "closure"), fr, depth + 1, max_depth,
                memo, out, seen; cargs = Dict{Int, Set{Int}}(1 => fields)
            )
        end
    end
    return nothing
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
        memo::Dict{Any, Any}, out::Vector{_ConcViol}, seen::Set{String}, caller::_Frame;
        fields::Union{Nothing, Set{Int}} = nothing,
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
    key = (T, :task, fields)
    haskey(memo, key) && return nothing
    memo[key] = false
    if depth >= max_depth
        _record!(
            out, seen, chain,
            "$held at recursion depth $depth (≥ max_depth=$max_depth) — not read, so not " *
                "established; pass a larger `max_depth` to check it", caller
        )
        return nothing
    end
    cts = try
        _code_typed_by_type(Tuple{T}; optimize = true)
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
        cts[1].first, isnothing(fields) ? Set{Int}(1) : Set{Int}(), vcat(chain, "task closure"), fr,
        depth + 1, max_depth, memo, out, seen;
        cargs = isnothing(fields) ? Dict{Int, Set{Int}}() : Dict{Int, Set{Int}}(1 => fields)
    )
    return nothing
end

function _recurse(
        mi::Core.MethodInstance, m::Method, tainted_pos::Vector{Int}, chain::Vector{String},
        depth::Int, max_depth::Int, memo::Dict{Any, Any}, out::Vector{_ConcViol}, seen::Set{String};
        cpos::Dict{Int, Set{Int}} = Dict{Int, Set{Int}}(), base::Bool = false, bang::Bool = false,
        gpos::Vector{Int} = Int[],
    )
    # Canonical, and comparable: sorting the pairs directly falls through to comparing the `Set`
    # values whenever two keys tie, and `isless` has no method for `Set`. Measured on a real
    # package: every `cholesky!` signature came back unanalyzable with a `MethodError` from the
    # memo key rather than from anything about the method.
    key = (mi, sort(tainted_pos), [k => sort!(collect(v)) for (k, v) in sort!(collect(cpos); by = first)], sort(gpos))
    # Entered for a global alone: nothing of the plan is handed over, so there is nothing about
    # the plan to record when the callee is not read.
    global_only = isempty(tainted_pos) && isempty(cpos)
    # A result is kept with the depth it was computed at and whether the walk was cut short
    # somewhere beneath it. One that was cut answers only a visit at least as deep: a shallower
    # visit reads further and may find what the deeper one could not.
    kept = get(memo, key, nothing)
    if kept isa Tuple
        (!kept[3] || depth >= kept[2]) && return kept[1]
    end
    label = string(_demangle(m.name))
    # A Base callee that is not read is reported only when its name declares a write. Base's
    # other functions do not write their arguments, and a record for each one the walk stopped
    # at would report every reduction and every `show` of a plan value.
    quiet = (base && !bang) || global_only
    if depth >= max_depth + (base ? _BASE_EXTRA_DEPTH : 0)
        quiet || _record!(
            out, seen, chain,
            "hands a plan-reachable value to `$label` at recursion depth $depth (≥ max_depth=$max_depth) — " *
                "not read, so not established; pass a larger `max_depth` to check it", _Frame(label, string(m.file), Int(m.line))
        )
        memo[:cut] = get(memo, :cut, 0) + 1
        global_only && return false
        return quiet ? _unread_result(label, "past the depth the walk reads", m, chain, out, seen) : false
    end
    cut0 = get(memo, :cut, 0)
    memo[key] = (false, depth, false)   # cycle guard: assume non-tainting return until proven
    ci = base ? _mi_codeinfo_by_type(mi) : _mi_codeinfo(mi)
    if ci === nothing
        # The callee holds a plan-reachable value and nothing says what it does with it.
        quiet || _record!(
            out, seen, chain,
            "hands a plan-reachable value to `$label`, whose typed IR could not be read — " *
                "not read, so not established", _Frame(label, string(m.file), Int(m.line))
        )
        delete!(memo, key)
        global_only && return false
        return quiet ? _unread_result(label, "its typed IR could not be read", m, chain, out, seen) : false
    end
    # user param k (1-based) ↔ Core.Argument(k+1)
    callee_targs = Set{Int}(p + 1 for p in tainted_pos)
    callee_cargs = Dict{Int, Set{Int}}(p + 1 => v for (p, v) in cpos)
    fr = _Frame(label, string(m.file), Int(m.line))
    rt = _taint_scan_ci(
        ci, callee_targs, vcat(chain, label), fr, depth + 1, max_depth, memo, out, seen;
        cargs = callee_cargs, gargs = Set{Int}(p + 1 for p in gpos)
    )
    memo[key] = (rt, depth, get(memo, :cut, 0) != cut0)
    return rt
end

# A Base callee that was entered because what it returns can be a reference into an argument,
# and was not read. Whether its result is the plan's memory is not known, so the call is recorded
# as undecided and the result is marked as possibly the plan's.
function _unread_result(label::String, why::String, m::Method, chain::Vector{String}, out::Vector{_ConcViol}, seen::Set{String})
    _record!(
        out, seen, chain,
        "hands a plan-reachable value to `$label`, whose result may be the plan's memory — " *
            "not read ($why), so not established", _Frame(label, string(m.file), Int(m.line))
    )
    return :maybe
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
        _code_typed(f, types; optimize = true)
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
    # A position the call does not have names no argument, and an empty result would read as
    # "that argument is not written".
    1 <= self_arg <= length(types) || throw(
        ArgumentError(
            "concurrency_findings: self_arg = $self_arg is out of range for " *
                "`$(_func_name(f))$(_sig_string(types))`, which takes $(length(types)) argument(s)"
        )
    )
    _may_ref(types[self_arg]) || return out
    # A lock or a channel is written by every task that uses it; that is what it is for.
    _is_lock_type(types[self_arg]) && return out
    targs = Set{Int}((self_arg + 1,))   # user arg `self_arg` ↔ Core.Argument(self_arg+1)
    _taint_scan_ci(ci, targs, String[], fr, 0, max_depth, Dict{Any, Any}(), out, Set{String}())
    return out
end

# The records by what the scan established: a write it read, an atomic write (read, and
# deliberate), and a site it could not rule out. Each with its heading and the tag its entries carry.
function _conc_groups(vs::Vector{_ConcViol})
    writes = filter(v -> v.certain && !v.deliberate, vs)
    atomics = filter(v -> v.deliberate, vs)
    undecided = filter(v -> !v.certain && !v.deliberate, vs)
    return (
        ("Writes the scan read", "write", writes),
        ("Atomic writes, which cannot tear", "atomic", atomics),
        ("Sites the scan could not rule out", "undecided", undecided),
    )
end

_conc_counts(groups) = string(
    length(groups[1][3]), " write(s) the scan read, ",
    isempty(groups[2][3]) ? "" : string(length(groups[2][3]), " atomic write(s), "),
    length(groups[3][3]), " site(s) it could not rule out"
)

# Whether every record is an atomic write to a global: the scan read each one, and none is about
# the plan.
_only_global_atomics(vs::Vector{_ConcViol}) = all(v -> v.global_state && v.deliberate && v.certain, vs)

function _assert_concurrency_safe(target, @nospecialize(f), @nospecialize(types::Tuple); self_arg::Int = 1, max_depth::Int = 4)
    vs = concurrency_findings(f, types; self_arg, max_depth)
    isempty(vs) && return nothing
    io = IOBuffer()
    # The headline has to match what the scan actually established, or the warn path states as fact
    # the very thing the certainty split says it could not see.
    # Raise only on a write that is both READ by the scan and not a deliberate atomic one.
    sure = any(v -> v.certain && !v.deliberate, vs)
    groups = _conc_groups(vs)
    println(
        io,
        sure ?
            "writes state that concurrent tasks share (the plan argument, or a global) — NOT safe to " *
            "run concurrently" :
            _only_global_atomics(vs) ?
            "makes atomic writes to global state that every concurrent call shares; the plan " *
            "argument is not written. The writes cannot tear, and the state is still shared" :
            "cannot establish that the plan argument is read-only — sharing it across concurrent " *
            "tasks is unproven, not disproven",
        " (", _conc_counts(groups), "):"
    )
    # What the scan proved comes first and under its own heading: among dozens of sites it could
    # not rule out, the one or two it read are what the reader has to fix.
    first_group = true
    for (heading, tag, sites) in groups
        isempty(sites) && continue
        first_group || println(io)
        first_group = false
        print(io, "  ", heading, " (", length(sites), "):")
        for (i, v) in enumerate(sites)
            print(io, "\n  [", tag, " ", i, "] ", v.message)
            v.file != "" && print(io, "\n        at ", v.file, ":", v.line)
        end
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
dynamic dispatch is flagged conservatively. A Base function that is not inlined is read the same
way when its name ends in `!` or its result can be a reference into an argument, so `sort!(plan.buf)`
and `get(plan.cache, k, x)[1] = v` are writes and `copyto!(out, plan.buf)` is not.

A foreign call follows Go's rule for cgo: a C function is assumed to write through every pointer it
is given. `memmove`, `memcpy` and `memset` are known to write their destination, so a plan buffer
there is a write the scan read; a plan pointer handed to any other foreign function, a BLAS routine
included, is reported as one the scan could not rule out. A lock, condition or channel held by the
plan is not shared data: locking it is not a write to the plan. A `Threads.Atomic` held by the plan
is: writing it is reported as an `@atomic` field write is, as an atomic write that warns.

**Failing and warning are different outcomes here, and which one you get follows how sure the scan
is.** A write it READ — a store whose container is plan-reachable, a hand-off to a known Base
mutator, or a `memmove` into a plan buffer — raises `StrictViolation`. A record it could only *not
rule out* warns instead: a callee behind dynamic dispatch, a foreign function with no known effect,
a task body whose closure type did not resolve, or a chain that reached `max_depth` and stopped. So a real write far enough down the call chain warns rather than fails,
because the scan never saw it — raise `max_depth` to reach it, or assert on the inner method
directly.

The proof tier does not remove that uncertainty: no backend decides whether an argument is
written, so `StrictModeTest` runs this same scan and inherits the same split — an uncertain record
is informational there too. That is unlike `@test_noalloc`, where AllocCheck replaces the guess.

This is a **complementary static proof**, not a total one: it does no alias analysis (if the
scratch you pass secretly aliases plan-owned storage it will not notice), does not read a Base
function whose name carries no `!` and whose result holds no reference, and bounds recursion depth — so pair it with a runtime concurrency test.
It prefers false positives over a confident false pass. Value-free (no AllocCheck/JET backend);
each argument is evaluated once; disabled builds expand to the bare call.

Options: `@assert_concurrency_safe self=2 f(out, plan)` picks a different plan slot;
`max_depth=N` bounds interprocedural recursion (default 4).
"""
macro assert_concurrency_safe(args...)
    pos, opts = _macro_call("@assert_concurrency_safe", args, (:self, :max_depth, :types))
    self_arg = haskey(opts, :self) ? opts[:self]::Int : 1
    max_depth = haskey(opts, :max_depth) ? opts[:max_depth]::Int : 4
    isempty(pos) && throw(ArgumentError("@assert_concurrency_safe needs a call expression"))
    call = pos[1]
    # Checked here where the call is written out, so a wrong position is reported without running it.
    if Meta.isexpr(call, :call)
        _, argexprs, kwexprs = _callinfo(call)
        (isempty(kwexprs) && !haskey(opts, :types) && !(1 <= self_arg <= length(argexprs))) && throw(
            ArgumentError(
                "@assert_concurrency_safe: self = $self_arg is out of range for a call with " *
                    "$(length(argexprs)) positional argument(s)"
            )
        )
    end
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

# `:no_threadid_state` — flag `Threads.threadid()`-indexed MUTABLE state that is still in use after a
# point where the task can be suspended (`_held_across_suspension`, below): only there can another
# task run on this thread, or this one move to another. The write scan here finds the state; we
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
# Two documented limits. It does NOT track a threadid stashed into another array and reused later.
# And a lock STRIPED by thread (`lock(locks[threadid()])`) is reported: the
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
    # Base names the MPFR and GMP entry points by string: `("mpfr_add", libmpfr)`.
    fn isa String && (fn = Symbol(fn))
    return fn isa Symbol ? fn : nothing
end

function _is_threadid_foreigncall(st)
    fn = _fcall_name(st)
    return fn !== nothing && occursin("threadid", String(fn))
end

function threadid_state_findings(@nospecialize(f), @nospecialize(types::Tuple))
    out, code, tid, tidref, fr, argtype = _threadid_scan(f, types)
    isempty(out) && return out
    return _held_across_suspension(code, tid, tidref, out, fr; argtype)
end

# Every write to threadid-indexed state in the body, whether or not the state is still in use after a
# suspension point. `threadid_state_findings` keeps them only when it is.
_threadid_writes(@nospecialize(f), @nospecialize(types::Tuple)) = first(_threadid_scan(f, types))

function _threadid_scan(@nospecialize(f), @nospecialize(types::Tuple))
    cts = try
        _code_typed(f, types; optimize = true)
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
    writes_memo = Dict{Tuple{Core.MethodInstance, Int}, Bool}()   # the fixpoint revisits each call
    returns_memo = Dict{Tuple{Core.MethodInstance, Int}, Bool}()
    changed = true
    while changed
        changed = false
        for (i, st) in enumerate(code)
            mark(s::BitSet, b) = (b && !(i in s)) ? (push!(s, i); changed = true) : nothing
            if _is_threadid_foreigncall(st)
                mark(tid, true); continue
            elseif st isa Core.PiNode
                isdefined(st, :val) && _op_tainted(st.val, tid, ()) && mark(tid, true)
                isdefined(st, :val) && _op_tainted(st.val, tidref, ()) && mark(tidref, true)
                continue
            elseif st isa Core.PhiNode
                # A merge of a per-thread reference with anything else may still be the per-thread one.
                _any_phi_tainted(st, tid, ()) && mark(tid, true)
                _any_phi_tainted(st, tidref, ()) && mark(tidref, true)
                continue
            elseif Meta.isexpr(st, :new)
                # A struct built around a per-thread reference reaches it: an owner wrapper
                # `Owner(per_thread_arena)` handed on is the arena handed on.
                any(a -> _op_tainted(a, tidref, ()), @view st.args[2:end]) && mark(tidref, true)
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
            # A tuple holding a per-thread reference reaches it, as a struct built around one does.
            if nm === :tuple && any(a -> _op_tainted(a, tidref, ()), dataargs)
                mark(tidref, true)
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
            elseif isinvoke
                # A threadid-reachable value handed to a callee the optimizer left out of line: the
                # write, or the handle the caller then writes through, is in the callee. The
                # threadid is in the caller and the store in the callee, so neither signature alone
                # shows the hazard.
                mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
                mi isa Core.MethodInstance || continue
                for k in eachindex(dataargs)
                    _op_tainted(dataargs[k], tidref, ()) || continue
                    if get!(() -> _callee_writes_arg(mi, k), writes_memo, (mi, k))
                        _record!(
                            out, seen, String[],
                            "writes mutable state indexed by `Threads.threadid()` through `$nm` " *
                                "(argument $k) — unsafe under task migration; index by a captured " *
                                "task-local id or a per-task buffer instead", fr;
                            certain = true
                        )
                    end
                    get!(() -> _returns_argument(mi, k), returns_memo, (mi, k)) && mark(tidref, true)
                end
                continue
            end
        end
    end
    # The type an argument of a call statement has here, which a despecialized callee (`print_to_string`
    # takes `Vararg{Any}`) no longer records.
    function argtype(@nospecialize(a))
        a isa Core.SSAValue && return Core.Compiler.widenconst(sts[a.id])
        a isa Core.Argument && return ci.slottypes isa Vector ? Core.Compiler.widenconst(ci.slottypes[a.n]) : Any
        a isa GlobalRef && return (isdefined(a.mod, a.name) && isconst(a.mod, a.name)) ? Core.Typeof(getglobal(a.mod, a.name)) : Any
        return Core.Typeof(a isa QuoteNode ? a.value : a)
    end
    return (out, code, tid, tidref, fr, argtype)
end

# Per-thread state is shared only by tasks that RUN on the same thread, and Julia moves a task, or lets
# another run, only where it can be suspended: tasks are not preempted. A write to per-thread state is
# therefore a hazard when the state is still in use after such a point, and safe when it is claimed
# and released with none in between. So a body with writes is reported only when one of its
# threadid-derived values is defined before a suspension point and used after it, along a path of the
# control-flow graph; the writes are listed with that cause. Reported for certain when the suspension
# was read, and conservatively when a callee could not be read in full.
# Runtime entry points that switch tasks.
const _SUSPEND_FCALLS = (:jl_yield, :jl_switch, :jl_task_wait, :jl_wait_empty_begin)

# Base waits that suspend the task whenever they run: on another task, a timer or a condition.
const _SUSPEND_STRONG = (:yield, :yieldto, :wait, :_wait, :wait_forever, :sleep, :fetch, :timedwait)

# Base operations that suspend only on some objects: a lock that can block, IO on a device or a
# stream, a channel. On an `IOBuffer`, `devnull` or a `SpinLock` they never do.
const _SUSPEND_ON = (
    :lock, :take!, :acquire, :run, :print, :println, :write, :read, :readline, :readavailable,
    :readbytes!, :flush, :unsafe_read, :unsafe_write, :eof, :handle_message, :handle_message_nothrow,
)

# Building a string writes only to an `IOBuffer`.
const _STRING_BUILDERS = (:print_to_string, :string, :sprint, :repr, :_str_sizehint)

# Builtins that call a function given as an argument, whatever it does.
const _CALLING_BUILTINS = (:invokelatest, :_apply_iterate, :_call_latest, :invoke, :invoke_in_world)

_inert_target(@nospecialize(T)) =
    T isa Type && (T <: Base.Threads.SpinLock || T <: Base.GenericIOBuffer || T <: Base.DevNull)

# `:yes`, `:maybe` or `:no` for a Base operation in `_SUSPEND_ON`, from the type of the object it acts
# on: a concrete object it cannot block on is `:no`, an abstract one is `:maybe`.
function _suspends_on(@nospecialize(T))
    T isa Type || return :maybe
    _inert_target(T) && return :no
    return isconcretetype(T) ? :yes : :maybe
end

# Callee signature and world => :yes, :maybe or :no. The world is part of the key because the reach
# follows run-time dispatch, which a method defined anywhere can change.
const _SUSPEND_MEMO = Dict{Tuple{Any, UInt}, Symbol}()
const _SUSPEND_LOCK = ReentrantLock()

# Whether a callee can suspend, from the Base functions its call graph reaches. The graph names a
# function, not the object it acts on, so an operation in `_SUSPEND_ON` reached there is `:maybe`.
function _sig_may_suspend(@nospecialize(sig))
    key = (sig, Base.get_world_counter())
    hit = @lock _SUSPEND_LOCK get(_SUSPEND_MEMO, key, nothing)
    isnothing(hit) || return hit
    r = try
        _reach(sig, Set{Tuple{Module, Symbol}}())
    catch
        nothing
    end
    v = if isnothing(r)
        :maybe
    elseif any(k -> k[2] in _SUSPEND_STRONG && _sw_is_base(k[1]), keys(r.found))
        :yes
    elseif any(k -> k[2] in _SUSPEND_ON && _sw_is_base(k[1]), keys(r.found)) || r.unread > 0 || r.dynamic > 0
        :maybe
    else
        :no
    end
    @lock _SUSPEND_LOCK (_SUSPEND_MEMO[key] = v)
    return v
end

# How a statement can suspend the task: `:yes`, `:maybe` (a call the scan cannot read in full, such as
# dynamic dispatch or an operation on an abstract object) or `:no`.
function _stmt_suspends(@nospecialize(st), code::Vector{Any}, argtype = _ -> Any)
    if Meta.isexpr(st, :foreigncall)
        return _fcall_name(st) in _SUSPEND_FCALLS ? :yes : :no
    elseif Meta.isexpr(st, :invoke)
        mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
        (mi isa Core.MethodInstance && mi.def isa Method) || return :maybe
        m = mi.def
        if _sw_is_base(m.module)
            nm = _demangle(m.name)
            # Building a string runs the `show` of each argument, which for a type outside Base is
            # user code that may suspend; only an all-Base argument list is known not to.
            # Judged by the argument types at this call, since a despecialized builder has lost them.
            site = Tuple{Any[argtype(a) for a in st.args[2:end]]...}
            nm in _STRING_BUILDERS && return _carries_user_type(site) ? _sig_may_suspend(site) : :no
            nm in _SUSPEND_STRONG && return :yes
            if nm in _SUSPEND_ON
                ps = mi.specTypes.parameters
                length(ps) >= 2 || return :maybe
                on = _suspends_on(ps[2])
                # Writing a value to an inert target still runs that value's `show`, which for a
                # type outside Base is user code.
                (on === :no && any(_carries_user_type, site.parameters[3:end])) && return _sig_may_suspend(site)
                return on
            end
            # A Base once-guard's one-time init locks, but it is Base's own path to the per-thread
            # slot rather than a use of state the caller holds. A user-registered barrier is not
            # exempt: it is the caller's own code.
            _mi_is_barrier(mi) && return :no
        end
        return _sig_may_suspend(mi.specTypes)
    elseif Meta.isexpr(st, :call)
        v = _sw_callee_value(st.args[1])
        if v isa Core.Builtin || v isa Core.IntrinsicFunction
            nameof(v) in _CALLING_BUILTINS || return :no
            # It calls whatever it is handed: a known wait suspends, anything else may.
            for a in @view st.args[2:end]
                g = _sw_callee_value(a)
                g isa Function && _sw_is_base(parentmodule(g)) && nameof(g) in _SUSPEND_STRONG && return :yes
            end
            return :maybe
        end
        isnothing(v) && return :maybe
        v isa Function && _sw_is_base(parentmodule(v)) && nameof(v) in _SUSPEND_STRONG && return :yes
        return :maybe                       # dynamic dispatch the scan cannot resolve
    end
    return :no
end

function _held_across_suspension(
        code::Vector{Any}, tid::BitSet, tidref::BitSet, writes::Vector{_ConcViol}, fr::_Frame;
        argtype = _ -> Any,
    )
    tainted = union(tid, tidref)
    cfg = Core.Compiler.compute_basic_blocks(code)
    blk = [Core.Compiler.block_for_inst(cfg, i) for i in eachindex(code)]
    succs(b) = cfg.blocks[b].succs
    # Is the value defined at `d` still the value used at `u`, on a path from `s`? In SSA a definition
    # inside a loop is a fresh value each iteration, so a path that runs through `d` again reaches a
    # different value: `u` must be reachable from `s` without passing `d`.
    function live_from(d::Int, s::Int, u::Int)
        bd, bs, bu = blk[d], blk[s], blk[u]
        if bs == bu && s < u
            return !(bd == bs && s < d < u)
        end
        bd == bs && d > s && return false       # `d` redefines before control leaves `s`'s block
        seenb = falses(length(cfg.blocks)); stack = copy(succs(bs))
        while !isempty(stack)
            b = pop!(stack); seenb[b] && continue; seenb[b] = true
            if b == bu
                (b != bd || u < d) && return true
            end
            b == bd && continue                 # passing the definition starts a new value
            append!(stack, succs(b))
        end
        return false
    end
    reaches(i, j) = (blk[i] == blk[j] && i < j) || (
        begin
            seenb = falses(length(cfg.blocks)); stack = copy(succs(blk[i])); found = false
            while !isempty(stack) && !found
                b = pop!(stack); seenb[b] && continue; seenb[b] = true
                found = b == blk[j]; append!(stack, succs(b))
            end
            found
        end
    )
    # Where each tainted value is used. A phi uses its incoming value on the edge it arrives by, so the
    # use is placed at that edge's last statement, not at the phi: a value that arrives only on the
    # loop's entry edge is not used after a suspension the back edge carries.
    uses = Dict{Int, Vector{Int}}()
    function adduses!(@nospecialize(x), at::Int)
        return if x isa Core.SSAValue
            x.id in tainted && push!(get!(Vector{Int}, uses, x.id), at)
        elseif x isa Expr
            foreach(a -> adduses!(a, at), x.args)
        elseif x isa Core.PiNode
            adduses!(x.val, at)
        elseif x isa Core.PhiNode
            for j in eachindex(x.values)
                isassigned(x.values, j) && adduses!(x.values[j], Int(x.edges[j]))
            end
        elseif x isa Core.ReturnNode && isdefined(x, :val)
            adduses!(x.val, at)
        end
    end
    for (i, st) in enumerate(code)
        adduses!(st, i)
    end
    for (s, st) in enumerate(code)
        kind = _stmt_suspends(st, code, argtype)
        kind === :no && continue
        for d in tainted
            d == s && continue
            ds = get(uses, d, Int[])
            reaches(d, s) || continue
            used_after = any(u -> u != s && live_from(d, s, u), ds)
            # A reference to the state handed to the suspending call: Base's own wait holds what it is
            # given, while a callee of the package may or may not still hold it when it suspends.
            handed = !used_after && s in ds && d in tidref
            (used_after || handed) || continue
            how = handed && !(Meta.isexpr(st, :invoke) && _sw_is_base(_invoke_module(st))) ? :maybe : kind
            nm = Meta.isexpr(st, :invoke) ? _resolve_callee_name(st.args[2], code) :
                Meta.isexpr(st, :call) ? _resolve_callee_name(st.args[1], code) : _fcall_name(st)
            what = isnothing(nm) ? "a call" : "`$(_demangle(nm))`"
            msg = "holds per-thread (`Threads.threadid()`-indexed) state across $what, which " *
                (how === :yes ? "can suspend the task" : "may suspend the task (not read in full)") *
                ": another task can then run on this thread and use the same state"
            # The writes are certain, but the hazard is as certain as its suspension and no more.
            sure = how === :yes
            return [
                _ConcViol(msg, fr.file, fr.line, sure, false);
                [_ConcViol(w.message, w.file, w.line, sure && w.certain, w.deliberate) for w in writes]
            ]
        end
    end
    return _ConcViol[]
end

function _invoke_module(st::Expr)
    mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
    return (mi isa Core.MethodInstance && mi.def isa Method) ? mi.def.module : Main
end

# Whether the callee `mi` writes its argument `k`, by the concurrency scan's own reading of a write
# to a chosen argument — which follows its callees and raw pointers in turn. Only a write it READ
# counts: this guarantee gates, and a conservative record for a callee it could not resolve would
# make an unreadable helper fail the caller.
function _callee_writes_arg(mi::Core.MethodInstance, k::Int)
    ps = mi.specTypes.parameters
    (!isempty(ps) && ps[1] isa DataType && isdefined(ps[1], :instance)) || return false
    vs = try
        concurrency_findings(ps[1].instance, Tuple(ps[2:end]); self_arg = k, max_depth = 3)
    catch
        return false
    end
    return any(v -> v.certain, vs)
end

# Whether the callee `mi` returns its argument `k`, or a reference projected out of it, so that the
# caller's store into the returned value writes the argument.
function _returns_argument(mi::Core.MethodInstance, k::Int)
    cts = try
        _code_typed_by_type(mi.specTypes; optimize = true)
    catch
        return false
    end
    length(cts) == 1 || return false
    ci = first(cts[1])
    code = ci.code
    sts = ci.ssavaluetypes
    arg = Core.Argument(k + 1)
    t = BitSet()
    is_t(a) = a == arg || (a isa Core.SSAValue && a.id in t)
    changed = true
    while changed
        changed = false
        for (i, st) in enumerate(code)
            i in t && continue
            hit = if st isa Core.PiNode
                isdefined(st, :val) && is_t(st.val)
            elseif st isa Core.PhiNode
                any(j -> isassigned(st.values, j) && is_t(st.values[j]), eachindex(st.values))
            elseif Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke)
                isinv = st.head === :invoke
                nm = _resolve_callee_name(isinv ? st.args[2] : st.args[1], code)
                da = isinv ? st.args[3:end] : st.args[2:end]
                p = isnothing(nm) ? 0 : get(_PROJECT_OPS, nm, 0)
                1 <= p <= length(da) && is_t(da[p]) && sts isa Vector && _may_ref(sts[i])
            else
                false
            end
            hit && (push!(t, i); changed = true)
        end
    end
    return any(st -> st isa Core.ReturnNode && isdefined(st, :val) && is_t(st.val), code)
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
    # Raises only where the suspension was read; one through a callee it could not read warns.
    _fail(:no_threadid_state, target, String(take!(io)); gates = any(v -> v.certain, vs))
    return nothing
end

"""
    @assert_no_threadid_state f(args...)

Fail if `f` writes **mutable state indexed by `Threads.threadid()`** and that state is still in use
after a point where the task can be suspended (best-effort, value-free IR scan). Julia does not
preempt a task: it moves one to another thread, or lets another run on its thread, only where it can
be suspended — a `yield`, `wait`, `sleep`, `fetch`, `take!`, a lock that may block, or a call that
reaches one. So `i = threadid(); yield(); buf[i] += 1` is a data race, two tasks writing the same
slot, while `buf[threadid()] += 1` with no such point in between is not. Callees are followed for
the suspension point, as for the write; one the scan could not read in full is reported without
gating. Prefer a per-task buffer, looked up where the task starts and passed down.

Detects a store to `buf[threadid()]`, and a store into an object loaded out of such a slot —
`buf[threadid()].field = …`, `buf[threadid()][i] = …`, `rand(rngs[threadid()])`. A scalar read out
of a slot and stored elsewhere is a copy, not the hazard, and stays clean.

A slot's value handed to a callee the optimizer left out of line is followed: a callee that writes
it is reported, and so is a store into a value the callee returns when that value is its argument.
A callee that only reads it, or returns a fresh copy, stays clean. It does not track a threadid
stashed into another array and reused later. A lock
striped by thread (`lock(locks[threadid()])`) IS reported — the inlined fast path writes a field of
a lock chosen by `threadid()`. That is not a data race, because a `ReentrantLock` belongs to the
task rather than the thread, but striping locks by thread buys nothing once tasks migrate.

Not part of [`@strict`](@ref). Disabled builds expand to the bare call.
"""
macro assert_no_threadid_state(args...)
    pos, opts = _macro_call("@assert_no_threadid_state", args, (:types,))
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
# `wait`/`notify` are not counted: on a `Threads.Event` or a `Condition` they signal rather than
# hold anything, and the two halves normally live in different functions — a worker waits, the
# driver notifies — so counting them reported every worker loop as unbalanced.
const _POOL_TAKE = Set{Symbol}((:take!, :acquire, :lock))
const _POOL_PUT = Set{Symbol}((:put!, :release, :unlock))

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
        _code_typed(f, types; optimize = false)   # keep source-level `take!`/`put!` names
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
    if fail && !any(v -> v.certain, vs)
        # The suspension was not read in full: a lead, not a verdict.
        return StrictFinding(
            md, fn, sg, :no_threadid_state, :info, vs[1].file, vs[1].line,
            "cannot rule out threadid-indexed state held across a suspension ($(length(vs)) site(s)): " *
                join((v.message for v in vs), "; "),
            "index by a captured task-local id, or give each task its own buffer", tier,
            _code(:no_threadid_state)
        )
    end
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

# The position in `types` of a method's OWN first argument.
#
# Julia's keyword lowering splits one `f(x; k)` definition into a thin wrapper and a mangled body,
# and the mangled body's leading arguments belong to the lowering: the keyword values, then the
# function object, and only then the arguments the author wrote. Position 1 there is a keyword
# value, so reading it answers a question about a keyword and leaves the argument the guarantee is
# about unexamined — a verdict of `pass` on a method nothing looked at. The function object marks
# the boundary: its type is the one argument whose singleton instance answers to the demangled name.
function _self_arg_position(@nospecialize(f), @nospecialize(types::Tuple))
    nm = try
        nameof(f)
    catch
        return 1
    end
    base = _demangle(nm)
    base === nm && return 1
    for (i, p) in enumerate(types)
        p isa DataType && isdefined(p, :instance) || continue
        p.instance isa Function && nameof(p.instance) === base && return i + 1
    end
    # A closure or an `@strict_stable` inner body carries its captures in the function object
    # itself, not in an argument, so position 1 is already the author's first argument.
    return 1
end

# `:concurrency_safe`'s verdict for one signature, shared by BOTH tiers through
# `_compiled_output_finding`. No backend has anything to add: AllocCheck, JET and TrimCheck say
# nothing about whether an argument is written.
#
# The status follows the records' certainty, which is the same rule `_assert_concurrency_safe`
# applies: a write this scan READ is `:fail`, and a record it only failed to rule out is `:info`.
# A sweep cannot be told which argument holds the plan, so it reads the method's own first argument
# — which is why `:concurrency_safe` is absent from the `:all` policy set and cannot stop a module
# loading.
function _concurrency_safe_finding(
        @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg; tier::Symbol = :report
    )
    self = _self_arg_position(f, types)
    # The convention is a property of the name the author wrote, and a mangled body carries the
    # same name with the lowering's decoration around it.
    bang = endswith(String(_demangle(Symbol(fn))), "!")
    # A method with no argument at that position shares nothing a call could write.
    self <= length(types) || return _mkfinding(
        md, fn, sg, :concurrency_safe, false,
        "takes no argument that could be shared (value-free IR scan)", "", 0; tier
    )
    vs = try
        concurrency_findings(f, types; self_arg = self)
    catch
        nothing
    end
    loc = _method_loc(f, types)
    isnothing(vs) && return _unevaluated(
        md, fn, sg, :concurrency_safe, "the concurrency scan could not read this signature";
        tier, file = loc[1], line = loc[2]
    )
    isempty(vs) && return _mkfinding(
        md, fn, sg, :concurrency_safe, false,
        "argument $self is not written (value-free IR scan)", "", 0; tier
    )
    # A `!` name DECLARES that the first argument is written — `mul!(C, A, B)`, `copyto!(dest,
    # src)` — so finding that write is not finding a defect, it is reading the convention back. The
    # sweep cannot be told which argument holds the shared object, so for these it cannot ask the
    # question the guarantee is about, and it says so as `:info` rather than failing. It must not
    # report `:pass`: "could not check here" and "is read-only" are different answers. Measured in
    # the field before this: 92 of 134 sweep failures on one package were `!` methods writing their
    # own first argument, which buried the 42 that were not.
    if bang
        return StrictFinding(
            md, fn, sg, :concurrency_safe, :info, vs[1].file, vs[1].line,
            "a `!` name declares that argument $self is written, so the sweep cannot tell a " *
                "shared plan from the intended output ($(length(vs)) site(s))",
            "assert this at a call site with `@assert_concurrency_safe self=N f(…)`, naming the " *
                "argument that is actually shared across tasks",
            tier, _code(:concurrency_safe)
        )
    end
    certain = any(v -> v.certain && !v.deliberate, vs)
    groups = _conc_groups(vs)
    # Located at a write the scan read when there is one, and the writes are listed first.
    at = certain ? groups[1][3][1] : vs[1]
    listed = String[]
    for (_, tag, sites) in groups, (i, v) in enumerate(sites)
        push!(listed, "[" * tag * " " * string(i) * "] " * v.message)
    end
    return StrictFinding(
        md, fn, sg, :concurrency_safe, certain ? :fail : :info,
        at.file, at.line,
        (
            certain ? "argument $self is written during the call (" :
                _only_global_atomics(vs) ?
                "argument $self is not written; global state every concurrent call shares is " *
                "written atomically (" :
                "cannot prove argument $self is read-only ("
        ) * _conc_counts(groups) * "): " * join(listed, "; "),
        _suggestion(:concurrency_safe), tier, _code(:concurrency_safe)
    )
end
