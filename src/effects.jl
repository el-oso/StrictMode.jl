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

# Is `st` a `Core.getfield(receiver, field, ...)` call whose FIELD/INDEX argument is a
# compile-time constant (a literal `Symbol`/`Int` or `QuoteNode`), as opposed to a runtime value
# (an `SSAValue`/`Argument` — a Phi-fed loop variable, say)? A constant field/index always reads
# the SAME fixed memory location no matter how loosely-typed that location is, so it never itself
# allocates. A runtime-computed index into a heterogeneous `Tuple` genuinely can vary in type by
# value (the founding runtime-tuple-index boxing trap) and must NOT be treated as static here.
function _static_getfield(@nospecialize(callee), st)
    callee === Core.getfield || return false
    length(st.args) >= 3 || return false
    a = st.args[3]
    return !(a isa Core.SSAValue || a isa Core.Argument)
end

# `AbstractDict` accessors whose appearance on the hot path means a runtime keyed lookup — the
# "owned scratch / GKH-ownership" violation: an owned workspace must resolve to a const-dispatched
# per-type accessor, never a runtime dictionary probe (measured ~130 ns/call, type-stable and
# non-allocating on the warm hit, so it slips past every value-based check). Same category as
# boxing: read from optimized IR, no timing.
const _DICT_ACCESSORS = (:get, :getindex, :get!, :setindex!, :haskey, :pop!, :delete!, :getkey)

# A resolved `:invoke` whose callee is a dict accessor on an `AbstractDict` receiver. `specTypes`
# is `Tuple{typeof(get), <dict>, key, …}` — parameters[2] is the receiver.
function _mi_dict_lookup(mi::Core.MethodInstance)
    d = mi.def
    (d isa Method && d.name in _DICT_ACCESSORS) || return false
    st = mi.specTypes
    st isa DataType || return false
    ps = st.parameters
    length(ps) >= 2 || return false
    recv = ps[2]
    return recv isa Type && recv <: AbstractDict
end

# --- issue #14: one-time-init allocation barriers -----------------------------------------------
#
# `Base.OncePerProcess`/`OncePerThread`-memoized lazy init (and hand-rolled equivalents,
# `OncePerTask` included — see the note on `_BASE_BARRIER_TYPES` below) allocate exactly once per
# process/thread/task, then read a memoized value forever after — but AllocCheck's all-paths static
# proof sees the initializer's allocation as statically reachable and reds `:full`
# @assert_noalloc/@assert_noboxing on a call that is provably alloc-free in steady state. Filtering
# AllocCheck's own per-instance backtraces to attribute allocations to
# the barrier does NOT work in practice: measured on a real `OncePerProcess`-memoized calibrator,
# 24 of 52 reported instances are merged into generic Base scheduler/lock/task internals
# ("multiple call sites") with no traceable single origin, even under an exact type-based filter.
# So the exemption is granted at the STATIC-IR level instead (the same reliable technique
# `_mi_dict_lookup` already uses for `@assert_owned`): recognize a call that routes through a
# barrier via its resolved `:invoke` callee type, and skip recursing into it for alloc/boxing/
# dictlookup signals — the barrier's cold-path cost is not a steady-state cost. `:full` mode then
# substitutes this (already-correct) heuristic for AllocCheck's proof on a barrier-containing call
# — see `_checked_allocs` in backend.jl.

# `OncePerTask` is deliberately NOT included: unlike `OncePerProcess`/`OncePerThread` (which
# resolve to a non-inlined `init_perprocesss`/`init_perthreads`-style cold-path closure — the
# `:invoke` boundary this scan detects), `OncePerTask` is implemented via the current task's
# `.storage` `IdDict` (`jl_eqtable_get`/`jl_eqtable_put`), fully inlined into the caller with no
# separate callee boundary at all — verified against its actual optimized IR, not assumed. There
# is nothing for this `:invoke`-based mechanism to detect. A user relying on `OncePerTask` can
# still get the exemption by wrapping it in their own `@noinline` function and passing that to
# `register_alloc_barrier!` — the wrapper's own call site IS a detectable `:invoke` boundary.
const _BASE_BARRIER_TYPES = (Base.OncePerProcess, Base.OncePerThread)

# User-registered hand-rolled barriers (functions that allocate once, memoize, and are alloc-free
# on every subsequent call) — the escape hatch for memoization that doesn't use one of the two
# `Base` once-guard types above (this includes `Base.OncePerTask`, deliberately excluded from
# `_BASE_BARRIER_TYPES` — see the note there). Keyed on the function value itself (`IdSet`,
# identity — function singletons compare `===` to themselves).
const _ALLOC_BARRIERS = Base.IdSet{Any}()

"""
    register_alloc_barrier!(f)

Mark `f` as a one-time-init allocation barrier: a function that allocates on its first call (per
process/thread/task) and is alloc-free on every subsequent call. `@assert_noalloc`/
`@assert_noboxing` (and `findings`/`check`) then treat a call reaching `f` as exempt from
`:full`'s all-paths AllocCheck proof for that call, the same way `Base.OncePerProcess`/
`OncePerThread` are recognized automatically — use this for a hand-rolled memoization pattern
that doesn't use one of those two `Base` types (this includes `Base.OncePerTask`, which is
**not** auto-recognized — see the note on `_BASE_BARRIER_TYPES` — wrap it in your own function
and register that instead).

Registering is a whole-session, function-identity-keyed decision (not per-call-site), and clears
the findings cache (it changes `:full` `:noalloc`/`:noboxing` verdicts for every caller of `f`).
See [`set_ignore_barrier!`](@ref) to disable the exemption globally.

```julia
@noinline function _my_calibrator()
    ...   # measures something once, memoizes it in a Ref/const
end
register_alloc_barrier!(_my_calibrator)
```
"""
function register_alloc_barrier!(@nospecialize(f))
    push!(_ALLOC_BARRIERS, f)
    clear_cache!()
    return nothing
end

# A registered function is only a barrier when it is ITSELF the callee (parameter 1 — Julia's
# MethodInstance always includes the callee's own type there for a direct call), never when it
# merely appears as an ordinary argument elsewhere (e.g. passed as a callback) — that distinction
# matters here in a way it doesn't for the `Base` types below, since a registered function is an
# arbitrary user function that could legitimately be passed around as a value.
_is_registered_callee(@nospecialize(p)) = p isa Type && any(f -> p === typeof(f), _ALLOC_BARRIERS)

# `(::OncePerProcess)()` (and OncePerThread) are themselves `@inline`d away in Base —
# the fast (already-initialized) path is inlined directly into the caller, so the only surviving
# non-inlined `:invoke` boundary is the COLD-path initializer closure (`init_perprocesss` and
# friends), whose signature is `(closure, ::OncePerProcess, ::UInt8)` — the barrier type sits at
# parameter 2, not 1 (verified against the actual optimized IR, not assumed).
_is_base_barrier_type(@nospecialize(p)) = p isa Type && any(bt -> p <: bt, _BASE_BARRIER_TYPES)

function _mi_is_barrier(mi::Core.MethodInstance)
    st = mi.specTypes
    st isa DataType || return false
    ps = st.parameters
    isempty(ps) && return false
    _is_registered_callee(ps[1]) && return true
    # The parameter-2 (Base once-guard) shape must ALSO be Base's own init closure, not merely
    # any function whose second argument happens to be a OncePerProcess/OncePerThread — a user
    # method with that exact parameter shape (e.g. `helper(o::OncePerProcess, n::Int) = o() +
    # length(Vector(undef, n))`) would otherwise be wrongly recognized as the barrier itself,
    # silently hiding its own real per-call allocation (a genuine false negative, verified: without
    # this check, `_alloc_signals` reports `alloc=false` for a caller of such a function). A user
    # cannot define a method inside `Base`, so `mi.def.module === Base` is the reliable boundary.
    return length(ps) >= 2 && _is_base_barrier_type(ps[2]) && mi.def.module === Base
end

# How many non-inlined `:invoke` levels the alloc/boxing/dictlookup scan follows by default. F35
# measured depth 1 as sufficient on the PureFFT/BlazingPorts corpus; BLAS/LAPACK-style drivers
# (issue #8) route workspace allocation through a `driver! -> prep-helper -> similar/Array` chain
# that's 2+ levels deep, which depth 1 can't see. Override for a codebase with deeper chains:
# `StrictMode._FAST_ALLOC_DEPTH[] = 3`.
const _FAST_ALLOC_DEPTH = Ref(2)

"""
    _alloc_signals(f, types; depth = _FAST_ALLOC_DEPTH[]) -> (; alloc, boxing, dictlookup, abscontainer, barrier, file, line)

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
over-reported on type-stable SIMD/pointer kernels). `dictlookup` flags a runtime `AbstractDict`
accessor (`$(_DICT_ACCESSORS)`) reached on the hot path — the owned-scratch/GKH-ownership
violation — following non-inlined callees like `alloc` (the lookup usually lives in a workspace
accessor callee, not the top function). `barrier` flags a call reaching a recognized one-time-init
allocation barrier (`Base.OncePerProcess`/`OncePerThread`, or a `register_alloc_barrier!`-registered
function — see the note on `_BASE_BARRIER_TYPES` for why `Base.OncePerTask` is not auto-recognized)
— recursion stops there, so the barrier's own one-time allocation never contributes to
`alloc`/`boxing`/`dictlookup`. Location is the method's definition site.
"""
function _alloc_signals(@nospecialize(f), @nospecialize(types::Tuple); depth::Int = _FAST_ALLOC_DEPTH[])
    # Top body via `code_typed(f, types)` — it reuses the compiled specialization's inference
    # (~3 ms); `code_typed_by_type` on the same signature measured ~20 ms (fresh-inference path),
    # so that form is reserved for the callee recursion, where the memo amortizes it.
    sig = Base.signature_type(f, Tuple{types...})
    cts = try
        Base.code_typed(f, types; optimize = true)
    catch
        Any[]
    end
    seen = Base.IdSet{Any}()
    push!(seen, sig)
    alloc, boxing, dictlookup, abscontainer, barrier = isempty(cts) ? (false, false, false, nothing, false) :
        _scan_ci(first(cts)[1], sig, depth, seen)
    m = try
        which(f, types)
    catch
        nothing
    end
    file = m === nothing ? "" : string(m.file)
    line = m === nothing ? 0 : Int(m.line)
    return (; alloc, boxing, dictlookup, abscontainer, barrier, file, line)
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
#
# Identity-keyed on the signature type: concrete signature DataTypes are interned by the runtime
# (structurally equal ⇒ ===), and `hash(::DataType)` walks the whole type — on deeply-nested
# kernel signatures that hashing alone cost more than the scan (profiled: ~half the runtime).
const _SIGNAL_MEMO = IdDict{Any, Dict{Tuple{Int, UInt64}, Tuple{Bool, Bool, Bool, Any, Bool}}}()
const _SIGNAL_MEMO_LOCK = ReentrantLock()

function _signals_by_type(@nospecialize(sig), depth::Int, seen::Base.IdSet{Any})
    sig in seen && return (false, false, false, nothing, false)
    push!(seen, sig)
    key = (depth, Base.get_world_counter())   # any new method definition invalidates (coarse, safe)
    memo = @lock _SIGNAL_MEMO_LOCK begin
        bysig = get(_SIGNAL_MEMO, sig, nothing)
        bysig === nothing ? nothing : get(bysig, key, nothing)
    end
    memo === nothing || return memo
    r = _signals_by_type_uncached(sig, depth, seen)
    @lock _SIGNAL_MEMO_LOCK get!(Dict{Tuple{Int, UInt64}, Tuple{Bool, Bool, Bool, Any, Bool}}, _SIGNAL_MEMO, sig)[key] = r
    return r
end

function _signals_by_type_uncached(@nospecialize(sig), depth::Int, seen::Base.IdSet{Any})
    cts = try
        Base.code_typed_by_type(sig; optimize = true)
    catch
        return (false, false, false, nothing, false)
    end
    isempty(cts) && return (false, false, false, nothing, false)
    return _scan_ci(first(cts)[1], sig, depth, seen)
end

function _scan_ci(ci, @nospecialize(sig), depth::Int, seen::Base.IdSet{Any})
    alloc = false
    boxing = false
    dictlookup = false                # a runtime AbstractDict accessor reached on the hot path
    abscontainer = nothing            # the abstract element type of the first abstract-eltype container seen
    barrier = false                   # a call reached a recognized one-time-init allocation barrier
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
            # An `IdDict` runtime lookup inlines to a `jl_eqtable_get`/`_put`/`_pop` ccall (no `:get`
            # method survives in optimized IR), so the method-name rules below never see it. This is
            # the exact PureBLAS `_symm_scr` shape — detect the primitive directly.
            occursin("eqtable", tgt) && (dictlookup = true)
        elseif Meta.isexpr(st, :new)
            dead[i] && continue
            nt = st.args[1]
            # F38 — any non-isbits `:new` is a real heap allocation, not just mutable/Array/Memory/
            # Box: an escaping *immutable* wrapper (e.g. `Some{Any}(x)`, a Tuple of heap refs) heap-
            # allocates too. `!isbitstype` subsumes the old mutable/Array/Memory/Box checks (none of
            # those are ever isbits) and additionally catches the immutable case AllocCheck sees but
            # the old rule missed. Corpus-measured (PureFFT+BlazingPorts, 569 specializations): fixed
            # 2 false negatives, net 1 new false positive on `Base.CodeUnits{UInt8,String}`-style
            # non-escaping stdlib wrappers (no escape analysis here to tell those apart) — an
            # acceptable tradeoff since over-flagging is the safe direction for an alloc guarantee.
            (nt isa Type && !Base.isbitstype(nt)) && (alloc = true)
        elseif Meta.isexpr(st, :invoke)
            # A resolved `:invoke` is never dispatch *from its own recorded result* (F9) — even
            # with an abstract recorded result (mutating helpers with an unused return are typed
            # `Any`). That's about the :invoke statement's SSA type, not what happens inside the
            # callee. If the callee's own body genuinely allocates, boxes, or hits a dict accessor
            # (found by recursing with the same F8/F9-safe scan below, plus the direct
            # `_mi_dict_lookup` check on the resolved callee itself), that's a real signal one
            # level removed from the caller — not the F9 trap.
            if !dead[i]
                a1 = st.args[1]
                mi = a1 isa Core.CodeInstance ? a1.def : a1
                if mi isa Core.MethodInstance
                    if _mi_is_barrier(mi)
                        # The callee itself IS a recognized barrier (e.g. `(::OncePerProcess)()`,
                        # or a directly-registered function) — its one-time cold-path allocation
                        # is not a steady-state cost, so recursion stops here rather than seeing it.
                        barrier = true
                    else
                        _mi_dict_lookup(mi) && (dictlookup = true)
                        if depth > 0 && (!alloc || !boxing || !dictlookup)
                            a2, b2, d2, _, br2 = _signals_by_type(mi.specTypes, depth - 1, seen)
                            a2 && (alloc = true)
                            b2 && (boxing = true)
                            d2 && (dictlookup = true)
                            br2 && (barrier = true)
                        end
                    end
                end
            end
        elseif Meta.isexpr(st, :call)
            callee = _static_callee(ci, st.args[1])
            # A *dynamic* dict accessor (abstract dict receiver) — the runtime-lookup form that never
            # resolves to an `:invoke`. Receiver is the first argument.
            if !dictlookup && !dead[i] && callee isa Function && nameof(callee) in _DICT_ACCESSORS && length(st.args) >= 2
                rt = _stmt_arg_type(ci, sig, st.args[2])
                (rt isa Type && rt <: AbstractDict) && (dictlookup = true)
            end
            if callee === Core.memorynew           # 1.12 `Memory` allocation is a builtin :call
                dead[i] || (alloc = true)
            elseif _nonconcrete(T) && !_static_getfield(callee, st)
                # A *dynamic* call with any non-concrete result boxes — including a small union
                # (the founding runtime-tuple-index trap): union-split is a resolved-callee
                # (`:invoke`) optimization, it does not save a dynamic `:call`. EXCEPT a
                # `Core.getfield` call whose field/index argument is a COMPILE-TIME CONSTANT
                # (`_static_getfield`, below) — e.g. reading a named struct field like
                # `OncePerProcess`'s internally loosely-typed memoized-value slot: always one
                # fixed memory location regardless of static type precision, never itself
                # allocates. Crucially this must NOT be widened to "any `getfield` call" —
                # `t[i]` on a heterogeneous tuple with a RUNTIME `i` *also* lowers to
                # `Core.getfield(t, i, ...)`, and that genuinely needs boxing (the field's type
                # varies by which runtime index is read) — that IS the founding runtime-tuple-
                # index trap `@unroll` exists for, and must keep flagging as boxing.
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
    return (alloc, boxing, dictlookup, abscontainer, barrier)
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
