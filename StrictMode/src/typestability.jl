# `@assert_typestable` — fail on type instability. Two layers, graded differently:
#   - return-type concreteness via `Base.return_types` — exact for the question it asks, so it gates.
#   - a depth-0 IR boxing signal — a heuristic, so it reports.
# JET's optimization analysis is the proof and lives in `StrictModeTest`'s `@test_typestable`.

# Union{T,Nothing} and other small isbits unions don't box; treat as type-stable (F21).
_is_typestable_return(@nospecialize(T)) = isconcretetype(T) || Base.isbitsunion(T)

# Cheap return-type check: the inferred return type must be a single concrete type. Also checks
# the IR boxing signal (F38): a concrete return can hide internal runtime dispatch — the same
# blind spot `_findings_fast`'s :typestable branch (check.jl) already closed for the batch API,
# which this macro-level fast check had been missing.
#
# DEPTH-0 (this-level only) for the boxing signal: type stability is a property of THIS function's
# own IR. A direct dynamic `:call` (an abstract callee/result in THIS body — F38's `c.f(1)`) is a
# real instability; a resolved `:invoke` to a callee that boxes internally is NOT — the call itself
# is statically dispatched, and if its abstract result is narrowed (e.g. the complex `_l3ws` IdDict
# `get!` behind a `::L3Workspace{T}` assert) the caller stays stable. JET's :full opt-analysis agrees
# (it flags dynamic dispatch, not resolved invokes). Depth-2 (the noalloc/noboxing depth, which counts
# a callee's runtime cost) over-flagged concrete-return callers of boxy helpers. See check.jl.
# `Base.return_types` runs inference and builds a result vector on every call. The guarantee macros
# run their check at every EXECUTION of a call site, so an un-memoized call here is paid per
# iteration of any loop containing one — measured at 3,872 of the 4,528 bytes a `@strict` site cost
# per call, 85% of the total (issue #29). That allocation lands in the CALLER's body, so a consumer
# cannot measure the very allocation-freedom `@strict` is about without building a second Julia
# process with checks off.
#
# Cached on the same terms as `_TOP_SIGNAL_MEMO`: identity on the signature (concrete signature
# `DataType`s are interned, and `hash(::DataType)` walks the whole type), keyed by world age so any
# new method definition invalidates. Cleared by `clear_cache!` with the other memos.
const _RETTYPE_MEMO = IdDict{Any, Dict{UInt64, Vector{Any}}}()

function _return_types_memo(@nospecialize(f), @nospecialize(types::Tuple))
    sig = Base.signature_type(f, Tuple{types...})
    world = Base.get_world_counter()
    memo = @lock _SIGNAL_MEMO_LOCK begin
        bysig = get(_RETTYPE_MEMO, sig, nothing)
        isnothing(bysig) ? nothing : get(bysig, world, nothing)
    end
    isnothing(memo) || return memo
    rts = Base.return_types(f, Tuple{types...})
    @lock _SIGNAL_MEMO_LOCK get!(Dict{UInt64, Vector{Any}}, _RETTYPE_MEMO, sig)[world] = rts
    return rts
end

function _typestable_fast(target, @nospecialize(f), @nospecialize(types::Tuple))
    rts = _return_types_memo(f, types)
    if length(rts) != 1 || !_is_typestable_return(only(rts))
        rt = isempty(rts) ? "none" : (length(rts) == 1 ? string(only(rts)) : string(rts))
        _fail(:typestable, target, "return type is not concrete or isbits-union (inference): $rt")
        return nothing
    end
    # The two layers are graded separately. Return-type concreteness above is exact for the
    # question it asks, so it gates. This one is an IR signal: a guarded `@warn` inside an
    # otherwise-clean numeric function reads as depth-0 boxing while JET's optimization analysis
    # passes it, and that shape must not be able to abort a build.
    sig = _alloc_signals(f, types; depth = 0)
    if sig.boxing
        _fail(
            :typestable, target, "internal dynamic dispatch (concrete return; fast IR heuristic)";
            gates = false
        )
    end
    # F39. A union-typed local whose members do not all ride unboxed is a type instability the
    # return type cannot show — the return stays concrete while a value is boxed to flow through the
    # phi. It reports rather than gates for the same reason the line above does: it is an IR signal.
    #
    # It belongs here and NOT in `:noalloc`. The claim "this local is union-typed with a
    # box-on-entry member" holds at every signature, because the union comes from branch structure;
    # "it allocates" does not, since LLVM elides the box for members that are already pointers. Wiring
    # it into an allocation verdict would red provably-0 B kernels, which is issue #17 all over again.
    if sig.unionphi
        _fail(
            :typestable, target,
            "a union-typed local carries a member that must be boxed to flow through it — the " *
                "return type is concrete, but a value is heap-boxed on the way into that union";
            gates = false
        )
    end
    return nothing
end

# The type-stability *check* expression (no value). Shared by `@assert_typestable` and `@strict`.
function _typestable_check_expr(target, fe, types)
    return :($(_typestable_fast)($target, $fe, $types))
end

# Guarded form, for the macros that expand a call site. `_typestable_fast` reads only the signature.
function _typestable_guarded_expr(p, target)
    return _guarded_check(p, _typestable_check_expr(target, p.checkfn, p.types))
end

"""
    @assert_typestable f(args...)
    @assert_typestable f(args...; kw...)
    @assert_typestable f(args...) types=(T1, T2, …)

Fail unless `f(args...)` is type stable.

Two layers, graded differently. The inferred return type must be a single concrete type
(`Base.return_types`) — that is exact for the question it asks, so a violation **throws**.

On top of that sit two IR signals (`StrictMode._alloc_signals`), both heuristics, so both **warn**:

- **internal dynamic dispatch** behind a concrete return — the classic "the return type is fine but
  something inside dispatches at runtime" shape. A guarded `@warn` in an otherwise-clean numeric
  function trips it.
- **a union-typed local that boxes a member on the way in** — a `PhiNode` whose union is not an
  isbits union, so at least one member must be heap-allocated to flow through it. Union splitting
  is not dynamic dispatch, so JET cannot see this one at all.

`StrictModeTest`'s `@test_typestable` adds JET's optimization analysis, which is the proof for the
first signal and does throw; for the second it consults this scan, since JET is blind to it.

Each argument is evaluated once, the macro returns the call's value, and disabled builds expand to
the bare call.

**Keyword arguments** are supported: `f(x; k=v)` is checked at its real specialization (the call is
routed through `Core.kwcall`, so the keyword sorter's signature is what inference sees).

**`types = (…)`** pins the inference signature explicitly instead of deriving it from
`typeof.(args)`. Use it for type-argument functions, where `typeof(Float64) == DataType` would
otherwise widen the result to a non-concrete type and false-positive.

```julia
@assert_typestable muladd(2.0, 3.0, 1.0)          # ok
@assert_typestable pick(heterogeneous_tuple, i)   # throws: Union from runtime tuple index
@assert_typestable scale(x; by=2)                 # ok: keyword call checked as-is

g(::Type{T}) where {T} = Vector{T}(undef, 1)
@assert_typestable g(Float64)                     # false positive: `Vector` (DataType widened `T`)
@assert_typestable g(Float64) types=(Type{Float64},)   # ok: pinned to the real specialization
```
"""
macro assert_typestable(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_typestable needs a call expression"))
    call = pos[1]
    target = string(call)
    p = _call_parts(call; types = get(opts, :types, nothing))

    checked = quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_typestable_guarded_expr(p, target))
        _val
    end
    return _gate(checked, esc(call))
end
