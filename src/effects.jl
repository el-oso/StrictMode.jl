# Cheap, value-free analysis built only on Base inference — no AllocCheck/JET backend. This is
# what makes `:fast` mode a quick all-properties triage: a `code_typed` IR scan for allocation /
# boxing signals, plus `Base.infer_effects`. `:full` mode keeps AllocCheck's rigorous proof.
#
# The heuristic is intentionally approximate (the user opted into "fast triage, may rarely
# miss/over-flag"): it catches explicit heap allocation and the boxing/dispatch class, which
# covers the common cases, but cannot match AllocCheck's LLVM-level precision.

# Runtime-call targets that allocate (matched as substrings, case-insensitive).
const _ALLOC_FFI = ("alloc", "gc_pool", "gc_big", "jl_box", "ijl_box", "new_array", "alloc_string")

_nonconcrete(@nospecialize T) = T isa Type && !Base.isconcretetype(T) && T !== Union{} && !(T <: Type)

# An abstract-`eltype` container — e.g. `Vector{AbstractFoo}` (often grown with `push!` of concrete
# subtypes). The container *type* is concrete, but its *elements* are abstractly typed, so indexing /
# iterating yields abstract values and any method called on them dynamically dispatches. A classic speed
# + `--trim` anti-pattern, and one the result-type boxing heuristic *misses* when the dispatched method
# returns a concrete type (e.g. `f(::AbstractFoo)::Float64`) — so it is worth flagging from the IR directly.
# Only an *abstract type* / `Any` element is flagged; a small splittable `Union` element is not.
function _abstract_container(@nospecialize T)
    (T isa Type && (T <: AbstractArray || T <: Memory) && Base.isconcretetype(T)) || return false
    et = eltype(T)
    return et isa Type && (isabstracttype(et) || et === Any)
end

# A union the optimizer union-splits rather than boxes: few members, all concrete. Members may be
# heap types (Union{Nothing, Vector{Int}} splits fine) — splitting is about member COUNT, not isbits.
function _splittable_union(@nospecialize T)
    T isa Union || return false
    uts = Base.uniontypes(T)
    return length(uts) <= 4 && all(u -> u isa Type && (isconcretetype(u) || u === Union{}), uts)
end

# Abstract-and-not-splittable: the result/argument shapes that mean real runtime dispatch/boxing.
_boxy(@nospecialize T) = _nonconcrete(T) && !_splittable_union(T)

# Inferred type of a `:call`/`:invoke` argument inside `ci` (SSAValue / Argument / literal).
# Optimized `code_typed_by_type` output often has `slottypes === nothing`, so `Argument`s fall
# back to the signature (`sig.parameters[n]`) — falling back to `Any` there flagged every
# non-builtin call on argument values as boxing (18 FPs on pure pointer kernels).
function _stmt_arg_type(ci, @nospecialize(sig), @nospecialize(a))
    a isa Core.SSAValue && return ci.ssavaluetypes[a.id]
    if a isa Core.Argument
        ci.slottypes === nothing || return ci.slottypes[a.n]
        ps = Base.unwrap_unionall(sig).parameters
        return a.n <= length(ps) ? ps[a.n] : Any
    end
    a isa GlobalRef && return isconst(a.mod, a.name) ? Core.Typeof(getglobal(a.mod, a.name)) : Any
    a isa QuoteNode && return Core.Typeof(a.value)
    a isa Expr && return Any
    return Core.Typeof(a)
end

# Resolve a `:call` callee to a value when statically possible (to skip Core builtins/intrinsics,
# which take `Any` arguments without dispatching).
function _static_callee(ci, @nospecialize(a))
    a isa GlobalRef && isconst(a.mod, a.name) && return getglobal(a.mod, a.name)
    a isa QuoteNode && return a.value
    a isa Function && return a
    return nothing
end

"""
    _alloc_signals(f, types; depth = 2) -> (; alloc, boxing, abscontainer, file, line)

Value-free allocation heuristic from optimized typed IR (no execution, no backend). `alloc` flags
explicit heap allocation (`:new` of a mutable/Array/`Core.Box` type, or a GC/box `:foreigncall`),
**following non-inlined `:invoke` callees to `depth` levels** (allocations in a non-inlined helper
— a grow path, a string build — are real allocations of the caller). `boxing` flags the boxing /
dynamic-dispatch subclass:

- a `:call`/`:invoke` with an abstract, non-union-splittable result (e.g. a runtime tuple index,
  an un-`Val`ed `ntuple`), or
- a dynamic `:call` (non-builtin) taking an abstract, non-union-splittable **argument** even when
  its own result is concrete — the "internal dispatch with a concrete return" blind spot.

A small all-concrete `Union` result stays unflagged (union-split, not boxing — flagging those
over-reported on type-stable SIMD/pointer kernels). Location is the method's definition site.
"""
function _alloc_signals(@nospecialize(f), @nospecialize(types::Tuple); depth::Int = 2)
    sig = Base.signature_type(f, Tuple{types...})
    alloc, boxing, abscontainer = _signals_by_type(sig, depth, Set{Any}())
    m = try
        which(f, types)
    catch
        nothing
    end
    file = m === nothing ? "" : string(m.file)
    line = m === nothing ? 0 : Int(m.line)
    return (; alloc, boxing, abscontainer, file, line)
end

# Per-statement "this straight-line region ends in an unreachable return" mask — the throw-path
# approximation of AllocCheck's `ignore_throw = true`: error branches build messages/exceptions
# (real allocations, but never taken on the success path), and `:full` doesn't count them, so the
# heuristic must not either. A region is [previous terminator + 1 .. terminator]; it is dead-end
# when its terminator is `ReturnNode()` with no value (= unreachable, i.e. after a throw).
function _deadend_mask(code::Vector{Any})
    dead = falses(length(code))
    start = 1
    for (i, st) in enumerate(code)
        if st isa Core.ReturnNode || st isa Core.GotoNode || Meta.isexpr(st, :gotoifnot) || st isa Core.GotoIfNot
            if st isa Core.ReturnNode && !isdefined(st, :val)
                dead[start:i] .= true
            end
            start = i + 1
        end
    end
    return dead
end

# Session memo for the per-signature scan: the callee recursion re-visits shared helpers (Base
# internals especially) from every caller, and each visit pays a `code_typed_by_type`. Without
# this, `:fast`'s median went 2.9 ms → 73 ms on the corpus study. Invalidated with the findings
# cache (`clear_cache!` / the Revise extension) — same staleness contract.
const _SIGNAL_MEMO = Dict{Any, Tuple{Bool, Bool, Any}}()
const _SIGNAL_MEMO_LOCK = ReentrantLock()

function _signals_by_type(@nospecialize(sig), depth::Int, seen::Set{Any})
    sig in seen && return (false, false, nothing)
    push!(seen, sig)
    key = (sig, depth, Base.get_world_counter())   # any new method definition invalidates (coarse, safe)
    memo = @lock _SIGNAL_MEMO_LOCK get(_SIGNAL_MEMO, key, nothing)
    memo === nothing || return memo
    r = _signals_by_type_uncached(sig, depth, seen)
    @lock _SIGNAL_MEMO_LOCK _SIGNAL_MEMO[key] = r
    return r
end

function _signals_by_type_uncached(@nospecialize(sig), depth::Int, seen::Set{Any})
    cts = try
        Base.code_typed_by_type(sig; optimize = true)
    catch
        return (false, false, nothing)
    end
    isempty(cts) && return (false, false, nothing)
    ci, _ = first(cts)
    alloc = false
    boxing = false
    abscontainer = nothing            # the abstract element type of the first abstract-eltype container seen
    dead = ignore_throw() ? _deadend_mask(ci.code) : falses(length(ci.code))
    for (i, st) in enumerate(ci.code)
        local T = ci.ssavaluetypes[i]
        if abscontainer === nothing && _abstract_container(T)
            abscontainer = eltype(T)
        end
        if Meta.isexpr(st, :foreigncall)
            dead[i] && continue
            tgt = lowercase(string(st.args[1]))
            any(p -> occursin(p, tgt), _ALLOC_FFI) && (alloc = true)
        elseif Meta.isexpr(st, :new)
            dead[i] && continue
            nt = st.args[1]
            (nt isa Type && (ismutabletype(nt) || nt <: Array || nt <: Memory || nt === Core.Box)) && (alloc = true)
        elseif Meta.isexpr(st, :invoke)
            # A resolved `:invoke` is never dispatch (F9) — even with an abstract recorded result
            # (mutating helpers with an unused return are typed `Any`). Boxing shows up where the
            # value is *used*: a downstream dynamic `:call` (result or argument rule below).
            if !alloc && !dead[i] && depth > 0
                a1 = st.args[1]
                mi = a1 isa Core.CodeInstance ? a1.def : a1
                if mi isa Core.MethodInstance
                    a2, _, _ = _signals_by_type(mi.specTypes, depth - 1, seen)
                    a2 && (alloc = true)
                end
            end
        elseif Meta.isexpr(st, :call)
            callee = _static_callee(ci, st.args[1])
            if callee === Core.memorynew           # 1.12 `Memory` allocation is a builtin :call
                dead[i] || (alloc = true)
            elseif _nonconcrete(T)
                # A *dynamic* call with any non-concrete result boxes — including a small union
                # (the founding runtime-tuple-index trap): union-split is a resolved-callee
                # (`:invoke`) optimization, it does not save a dynamic `:call`.
                boxing = true
            elseif !boxing
                # Concrete result but a boxy argument on a non-builtin call = runtime dispatch
                # that inference resolved only by return type (e.g. `Vec{32,UInt8}(::Tuple{Vararg})`).
                if !(callee isa Core.Builtin || callee isa Core.IntrinsicFunction)
                    any(a -> _boxy(_stmt_arg_type(ci, sig, a)), st.args[2:end]) && (boxing = true)
                end
            end
        end
    end
    return (alloc, boxing, abscontainer)
end

# --- Base.infer_effects layer (cheap; basis for @assert_effects in Phase 3) -------------------

"""
    StrictMode.effects(f, types) -> Core.Compiler.Effects

The compiler's inferred effects for `f`'s signature — a cheap (inference-only) read of whether a
method is `:nothrow`, `:effect_free`, `:terminates`, `:consistent`, etc. Used by the `:fast`
triage and by `@assert_effects`.
"""
effects(@nospecialize(f), @nospecialize(types::Tuple)) = Base.infer_effects(f, types)

# Predicate by symbol, so callers can ask `effect_holds(eff, :nothrow)`.
function effect_holds(eff, sym::Symbol)
    sym === :nothrow && return Core.Compiler.is_nothrow(eff)
    sym === :effect_free && return Core.Compiler.is_effect_free(eff)
    sym === :terminates && return Core.Compiler.is_terminates(eff)
    sym === :consistent && return Core.Compiler.is_consistent(eff)
    sym === :nonoverlayed && return Core.Compiler.is_nonoverlayed(eff)
    throw(ArgumentError("unknown effect :$sym; expected :nothrow, :effect_free, :terminates, :consistent, or :nonoverlayed"))
end
