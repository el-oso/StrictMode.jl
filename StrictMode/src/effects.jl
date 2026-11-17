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

# --- unoptimized-IR statement reading -----------------------------------------------------------
# The three helpers below read `code_typed(...; optimize = false)` instead of the optimized form
# the rest of this file uses. Two scans need that view — `:static_ownership` (a `Type{T}`-keyed
# lookup const-folds away entirely under optimization) and `:trusted` (a small trust boundary
# inlines, and its `getfield` then surfaces in the IR of an innocent caller). Both ask about the
# shape of the source, not about a provable per-specialization cost, so both must look before the
# optimizer erases the pattern.

_unwrap_lattice(@nospecialize(T)) = T isa Core.Const ? Core.Typeof(T.val) : (T isa Core.PartialStruct ? T.typ : T)

# Argument type at unoptimized-IR statement granularity: slots (`SlotNumber`) are the pre-SSA
# argument/local representation here, not `Core.Argument` (that's optimized-IR-only) — the reason
# these scans can't reuse `_stmt_arg_type`.
function _unopt_arg_type(ci, @nospecialize(a))
    a isa Core.SSAValue && return _unwrap_lattice(ci.ssavaluetypes[a.id])
    a isa Core.SlotNumber && return isnothing(ci.slottypes) ? Any : _unwrap_lattice(ci.slottypes[a.id])
    a isa GlobalRef && return isconst(a.mod, a.name) ? Core.Typeof(getglobal(a.mod, a.name)) : Any
    a isa QuoteNode && return Core.Typeof(a.value)
    a isa Expr && return Any
    return Core.Typeof(a)
end

# Resolve a callee value, following one level of SSA indirection (unoptimized IR routinely
# assigns `%1 = GlobalRef(Base, :get!)` as its own statement, then calls `(%1)(args...)`).
function _unopt_callee(ci, @nospecialize(a))
    if a isa Core.SSAValue
        # A module-qualified callee is an `Expr` the structural walk below cannot resolve —
        # `Core.getfield(x, :f)` lowers to `getproperty(Core, :getfield)` and then a call through
        # that SSA value. Inference constant-folds it, so take the folded callee from the SSA type.
        T = ci.ssavaluetypes[a.id]
        T isa Core.Const && return T.val
        return _unopt_callee(ci, ci.code[a.id])
    end
    a isa GlobalRef && isconst(a.mod, a.name) && return getglobal(a.mod, a.name)
    a isa QuoteNode && return a.value
    a isa Function && return a
    return nothing
end

function _call_callee_and_args(ci, st)
    Meta.isexpr(st, :call) && return _unopt_callee(ci, st.args[1]), st.args[2:end]
    # `:invoke_modify` carries an `:invoke`'s layout and is what the atomic read-modify-write forms
    # lower to, so a scan that omits it reads `@atomic x.f += v` as no call at all.
    (Meta.isexpr(st, :invoke) || Meta.isexpr(st, :invoke_modify)) &&
        return _unopt_callee(ci, st.args[2]), st.args[3:end]
    return nothing, ()
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
# "static ownership" violation: an owned workspace must resolve to a const-dispatched
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
# dictlookup signals — the barrier's cold-path cost is not a steady-state cost. `StrictModeTest`
# substitutes this (already-correct) heuristic for AllocCheck's proof on a barrier-containing call.

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
process/thread/task) and is alloc-free on every subsequent call. The allocation scan then stops at
`f` instead of counting its initializer, the same way `Base.OncePerProcess`/`OncePerThread` are
recognized automatically — use this for a hand-rolled memoization pattern that doesn't use one of
those two `Base` types (this includes `Base.OncePerTask`, which is **not** auto-recognized — see
the note on `_BASE_BARRIER_TYPES` — wrap it in your own function and register that instead).
`StrictModeTest` honors the same registration: it substitutes this heuristic for AllocCheck's
all-paths proof on a call whose only allocation risk is the barrier.

The precondition is about the memoization **scope**, which is what "per process/thread/task" above
means: the allocation is the one-time init *of that scope*, and nothing in that scope allocates
again. A `OncePerTask` accessor satisfies it — once per task, then reads — and is the case this
function exists for, since it is the one Base scope the scan cannot detect on its own.

A **growing pool does not**, under any reading. It allocates again at a new high-water mark within
the same process, thread and task, so there is no scope whose init has finished. That is an ordinary
allocating function, and `:noalloc` cannot express what it really guarantees: "finitely many
growths, then nothing" is a property of the call sequence rather than of the code, so an all-paths
proof must report the growth path forever. Excuse it visibly with
`@strict_exempt :noalloc reason = "…"` and assert the real property where it can be measured — warm
the call, then check that a second identical call allocates nothing.

**A barrier excuses allocation, and nothing else.** Every other guarantee still reads `f` itself: a
dictionary lookup or a boxed value inside `f` is reported when `f` is checked, once. A caller whose
only such cause lies inside `f` is neither failed again nor passed as if it had been checked: it
gets an `:info` finding that names `f`, so the reader can follow it to the one place it is reported.
A `:owned` failure on a `OncePerTask` accessor is the usual case: the lookup is the price of
per-task state, and it belongs to the accessor, not to every kernel that reaches it.

Registering is a whole-session, function-identity-keyed decision (not per-call-site), and clears
the findings cache (it changes `:noalloc`/`:noboxing` verdicts for every caller of `f`).

```julia
@noinline function _my_calibrator()
    ...   # measures something once, memoizes it in a Ref/const
end
register_alloc_barrier!(_my_calibrator)
```
"""
function register_alloc_barrier!(@nospecialize(f))
    push!(_ALLOC_BARRIERS, f)
    # The registry above lives in this session. A package that registers at its own precompile loses it
    # at the next load, so the registration is also kept in the package that owns the function, which
    # is serialized with it, and read back with the other loaded packages' (`_barrier_functions`).
    try
        store = _local_store!(parentmodule(f), _LOCAL_BARRIERS, Any[])
        any(g -> g === f, store) || push!(store, f)
    catch
        # A module that is closed to writes keeps the session registration only.
    end
    _BARRIER_GEN[] += 1
    clear_cache!()
    return nothing
end

const _LOCAL_BARRIERS = :__strict_barriers__
const _BARRIER_GEN = Ref(0)
const _BARRIER_MEMO = Ref{Tuple{UInt, Int, Int, Vector{Any}}}((UInt(0), -1, -1, Any[]))

# Every registered barrier in scope: this session's, and each loaded package's own.
function _barrier_functions()
    w = Base.get_world_counter()
    n = length(_ALLOC_BARRIERS)
    m = _BARRIER_MEMO[]
    (m[1] == w && m[2] == n && m[3] == _BARRIER_GEN[]) && return m[4]
    out = Any[]
    for f in _ALLOC_BARRIERS
        push!(out, f)
    end
    for mod in _store_modules()
        s = _store_for(mod, _LOCAL_BARRIERS)
        s isa AbstractVector || continue
        for f in s
            any(g -> g === f, out) || push!(out, f)
        end
    end
    _BARRIER_MEMO[] = (w, n, _BARRIER_GEN[], out)
    return out
end

# A registered function is only a barrier when it is ITSELF the callee (parameter 1 — Julia's
# MethodInstance always includes the callee's own type there for a direct call), never when it
# merely appears as an ordinary argument elsewhere (e.g. passed as a callback) — that distinction
# matters here in a way it doesn't for the `Base` types below, since a registered function is an
# arbitrary user function that could legitimately be passed around as a value.
_is_registered_callee(@nospecialize(p)) = p isa Type && any(f -> p === typeof(f), _barrier_functions())

# `(::OncePerProcess)()` (and OncePerThread) are themselves `@inline`d away in Base —
# the fast (already-initialized) path is inlined directly into the caller, so the only surviving
# non-inlined `:invoke` boundary is the COLD-path initializer closure (`init_perprocesss` and
# friends), whose signature is `(closure, ::OncePerProcess, ::UInt8)` — the barrier type sits at
# parameter 2, not 1 (verified against the actual optimized IR, not assumed).
_is_base_barrier_type(@nospecialize(p)) = p isa Type && any(bt -> p <: bt, _BASE_BARRIER_TYPES)

# StrictMode's own machinery, reached from a guarded call site. With checks enabled a `@strict` or
# `@assert_*` site leaves a live `:invoke` of `_strict_scan` behind its per-site flag, and recursing
# into it reports the scan's OWN reflection — allocation, boxing, a dict lookup and a union phi —
# against the function under test (issue #32). Those costs belong to the tool, run once per site, and
# vanish with `disable_checks!()`. The proof tier drops the same frame by name (`_GUARD_FRAME` in
# StrictModeTest); this is the value-free scan's half.
#
# `moduleroot` rather than `=== StrictMode`, so a submodule counts too, and the whole package is
# excluded rather than one function name: every entry point a guard can reach (`_fail`, `findings`,
# `_alloc_signals` itself) is equally not the caller's cost.
_mi_is_strictmode(mi::Core.MethodInstance) =
    mi.def isa Method && Base.moduleroot(mi.def.module) === @__MODULE__

# A registered function called with keywords is reached through two more methods: `Core.kwcall`, which
# carries the function at parameter 3, and the keyword-sorted body `#f#N`, which carries it after the
# keyword values. Both are the barrier: the allocation is the registered function's own.
function _is_registered_kw_callee(mi::Core.MethodInstance, ps)
    bs = _barrier_functions()
    (isempty(bs) || !(mi.def isa Method)) && return false
    ps[1] === typeof(Core.kwcall) && return length(ps) >= 3 && _is_registered_callee(ps[3])
    name = _demangle(mi.def.name)
    for f in bs
        nameof(f) === name && any(p -> p === typeof(f), ps) && return true
    end
    return false
end

function _mi_is_barrier(mi::Core.MethodInstance)
    st = mi.specTypes
    st isa DataType || return false
    ps = st.parameters
    isempty(ps) && return false
    _is_registered_callee(ps[1]) && return true
    _is_registered_kw_callee(mi, ps) && return true
    # The parameter-2 (Base once-guard) shape must ALSO be Base's own init closure, not merely
    # any function whose second argument happens to be a OncePerProcess/OncePerThread — a user
    # method with that exact parameter shape (e.g. `helper(o::OncePerProcess, n::Int) = o() +
    # length(Vector(undef, n))`) would otherwise be wrongly recognized as the barrier itself,
    # silently hiding its own real per-call allocation (a genuine false negative, verified: without
    # this check, `_alloc_signals` reports `alloc=false` for a caller of such a function). A user
    # cannot define a method inside `Base`, so `mi.def.module === Base` is the reliable boundary.
    return length(ps) >= 2 && _is_base_barrier_type(ps[2]) && mi.def.module === Base
end

# How many non-inlined `:invoke` levels of Base the alloc/boxing/dictlookup scan follows by default; the
# package's own helpers are followed to the end of their call graph whatever this is. F35
# measured depth 1 as sufficient on the PureFFT/BlazingPorts corpus; BLAS/LAPACK-style drivers
# (issue #8) route workspace allocation through a `driver! -> prep-helper -> similar/Array` chain
# that's 2+ levels deep, which depth 1 can't see. Override for a codebase with deeper chains:
# `StrictMode._FAST_ALLOC_DEPTH[] = 3`.
const _FAST_ALLOC_DEPTH = Ref(2)

# The most bodies one scan reads. A call graph larger than this leaves the verdict `truncated`.
const _SCAN_BODY_BUDGET = Ref(1000)

# Base's task, lock and condition code. Its run-time dispatch is the scheduler's own, off the call's
# hot path, and AllocCheck reports none there, so a callee reached only through it is not boxing.
const _SCHEDULER_FILES = ("task.jl", "condition.jl", "lock.jl", "locks-mt.jl", "partr.jl")
_in_scheduler(mi::Core.MethodInstance) = mi.def isa Method && mi.def.module === Base &&
    basename(string(mi.def.file)) in _SCHEDULER_FILES

# A callee the scan follows below the Base levels: one defined outside Base and Core, or a Base
# method handed the package's code or types to run (a closure given to `map`).
function _enters_user_code(mi::Core.MethodInstance)
    mi.def isa Method || return false
    root = Base.moduleroot(mi.def.module)
    return !(root === Base || root === Core) || _carries_user_type(mi.specTypes)
end

"""
    _alloc_signals(f, types; depth = _FAST_ALLOC_DEPTH[]) -> (; alloc, boxing, dictlookup, abscontainer, barrier, file, line)

Value-free allocation heuristic from optimized typed IR (no execution, no backend). `alloc` flags
explicit heap allocation (`:new` of a mutable/Array/`Core.Box` type, or a GC/box `:foreigncall`),
**following non-inlined `:invoke` callees: Base's to `depth` levels, the package's own to the end of
its call graph** (allocations in a non-inlined helper
— a grow path, a string build — are real allocations of the caller). `boxing` flags the boxing /
dynamic-dispatch subclass:

- a `:call`/`:invoke` with an abstract, non-union-splittable result (e.g. a runtime tuple index,
  an un-`Val`ed `ntuple`), or
- a dynamic `:call` (non-builtin) taking an abstract, non-union-splittable **argument** even when
  its own result is concrete — the "internal dispatch with a concrete return" blind spot.

A small all-concrete `Union` result stays unflagged (union-split, not boxing — flagging those
over-reported on type-stable SIMD/pointer kernels). `dictlookup` flags a runtime `AbstractDict`
accessor (`$(_DICT_ACCESSORS)`) reached on the hot path — the static-ownership
violation — following non-inlined callees like `alloc` (the lookup usually lives in a workspace
accessor callee, not the top function). `barrier` flags a call reaching a recognized one-time-init
allocation barrier (`Base.OncePerProcess`/`OncePerThread`, or a `register_alloc_barrier!`-registered
function — see the note on `_BASE_BARRIER_TYPES` for why `Base.OncePerTask` is not auto-recognized)
— recursion stops there, so the barrier's own one-time allocation never contributes to
`alloc`/`boxing`/`dictlookup`. It is a one-sided signal: the callee walk stops once `alloc`,
`boxing` and `dictlookup` are all set, so a barrier reachable only below that point is not
recorded, and `barrier == false` alongside those three means "not looked for". Read it only in
combination with a clean `alloc`/`boxing` result, which is the state where it is exhaustive.
Location is the method's definition site.
"""
const _AllocSignals = @NamedTuple{
    alloc::Bool, boxing::Bool, dictlookup::Bool, abscontainer::Any,
    barrier::Bool, unionphi::Bool, exempt::Union{Nothing, Symbol}, file::String, line::Int,
    # No typed body could be read for the signature, so every other field is empty for want of a
    # body, not because the body is clean.
    unread::Bool,
    # A registered barrier the call reaches whose own dictionary lookup, or boxing, is reported at the
    # barrier rather than here (`nothing` when there is none).
    barrier_dict::Union{Nothing, Symbol}, barrier_box::Union{Nothing, Symbol},
    # The walk did not read the whole call graph: a body it could not read, the body budget, or the
    # depth limit with a callee outside Base below it. A verdict that depends on what lies below
    # (`:noalloc`, `:noboxing`, `:owned`) is not established.
    truncated::Bool,
}

# The scan of `f`'s OWN body, memoized on the same terms as the callee recursion below: identity on
# the signature, keyed by `(depth, world)`, so any new method definition invalidates. Sharing
# `_SIGNAL_MEMO_LOCK` is safe because the scan itself runs outside the critical section.
#
# The macros re-run their check on EVERY execution of the call site, not once per site, so an
# uncached top body is paid per iteration of any loop containing one: measured 450 µs uncached
# against 240 ns cached on a 256-element dot product whose bare call is 19 ns. `@assert_noalloc`
# (heuristic mode) and `@assert_owned` ask at the same default depth, so they share one entry.
const _TOP_SIGNAL_MEMO = IdDict{Any, Dict{Tuple{Int, UInt64, Symbol}, _AllocSignals}}()

function _alloc_signals(
        @nospecialize(f), @nospecialize(types::Tuple); mode::Symbol = :full, depth::Int = _FAST_ALLOC_DEPTH[]
    )
    sig = _sigtype(f, types)
    key = (depth, Base.get_world_counter(), mode)
    memo = @lock _SIGNAL_MEMO_LOCK begin
        bysig = get(_TOP_SIGNAL_MEMO, sig, nothing)
        isnothing(bysig) ? nothing : get(bysig, key, nothing)
    end
    isnothing(memo) || return memo
    r = _alloc_signals_uncached(f, types, sig, depth, mode)
    @lock _SIGNAL_MEMO_LOCK get!(
        Dict{Tuple{Int, UInt64, Symbol}, _AllocSignals}, _TOP_SIGNAL_MEMO, sig
    )[key] = r
    return r
end

function _alloc_signals_uncached(@nospecialize(f), @nospecialize(types::Tuple), @nospecialize(sig), depth::Int, mode::Symbol = :full)
    # The top body comes from the body memo the callee recursion shares: an entry point is often a
    # callee of another, and a body is read once.
    topci = _typed_body(sig)
    seen = Base.IdSet{Any}()
    push!(seen, sig)
    alloc, boxing, dictlookup, abscontainer, barrier, unionphi, exempt, barrier_dict, barrier_box, truncated =
        isnothing(topci) ? (false, false, false, nothing, false, false, nothing, nothing, nothing, false) :
        _scan_ci(topci, sig, depth, seen, mode, true)
    m = try
        which(f, types)
    catch
        nothing
    end
    file = isnothing(m) ? "" : string(m.file)
    line = isnothing(m) ? 0 : Int(m.line)
    return (;
        alloc, boxing, dictlookup, abscontainer, barrier, unionphi, exempt, file, line,
        unread = isnothing(topci), barrier_dict, barrier_box, truncated,
    )
end

# --- issue #17: escape analysis, so the `:new` rule stops flagging what LLVM elides -------------
#
# Typed IR still contains the `Vector{Float64}(undef, n)` that LLVM later removes because the array
# never escapes, so a call measuring 0 bytes is reported as allocating. `has_no_escape` on the `:new`
# statement separates the two — MEASURED on the shapes that matter:
#
#   length(Vector{Float64}(undef, n))          0 B      no_escape = true    (the false positive)
#   v = …; SINK[] = v                        112 B      no_escape = false
#   v = …; v[1] = 1.0; v[1]  (runtime size)  112 B      no_escape = false
#   v = …  (100_000 elements)                803 kB     no_escape = false
#   IOBuffer/print/take!                     256 B      no_escape = false
#   Dict + setindex!                         448 B      no_escape = false
#
# Every shape that really allocates reports `false`, so gating on this can only ever LOSE a false
# positive — it cannot introduce a false negative, which is the direction that would matter for an
# allocation guarantee. (`[n, n+1]`, which measures 0 B, still reports `false` and stays flagged:
# the over-flag is narrowed, not eliminated.)
#
# The reach is narrow, and worth knowing before pointing anyone at it: over 120 compiled PureBLAS +
# PureIPM specializations, 63 frames contain a non-isbits `:new` and this proves the set fully
# non-escaping in NONE of them. It separates small self-contained kernels, not the interprocedural
# shapes library code is made of. That is why `_scan_ci` calls it on demand rather than per frame —
# eagerly it doubles a sweep.
#
# `Core.Compiler.EscapeAnalysis` is a compiler internal with no stability guarantee across Julia
# versions, so EVERY failure here falls back to `false` — "assume it escapes", i.e. the behavior
# without this. A missing analysis must never quiet a guarantee.
const _ESCAPE_MEMO = IdDict{Any, Bool}()
const _ESCAPE_MEMO_LOCK = ReentrantLock()

# The pass `code_ircode_by_type` must stop at, by the name this compiler uses for it. The compiler
# publishes its pass names where it has a list, and the names there carry a prefix (`"CC: INLINING"`)
# while the older spelling is `"Inlining"` — an unrecognized name is an ERROR, not a no-op, so this
# reads the list when there is one rather than keying on a version.
const _INLINING_PASS = let CC = Core.Compiler
    names = isdefined(CC, :ALL_PASS_NAMES) ? collect(String, CC.ALL_PASS_NAMES) : String[]
    i = findfirst(n -> occursin("INLINING", uppercase(n)), names)
    isnothing(i) ? "Inlining" : names[i]
end

function _all_news_nonescaping(@nospecialize(sig))
    cached = @lock _ESCAPE_MEMO_LOCK get(_ESCAPE_MEMO, sig, nothing)
    isnothing(cached) || return cached
    v = try
        _compute_all_news_nonescaping(sig)
    catch err
        # `false` is the conservative answer — it only declines to suppress a finding — which is why
        # this failing is invisible in a verdict. Say it once: when the compiler renamed its
        # inlining pass, this threw on every call and the escape analysis stopped running at all,
        # leaving the false positives of issue #17 unsuppressed with nothing to show for it.
        @warn "StrictMode: escape analysis is unavailable, so allocations LLVM elides may be " *
            "reported as real (issue #17). The verdicts stay conservative. Cause: " *
            sprint(showerror, err) maxlog = 1
        false
    end
    @lock _ESCAPE_MEMO_LOCK (_ESCAPE_MEMO[sig] = v)
    return v
end

function _compute_all_news_nonescaping(@nospecialize(sig))
    EA = Core.Compiler.EscapeAnalysis
    irs = _code_ircode_by_type(sig)
    isempty(irs) && return false
    ir = first(irs)[1]
    # `Returns(false)` is the conservative cache callback: an `:invoke` callee with no cached escape
    # information is treated as escaping its arguments, rather than assumed clean.
    st = EA.analyze_escapes(
        ir, length(ir.argtypes), Core.Compiler.SimpleInferenceLattice.instance, Returns(false)
    )
    sawnew = false
    for (i, stmt) in enumerate(ir.stmts.stmt)
        (stmt isa Expr && stmt.head === :new) || continue
        sawnew = true
        EA.has_no_escape(st[Core.SSAValue(i)]) || return false
    end
    return sawnew
end

const _IGNORE_THROW = Ref(true)

"""
    ignore_throw() -> Bool

Whether allocation analysis ignores allocations on an error path — a `BoundsError` construction and
the like (default `true`). Hot-path semantics: a runtime-zero-alloc kernel with bounds checks is not a
violation. Both tiers honor it, so the scan and `StrictModeTest`'s AllocCheck proof answer the same
question. See [`set_ignore_throw!`](@ref).

An error path is every statement from which no path reaches a `return` carrying a value — not only the
`throw` itself. An interpolated message is usually built one block earlier, in a block that jumps to
the throw, so counting only the throw's own block reported `print_to_string`'s allocation for text no
successful call ever builds. A loop is never an error path: a statement is live when *some* path from
it returns.
"""
ignore_throw() = _IGNORE_THROW[]

"""
    set_ignore_throw!(b::Bool)

Set whether allocation analysis ignores throw-branch allocations. `true` (default) gives hot-path
semantics; `false` counts allocations on error branches that never execute. Clears the findings
cache, since it changes `:noalloc`/`:noboxing` results.
"""
function set_ignore_throw!(b::Bool)
    _IGNORE_THROW[] = b
    clear_cache!()
    return b
end

# Per-statement "this straight-line region ends in an unreachable return" mask — the throw-path
# approximation of AllocCheck's `ignore_throw = true`: error branches build messages/exceptions
# (real allocations, but never taken on the success path), and the proof doesn't count them, so the
# scan must not either. A region is [previous terminator + 1 .. terminator]; it is dead-end
# when its terminator is `ReturnNode()` with no value (= unreachable, i.e. after a throw).
# Statements from which NO path reaches a normal return: the error paths `ignore_throw()` discounts.
#
# Reachability, not a per-block spelling. The block that ends in the unreachable `return` is only the
# last one on such a path; a `throw`'s message is usually built earlier, in a block that merely JUMPS
# there, and marking only the terminator block left an interpolated message live — so the scan
# reported `print_to_string`'s allocation for text no successful call ever builds (issue #33).
#
# A statement is alive when one of its successors is, and a `ReturnNode` carrying a value is alive: the
# fixed point of that, taken over the statements from the last to the first until nothing changes. A
# loop cannot fool it: a statement is alive when *some* path from it returns, and everything left over
# leads only to a throw or to an unreachable terminator. No per-statement storage: a body is a few
# thousand statements and this runs for every body a walk reads.
function _deadend_mask(code::Vector{Any})
    n = length(code)
    iszero(n) && return falses(0)
    alive = falses(n)
    changed = true
    while changed
        changed = false
        for i in n:-1:1
            alive[i] && continue
            st = code[i]
            up = if st isa Core.ReturnNode
                isdefined(st, :val)
            elseif st isa Core.GotoNode
                1 <= st.label <= n && alive[st.label]
            elseif st isa Core.GotoIfNot
                (1 <= st.dest <= n && alive[st.dest]) || (i < n && alive[i + 1])
            elseif Meta.isexpr(st, :gotoifnot)
                t = st.args[2]
                (t isa Integer && 1 <= t <= n && alive[t]) || (i < n && alive[i + 1])
            else
                i < n && alive[i + 1]                    # falls through
            end
            if up
                alive[i] = true
                changed = true
            end
        end
    end
    return map(!, alive)
end

# Session memo for the per-signature scan: the callee recursion re-visits shared helpers (Base
# internals especially) from every caller, and each visit pays a `code_typed_by_type`. Without
# this, `:fast`'s median went 2.9 ms → 73 ms on the corpus study. Invalidated with the findings
# cache (`clear_cache!` / the Revise extension) — same staleness contract.
#
# Identity-keyed on the signature type: concrete signature DataTypes are interned by the runtime
# (structurally equal ⇒ ===), and `hash(::DataType)` walks the whole type — on deeply-nested
# kernel signatures that hashing alone cost more than the scan (profiled: ~half the runtime).
const _SIGNAL_MEMO = IdDict{Any, Dict{Tuple{Int, UInt64, Symbol}, Tuple{Bool, Bool, Bool, Any, Bool, Bool, Union{Nothing, Symbol}, Union{Nothing, Symbol}, Union{Nothing, Symbol}, Bool}}}()
const _SIGNAL_MEMO_LOCK = ReentrantLock()

# A body already on this walk contributes nothing a second time, so a result computed below such a
# cut is the walk's, not the body's own: it omits what the cut body reaches. Memoizing it would hand
# a later walk, which reaches the body by another route, a verdict with that part missing. The scan
# therefore counts its cuts, and only a body whose subtree met none is memoized.
_cut_counter() = get!(() -> Ref(0), task_local_storage(), :strictmode_scan_cuts)::Base.RefValue{Int}

function _signals_by_type(@nospecialize(sig), depth::Int, seen::Base.IdSet{Any}, mode::Symbol = :full)
    if sig in seen
        _cut_counter()[] += 1
        return (false, false, false, nothing, false, false, nothing, nothing, nothing, false)
    end
    push!(seen, sig)
    key = (depth, Base.get_world_counter(), mode)   # any new method definition invalidates (coarse, safe)
    memo = @lock _SIGNAL_MEMO_LOCK begin
        bysig = get(_SIGNAL_MEMO, sig, nothing)
        bysig === nothing ? nothing : get(bysig, key, nothing)
    end
    memo === nothing || return memo
    cuts = _cut_counter()
    before = cuts[]
    r = _signals_by_type_uncached(sig, depth, seen, mode)
    cuts[] == before || return r
    @lock _SIGNAL_MEMO_LOCK get!(Dict{Tuple{Int, UInt64, Symbol}, Tuple{Bool, Bool, Bool, Any, Bool, Bool, Union{Nothing, Symbol}, Union{Nothing, Symbol}, Union{Nothing, Symbol}, Bool}}, _SIGNAL_MEMO, sig)[key] = r
    return r
end

# The optimized body of a signature, or `nothing` when none can be read. Inferring a body is most of
# what a scan costs, and the same body is reached again by every walk that passes through it, at
# each depth and from every entry point, so it is read once. An entry stays valid while the compiler's
# own record of the signature does (a method defined elsewhere does not end it), or, for a signature
# the compiler holds no record of, while the world is the one it was read in.
const _BODY_MEMO = IdDict{Any, Tuple{UInt, Any, Any}}()

function _typed_body(@nospecialize(sig))
    world = Base.get_world_counter()
    hit = @lock _SIGNAL_MEMO_LOCK get(_BODY_MEMO, sig, nothing)
    if !isnothing(hit)
        rec = hit[3]
        (hit[1] == world || (rec isa Core.CodeInstance && rec.min_world <= world <= rec.max_world)) && return hit[2]
    end
    ci = _compiled_body(sig, world)
    if isnothing(ci)
        cts = try
            _code_typed_by_type(sig; optimize = true)
        catch
            Any[]
        end
        ci = isempty(cts) ? nothing : first(cts[1])
    end
    rec = isnothing(ci) ? nothing : _record_of(sig, world)
    @lock _SIGNAL_MEMO_LOCK (_BODY_MEMO[sig] = (world, ci, rec))
    return ci
end

# The compiler's record of a signature in `world`: the cached `CodeInstance` that says in which worlds
# its inference holds.
function _record_of(@nospecialize(sig), world::UInt)
    m = try
        Base._which(sig; raise = false, world)
    catch
        nothing
    end
    isnothing(m) && return nothing
    mi = try
        Base.specialize_method(m)
    catch
        nothing
    end
    mi isa Core.MethodInstance || return nothing
    ci = isdefined(mi, :cache) ? mi.cache : nothing
    while ci isa Core.CodeInstance
        (isnothing(ci.owner) && ci.min_world <= world <= ci.max_world) && return ci
        ci = isdefined(ci, :next) ? ci.next : nothing
    end
    return nothing
end

# The optimized body the compiler already holds for a signature that has been run, when it keeps one
# (a method compiled into a package image keeps none, and one cached compressed is not read here).
# Reading it costs nothing; inferring the body again costs milliseconds.
function _compiled_body(@nospecialize(sig), world::UInt)
    m = try
        Base._which(sig; raise = false, world)
    catch
        nothing
    end
    isnothing(m) && return nothing
    mi = try
        Base.specialize_method(m)
    catch
        nothing
    end
    mi isa Core.MethodInstance || return nothing
    ci = isdefined(mi, :cache) ? mi.cache : nothing
    while ci isa Core.CodeInstance
        if isnothing(ci.owner) && ci.min_world <= world <= ci.max_world && ci.inferred isa Core.CodeInfo
            return ci.inferred
        end
        ci = isdefined(ci, :next) ? ci.next : nothing
    end
    return nothing
end

# Where the scan finds what it reports: for every body of the call graph whose own statements set the
# signal `mode` asks about, the callees that lead to it and the statements. `_alloc_signals` says that
# something allocates; this says which statement, in which callee, reached from where.
function _signal_origin(
        @nospecialize(f), @nospecialize(types::Tuple); mode::Symbol = :alloc,
        stops::Union{Nothing, Vector{Any}} = nothing, first_only::Bool = false
    )
    top = _sigtype(f, types)
    parent = IdDict{Any, Any}()
    queue = Any[(top, _FAST_ALLOC_DEPTH[])]
    seen = Base.IdSet{Any}()
    out = Any[]
    while !isempty(queue) && length(seen) < _SCAN_BODY_BUDGET[]
        s, depth = popfirst!(queue)
        s in seen && continue
        push!(seen, s)
        ci = _typed_body(s)
        isnothing(ci) && continue
        trace = Any[]
        _scan_ci(ci, s, 0, Base.IdSet{Any}([s]), mode, false, trace)
        if !isempty(trace)
            path = Any[]
            c = s
            while haskey(parent, c)
                c = parent[c]
                pushfirst!(path, c)
            end
            push!(out, (; signature = s, path, statements = trace))
            first_only && break
        end
        dead = ignore_throw() ? _deadend_mask(ci.code) : falses(length(ci.code))
        for (j, st) in enumerate(ci.code)
            (Meta.isexpr(st, :invoke) && !dead[j]) || continue
            a1 = st.args[1]
            mi = a1 isa Core.CodeInstance ? a1.def : a1
            (mi isa Core.MethodInstance && mi.def isa Method) || continue
            _mi_is_strictmode(mi) && continue
            if _mi_is_barrier(mi)
                isnothing(stops) || push!(stops, mi.specTypes)
                continue
            end
            isnothing(_mi_exempt_name(mi)) || continue
            # The scan's own rule: the package's code to the end, Base to `depth` levels.
            user = _enters_user_code(mi)
            (depth > 0 || (depth < 0 && user)) || continue
            haskey(parent, mi.specTypes) || (parent[mi.specTypes] = s)
            push!(queue, (mi.specTypes, user ? depth : (depth > 1 ? depth - 1 : -1)))
        end
    end
    return out
end

# The nearest place an allocation or boxing comes from, as a sentence for a warning: the callee, the
# statement, and the calls that lead to it. Empty when the walk finds none.
function _origin_note(@nospecialize(f), @nospecialize(types::Tuple); mode::Symbol = :alloc)
    o = try
        _signal_origin(f, types; mode, first_only = true)
    catch
        return ""
    end
    isempty(o) && return ""
    x = first(o)
    st = first(x.statements)
    via = join((first(string(p), 70) for p in last(x.path, 3)), " -> ")
    return "; first at " * first(string(x.signature), 110) * " [" * first(string(st[2]), 90) * "]" *
        (isempty(via) ? "" : ", reached through " * via)
end

# Whether a signature is Base's task, lock or condition code.
function _sig_in_scheduler(@nospecialize(sig))
    m = try
        Base._which(sig; raise = false)
    catch
        nothing
    end
    isnothing(m) && return false
    meth = m.method
    return meth.module === Base && basename(string(meth.file)) in _SCHEDULER_FILES
end

# `nothing` unless every place the scan finds an allocation or boxing is in the task scheduler, in
# which case the nearest one: the finding is then that the call can block, not that it allocates.
# What the user can do about it differs, so it is reported as its own kind.
function _scheduler_origin(@nospecialize(f), @nospecialize(types::Tuple))
    origins = _signal_origin(f, types; mode = :alloc)
    isempty(origins) && return nothing
    all(o -> _sig_in_scheduler(o.signature), origins) || return nothing
    o = first(origins)
    via = join((first(string(p), 70) for p in last(o.path, 3)), " -> ")
    return (; call = first(string(o.signature), 100), statement = first(string(o.statements[1][2]), 80), via)
end

# The registered barriers the walk from `f` stops at, so a reader can see that one was reached and not
# entered.
function _barrier_stops(@nospecialize(f), @nospecialize(types::Tuple))
    stops = Any[]
    _signal_origin(f, types; stops)
    return unique(stops)
end

function _signals_by_type_uncached(@nospecialize(sig), depth::Int, seen::Base.IdSet{Any}, mode::Symbol)
    ci = _typed_body(sig)
    isnothing(ci) && return (false, false, false, nothing, false, false, nothing, nothing, nothing, true)
    return _scan_ci(ci, sig, depth, seen, mode)
end

# Would a value of this type have to be boxed to flow through a union-typed slot? An isbits type
# rides the union's inline payload and a mutable one is already a pointer; what costs is an
# immutable struct that is not inline-allocatable as a bare value — it gets a heap box on entry.
# Anything that is not a concrete `DataType` is assumed to box, which is the safe direction.
_box_on_entry(@nospecialize m) = !(m isa DataType) ? true :
    (Base.allocatedinline(m) && !Base.isbitstype(m) && !Base.issingletontype(m))

# --- which non-isbits `:new` is a heap allocation ------------------------------------------------
#
# A non-isbits `:new` in typed IR is not by itself a heap object. Two shapes that dominate library
# code are placed on the stack by codegen, and flagging them reported allocation-free BLAS/LAPACK
# callers as allocating:
#
#   `Ref{BlasInt}(n)` passed to a `ccall`       used only by the call (its `jl_value_ptr`
#                                               conversion and GC-root slot) and its own `:x` field
#   `view(v, 1:2)`, `Diagonal(d)`, `A'`         immutable wrappers handed to a resolved `:invoke`,
#                                               a constant-field read, or returned concretely
#
# Each case is decided by where the value GOES, so the rules below read its uses:
#
# - A value placed in a field declared with an abstract type is boxed, whatever holds it
#   (`Some{Any}(x)`, the F38 false negative) — checked first, for mutable and immutable alike.
# - An immutable is boxed only when it reaches a slot that needs a box: a dynamic call, a store
#   builtin writing a slot that cannot hold it inline, a `foreigncall`, a non-concrete `:invoke`
#   parameter or phi, a mutable container's abstract field, or an abstract return. Wrapping in
#   another immutable or a tuple follows the wrapper.
# - A mutable is a `ccall` `Ref` argument when every use is the call itself or a read/write of its
#   own field. Anything else falls back to escape analysis.
#
# Every unrecognized use counts as a box, so a shape these rules do not model stays flagged.
const _STORE_BUILTINS = Tuple(
    getfield(Core, s) for s in (
            :setfield!, :swapfield!, :modifyfield!, :replacefield!, :setfieldonce!, :setglobal!,
            :setglobalonce!, :memoryrefset!, :memoryrefswap!, :memoryrefmodify!,
            :memoryrefreplace!, :memoryrefsetonce!,
        ) if isdefined(Core, s)
)

# The declared type of the slot a store builtin writes `st.args[k]` into, or `nothing` when these
# rules cannot name it. A slot whose declared type is concrete and `Base.allocatedinline` holds the
# value's fields in place, so nothing is heap-allocated to store it; a pointer slot (an abstract or
# union-typed field, a `Vector{Any}` element) needs the value boxed first. Only the two forms that
# carry the destination in a fixed argument position are modeled — everything else returns `nothing`
# and stays flagged.
function _store_slot_type(ci, @nospecialize(sig), @nospecialize(callee), st::Expr, k::Int)
    a = st.args
    if callee === Core.setfield! && k == 4 && length(a) >= 4
        recv = _stmt_arg_type(ci, sig, a[2])
        recv isa Core.Const && (recv = Core.Typeof(recv.val))
        fld = a[3] isa QuoteNode ? a[3].value : a[3]
        (recv isa DataType && (fld isa Symbol || fld isa Int)) || return nothing
        return try
            fieldtype(recv, fld)
        catch
            nothing
        end
    elseif callee === Core.memoryrefset! && k == 3 && length(a) >= 3
        mr = _stmt_arg_type(ci, sig, a[2])
        return mr isa Type && mr <: Core.GenericMemoryRef ? eltype(mr) : nothing
    end
    return nothing
end

# For each SSA value, the (statement, argument position) pairs that read it.
const _SSAUses = Vector{Vector{Tuple{Int, Int}}}

function _ssa_uses(ci)::_SSAUses
    uses = [Tuple{Int, Int}[] for _ in eachindex(ci.code)]
    for (j, st) in enumerate(ci.code)
        vals = st isa Expr ? st.args :
            st isa Core.PhiNode ? st.values :
            st isa Core.PiNode ? Any[st.val] :
            st isa Core.ReturnNode && isdefined(st, :val) ? Any[st.val] : Any[]
        for k in eachindex(vals)
            isassigned(vals, k) || continue   # a phi's edge from an unreachable predecessor
            v = vals[k]
            v isa Core.SSAValue && push!(uses[v.id], (j, k))
        end
    end
    return uses
end

function _boxes_into_field(ci, @nospecialize(sig), st::Expr, @nospecialize(nt))
    nt isa DataType || return true
    for k in 2:length(st.args)
        FT = k - 1 <= fieldcount(nt) ? fieldtype(nt, k - 1) : Any
        isconcretetype(FT) && continue
        AT = _stmt_arg_type(ci, sig, st.args[k])
        AT = AT isa Core.Const ? typeof(AT.val) : AT
        if AT isa DataType && isconcretetype(AT) && !ismutabletype(AT) && !Base.issingletontype(AT)
            return true
        end
    end
    return false
end

# The type a `:new` constructs. Optimized IR may name it with a `GlobalRef` (`%new(Base.ComplexF64, …)`)
# instead of holding the `DataType`.
_new_type(ci, st::Expr) = (a = st.args[1]; a isa Type ? a : _static_callee(ci, a))

function _immutable_escapes(ci, @nospecialize(sig), uses, dead, i::Int, seen::BitSet = BitSet())
    i in seen && return false
    push!(seen, i)
    for (j, k) in uses[i]
        dead[j] && continue
        st = ci.code[j]
        if st isa Core.ReturnNode
            isconcretetype(ci.rettype) || return true
        elseif st isa Core.PhiNode || st isa Core.PiNode
            isconcretetype(ci.ssavaluetypes[j]) || return true
            _immutable_escapes(ci, sig, uses, dead, j, seen) && return true
        elseif Meta.isexpr(st, :invoke)
            mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
            mi isa Core.MethodInstance || return true
            # `args[2]` is the callee and lines up with `specTypes.parameters[1]`.
            ps = mi.specTypes.parameters
            (k - 1 <= length(ps) && isconcretetype(ps[k - 1])) || return true
        elseif Meta.isexpr(st, :new)
            ct = _new_type(ci, st)
            if ct isa DataType && !ismutabletype(ct)
                _immutable_escapes(ci, sig, uses, dead, j, seen) && return true
            else
                (ct isa DataType && k - 1 <= fieldcount(ct) && isconcretetype(fieldtype(ct, k - 1))) ||
                    return true
            end
        elseif Meta.isexpr(st, :call)
            callee = _static_callee(ci, st.args[1])
            if callee === Core.tuple
                _immutable_escapes(ci, sig, uses, dead, j, seen) && return true
            elseif callee isa Core.Builtin || callee isa Core.IntrinsicFunction
                # Position 2 is the object being written into, not the value being stored. A store
                # into a slot that holds the value inline copies its fields into place and needs no
                # box; any other destination — or one these rules cannot name — does.
                if k > 2 && any(b -> callee === b, _STORE_BUILTINS)
                    FT = _store_slot_type(ci, sig, callee, st, k)
                    (FT isa Type && isconcretetype(FT) && Base.allocatedinline(FT)) || return true
                end
            else
                return true
            end
        elseif Meta.isexpr(st, :gc_preserve_begin)
            # `GC.@preserve x` roots `x` for a block. It neither stores nor copies `x`, so an
            # immutable it preserves stays where it is: a preserved `view` reads 0 bytes.
            continue
        else
            return true
        end
    end
    return false
end

# `Base.unsafe_convert(Ptr, ref)` lowers to a `jl_value_ptr` call on the `Ref` and a `bitcast` of the
# result. The pointer is confined when everything it reaches is a `bitcast` that is itself confined,
# or a `ccall`; a pointer stored, returned or passed to a Julia call may outlive the frame.
function _ptr_confined(ci, uses, i::Int)
    for (j, _) in uses[i]
        st = ci.code[j]
        if Meta.isexpr(st, :foreigncall)
            continue
        elseif Meta.isexpr(st, :call) && _static_callee(ci, st.args[1]) === Core.bitcast
            _ptr_confined(ci, uses, j) || return false
        else
            return false
        end
    end
    return true
end

function _ccall_ref_only(ci, uses, i::Int)
    sawccall = false
    for (j, k) in uses[i]
        st = ci.code[j]
        if Meta.isexpr(st, :foreigncall)
            occursin("jl_value_ptr", string(st.args[1])) && !_ptr_confined(ci, uses, j) && return false
            sawccall = true
        elseif Meta.isexpr(st, :gc_preserve_begin)
            continue
        elseif Meta.isexpr(st, :call) && k == 2
            callee = _static_callee(ci, st.args[1])
            (callee === Core.getfield || callee === Core.setfield!) || return false
        else
            return false
        end
    end
    return sawccall
end

function _new_allocates(ci, @nospecialize(sig), uses, dead, i::Int, newsdead)
    st = ci.code[i]
    nt = _new_type(ci, st)
    nt isa Type || return true
    Base.isbitstype(nt) && return false
    _boxes_into_field(ci, sig, st, nt) && return true
    nt isa DataType && !ismutabletype(nt) && return _immutable_escapes(ci, sig, uses, dead, i)
    _ccall_ref_only(ci, uses, i) && return false
    return !newsdead()
end

function _scan_ci(
        ci, @nospecialize(sig), depth::Int, seen::Base.IdSet{Any}, mode::Symbol = :full, top::Bool = false,
        trace::Union{Nothing, Vector{Any}} = nothing
    )
    alloc = false
    boxing = false
    dictlookup = false                # a runtime AbstractDict accessor reached on the hot path
    abscontainer = nothing            # the abstract element type of the first abstract-eltype container seen
    barrier = false                   # a call reached a recognized one-time-init allocation barrier
    unionphi = false                  # a union-typed phi whose members do not all ride unboxed (F39)
    exempt = nothing                  # the first `@strict_exempt :noalloc` callee whose allocation was excused
    # The first registered barrier found to box, or to look up a dictionary, inside itself. A barrier
    # excuses only allocation: what else it does is judged at the barrier, once, and its callers
    # are pointed there rather than failed again for the same cause.
    barrier_dict = nothing
    barrier_box = nothing
    truncated = false                 # part of the call graph was left unread
    # Per frame, so a callee's own `:new`s are judged against the callee's own escape analysis.
    # Computed on demand: the analysis costs about as much as the whole rest of the scan, and it can
    # only change the verdict at a non-isbits `:new`/`memorynew` that nothing else has flagged yet.
    # Corpus-measured (PureBLAS + PureIPM, 120 specializations): 57 frames reach no such statement.
    escmemo = Ref{Union{Nothing, Bool}}(nothing)
    newsdead() = escmemo[] === nothing ? (escmemo[] = _all_news_nonescaping(sig))::Bool : escmemo[]::Bool
    dead = ignore_throw() ? _deadend_mask(ci.code) : falses(length(ci.code))
    # Built on demand, like the escape analysis: only a non-isbits `:new` reads it.
    # Both branches are asserted, like `newsdead` above. Without it the memo's `Union{Nothing, …}`
    # is the closure's return type: the `isnothing` check narrows the FIRST load of the `Ref`, and
    # the else branch is a second, separate load that inference cannot narrow. That union reaches
    # `_ccall_ref_only` and `_new_allocates`, which then compile a `Nothing` specialization whose
    # only possible act is to throw on `uses[i]`.
    usememo = Ref{Union{Nothing, _SSAUses}}(nothing)
    ssauses() = isnothing(usememo[]) ? (usememo[] = _ssa_uses(ci))::_SSAUses : usememo[]::_SSAUses
    for (i, st) in enumerate(ci.code)
        local T = ci.ssavaluetypes[i]
        if top && abscontainer === nothing && _abstract_container(T)
            abscontainer = eltype(T)
        end
        # `:boxing` reads dispatch only: an allocation, a dictionary lookup and a union phi are other questions.
        if mode === :boxing && (st isa Core.PhiNode || Meta.isexpr(st, :foreigncall) || Meta.isexpr(st, :new))
            continue
        end
        if Meta.isexpr(st, :foreigncall)
            dead[i] && continue
            tgt = lowercase(string(st.args[1]))
            if any(p -> occursin(p, tgt), _ALLOC_FFI)
                alloc = true
                isnothing(trace) || push!(trace, (i, st, :alloc))
            end
            # An `IdDict` runtime lookup inlines to a `jl_eqtable_get`/`_put`/`_pop` ccall (no `:get`
            # method survives in optimized IR), so the method-name rules below never see it. This is
            # the exact PureBLAS `_symm_scr` shape — detect the primitive directly.
            occursin("eqtable", tgt) && (dictlookup = true)
        elseif st isa Core.PhiNode
            # F39. A non-isbits union phi is a TAGGED POINTER, so a member that normally lives
            # unboxed has to be heap-boxed to flow through it. That box leaves no `:new` and no
            # allocating `foreigncall` behind — its only trace in optimized IR is the phi's own type —
            # so every other rule here is blind to it, and so is JET, because union splitting is not
            # dynamic dispatch. Measured on `PureBLAS._trsm_right!`: 0 B through a `Matrix`, 64 B per
            # call through a `SubArray`, under a contract declaring the method allocation-free.
            #
            # Member count is NOT the discriminator — a union that splits perfectly still boxes.
            # Representation is: isbits members ride the unboxed payload, mutable members are already
            # pointers, and an immutable struct holding heap references (`SubArray`, `Adjoint`,
            # `Tuple{String,Int}`) must be boxed on the way in.
            if !dead[i]
                local PT = ci.ssavaluetypes[i]
                if PT isa Union && !Base.isbitsunion(PT) && any(_box_on_entry, Base.uniontypes(PT))
                    unionphi = true
                end
            end
        elseif Meta.isexpr(st, :new)
            dead[i] && continue
            # Which non-isbits `:new`s allocate is decided by `_new_allocates`; see the note above it.
            if !alloc && _new_allocates(ci, sig, ssauses(), dead, i, newsdead)
                alloc = true
                isnothing(trace) || push!(trace, (i, st, :alloc))
            end
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
                    if _mi_is_strictmode(mi)
                        # A guard the caller's own macros left behind: skipped entirely, not treated
                        # as a barrier. A barrier records `barrier = true`, which grants an allocation
                        # exemption elsewhere; StrictMode's presence in a body says nothing about
                        # whether the caller's own code allocates, so it must leave no trace at all.
                    elseif _mi_is_barrier(mi)
                        # The callee itself IS a recognized barrier (e.g. `(::OncePerProcess)()`,
                        # or a directly-registered function) — its one-time cold-path allocation
                        # is not a steady-state cost, so recursion stops here rather than seeing it.
                        barrier = true
                        if depth > 0 && _is_registered_callee(first(mi.specTypes.parameters))
                            _, b2, d2, _, _, _, _, bd2, bb2, _ = _signals_by_type(mi.specTypes, depth - 1, seen, mode)
                            here = _demangle(mi.def.name)
                            isnothing(barrier_dict) && (barrier_dict = d2 ? here : bd2)
                            isnothing(barrier_box) && (barrier_box = b2 ? here : bb2)
                        end
                    else
                        _mi_dict_lookup(mi) && (dictlookup = true)
                        # The walk stops once `alloc`, `boxing` and `dictlookup` are all set:
                        # nothing deeper can change those three, and each further level is a fresh
                        # `code_typed_by_type` (widening this condition is measurably expensive on
                        # signal-saturated functions). So `barrier` is ONE-SIDED below a saturated
                        # frontier: a barrier reachable only there is never recorded, and `barrier
                        # == false` on a saturated result means "not looked for", not "not there".
                        # That is safe in one direction only, which is the direction that holds:
                        # acting on `barrier` means granting an allocation exemption, and every
                        # such reader first demands a signal set free of `alloc`/`boxing` — which a
                        # saturated result can never be. A missed barrier can only withhold an
                        # exemption, never grant one. `abscontainer` is one-sided here too, and
                        # more so: it is a top-level-only signal, never propagated from a callee
                        # (widening it to callees and to dict value types over-flags `IdDict`, #17).
                        # The package's own code is followed to the end of its call graph (bounded by
                        # `_SCAN_BODY_BUDGET`): `depth` counts levels of Base only, since an allocation
                        # reached through a chain of the package's own helpers is as real as one in the
                        # first. Below the last Base level `depth` is -1, which follows user code alone.
                        user = _enters_user_code(mi)
                        follows = depth > 0 || (depth < 0 && user)
                        # A callee can still change the answer while `undecided`: `:alloc` is decided by the
                        # first allocation or boxing, `:boxing` by the first boxing, and `:full` also needs the
                        # dictionary lookup.
                        undecided = mode === :full ? (!alloc || !boxing || !dictlookup) :
                            mode === :alloc ? (!alloc && !boxing) : !boxing
                        if follows && undecided && length(seen) > _SCAN_BODY_BUDGET[]
                            truncated = true
                        elseif follows && undecided
                            sub = user ? depth : (depth > 1 ? depth - 1 : -1)
                            a2, b2, d2, _, br2, up2, ex2, bd2, bb2, tr2 = _signals_by_type(mi.specTypes, sub, seen, mode)
                            tr2 && (truncated = true)
                            isnothing(barrier_dict) && (barrier_dict = bd2)
                            isnothing(barrier_box) && (barrier_box = bb2)
                            # A callee exempted from `:noalloc` has its allocation excused here
                            # too — it is the same allocation, already excused where it is made —
                            # and the excusal is recorded, so the caller is reported as reaching it
                            # rather than as clean. Only allocation is excused: the callee's boxing
                            # and dictionary lookups still count against the caller.
                            exname = a2 ? _mi_exempt_name(mi) : nothing
                            if isnothing(exname)
                                a2 && (alloc = true)
                            elseif isnothing(exempt)
                                exempt = exname
                            end
                            (isnothing(exempt) && !isnothing(ex2)) && (exempt = ex2)
                            (b2 && !_in_scheduler(mi)) && (boxing = true)
                            d2 && (dictlookup = true)
                            br2 && (barrier = true)
                            up2 && (unionphi = true)
                        elseif iszero(depth) && !dictlookup && mi.def isa Method &&
                                !(Base.moduleroot(mi.def.module) === Base || Base.moduleroot(mi.def.module) === Core)
                            # The walk ends here with a callee of the user's own unread: whatever it
                            # does is not in this verdict, so `:owned` reports it as not checked.
                            truncated = true
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
                if !(mode === :boxing || alloc || dead[i] || newsdead())
                    alloc = true
                    isnothing(trace) || push!(trace, (i, st, :alloc))
                end
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
                isnothing(trace) || push!(trace, (i, st, :boxing))
            elseif !boxing
                # Concrete result but a boxy argument on a non-builtin call = runtime dispatch
                # that inference resolved only by return type (e.g. `Vec{32,UInt8}(::Tuple{Vararg})`).
                if !(callee isa Core.Builtin || callee isa Core.IntrinsicFunction)
                    if any(a -> _boxy(_stmt_arg_type(ci, sig, a)), st.args[2:end])
                        boxing = true
                        isnothing(trace) || push!(trace, (i, st, :boxing))
                    end
                end
            end
        end
    end
    return (alloc, boxing, dictlookup, abscontainer, barrier, unionphi, exempt, barrier_dict, barrier_box, truncated)
end

# The name of the function `mi` calls, when an exemption in scope covers `:noalloc` for it at the
# types it is called with; `nothing` otherwise.
function _mi_exempt_name(mi::Core.MethodInstance)
    mi.def isa Method || return nothing
    es = _noalloc_exemptions()
    isempty(es) && return nothing
    name = _demangle(mi.def.name)
    ps = mi.specTypes.parameters
    types = length(ps) > 1 ? Tuple(ps[2:end]) : ()
    root = Base.moduleroot(mi.def.module)
    for (mod, e) in es
        # The declaring module when recorded, else the package root of the store it came from.
        if !isnothing(e.mod)
            mi.def.module === e.mod || continue
        else
            (isnothing(mod) || mod === root) || continue
        end
        _covers(e, name, types, :noalloc) && return name
    end
    return nothing
end

# --- Base.infer_effects layer (cheap; basis for @assert_effects in Phase 3) -------------------

"""
    StrictMode.effects(f, types) -> Core.Compiler.Effects

The compiler's inferred effects for `f`'s signature — a cheap (inference-only) read of whether a
method is `:nothrow`, `:effect_free`, `:terminates`, `:consistent`, etc. Used by the `:fast`
triage and by `@assert_effects`.
"""
effects(@nospecialize(f), @nospecialize(types::Tuple)) = _infer_effects(f, types)

# Predicate by symbol, so callers can ask `effect_holds(eff, :nothrow)`.
#
# Every one of these is a PROOF of the property, so `false` means the compiler could not establish
# it, NOT that the property fails. `:noub` is `false` for a non-`const` global read and for a
# dynamic call, neither of which is undefined behavior (measured), so a caller may act on `true`
# and must treat `false` as unknown.
function effect_holds(eff, sym::Symbol)
    sym === :nothrow && return Core.Compiler.is_nothrow(eff)
    sym === :effect_free && return Core.Compiler.is_effect_free(eff)
    sym === :terminates && return Core.Compiler.is_terminates(eff)
    sym === :consistent && return Core.Compiler.is_consistent(eff)
    sym === :nonoverlayed && return Core.Compiler.is_nonoverlayed(eff)
    sym === :notaskstate && return Core.Compiler.is_notaskstate(eff)
    sym === :noub && return Core.Compiler.is_noub(eff)
    sym === :inaccessiblememonly && return Core.Compiler.is_inaccessiblememonly(eff)
    sym === :nortcall && return Core.Compiler.is_nortcall(eff)
    throw(
        ArgumentError(
            "unknown effect :$sym; expected :nothrow, :effect_free, :terminates, :consistent, " *
                ":nonoverlayed, :notaskstate, :noub, :inaccessiblememonly, or :nortcall"
        )
    )
end

# --- scoped values: a value that must not leave the frame that obtained it ----------------------

# A borrow handle, a lock token, a pointer into a slab: a value that is valid only inside the frame
# that obtained it, and whose escape is a use-after-free rather than a slow path. The compiler
# already answers this question — the escape analysis above runs for allocation suppression — so
# what is missing is a way to ASK it.
#
# Registration is by TYPE, not by the function that produces the value. The analysis must run on IR
# after inlining to be meaningful, and a small `borrow!` inlines into its caller, taking the callee
# boundary with it. The handle's type survives that, so a type is the thing still identifiable at
# the point the question can be answered.
const _SCOPED_TYPES = Any[]
const _SCOPED_LOCK = ReentrantLock()

"""
    register_scoped!(T::Type) -> T

Declare that a value of type `T` must not escape the frame that obtains it, so `:noescape` reports
one that does.

For a handle whose validity is bounded by a scope — a borrow from an arena, a pointer into a slab,
a token for a held lock — escape is a use-after-free, not a performance problem. Register the type,
then assert it where the handle is obtained:

```julia
register_scoped!(ArenaHandle)
@assert_noescape compute!(arena, A, b)
```

What it proves is **confinement**: that the handle is provably unable to leave this frame. A pass is
trustworthy. A failure means confinement could not be proved, which covers the value being
returned, stored to a global or a field, captured by a closure, OR handed to a function the
analysis cannot see through — the escape state of an unanalyzed callee is assumed rather than
computed, so those cases cannot be told apart. The finding names the type and lists them.

Only a handle CREATED in the frame carries a verdict. The escape state of a call result is assumed
rather than computed, so a handle from a producer that did not inline reads as escaping whatever it
does; that is reported as undecided rather than as an escape, naming the fix. An `@inline`
accessor, the usual shape for a borrow, gives a real verdict.

It does **not** cover a handle that stays inside the frame and is used after its scope has ended —
that is not an escape, and the compiler's analysis will correctly call it clean. Rejecting that
needs the syntactic check a scope macro can do at expansion time, where the end of the block is
visible. The two cover different halves and neither subsumes the other.

Registration is by type because the analysis runs on IR after inlining, where a small accessor has
been inlined into its caller and the callee boundary no longer exists. The type does.

See also [`@assert_noescape`](@ref), [`register_alloc_barrier!`](@ref).
"""
function register_scoped!(@nospecialize(T::Type))
    @lock _SCOPED_LOCK begin
        any(S -> S === T, _SCOPED_TYPES) || push!(_SCOPED_TYPES, T)
    end
    clear_cache!()
    return T
end

function _is_scoped_type(@nospecialize(T))
    T isa Type || return false
    # `Union{}` is a subtype of every type, so a bare `T <: S` reads a statement that does not
    # return a value — one whose only outcome is a throw — as carrying a scoped handle.
    T === Union{} && return false
    # A union carries a scoped value if any member is one. Without this a union-typed statement is
    # skipped, because `Union{A,B} <: A` is false, and a handle hiding in one branch of a producer
    # that did not inline would go unexamined rather than being reported as undecided.
    T isa Union && return _is_scoped_type(T.a) || _is_scoped_type(T.b)
    @lock _SCOPED_LOCK for S in _SCOPED_TYPES
        T <: S && return true
    end
    return false
end

"""
    _escaping_scoped(sig) -> (; escaped, undetermined)

The registered scoped types that escape the frame `sig` names, and the ones whose fate this cannot
decide. Both empty means nothing escaped, which is also the answer when no type is registered.

Only a `:new` carries a verdict. The escape state of a value returned by a call comes from the
conservative cache callback, which assumes an uncached callee escapes its arguments — so a handle
from a producer that did not inline reads as escaping whatever it does, and reporting that as an
escape is a false positive. Those land in `undetermined` instead: a frame whose handle is created
elsewhere has to be asked about where the handle is created.
"""
function _escaping_scoped(@nospecialize(sig))
    sig = _forwarded_sig(sig)   # a default or keyword forwarder hands the handle to its body
    isempty(_SCOPED_TYPES) && return (; escaped = String[], undetermined = String[])
    EA = Core.Compiler.EscapeAnalysis
    irs = _code_ircode_by_type(sig)
    isempty(irs) && throw(ArgumentError("no IR for $sig"))
    ir = first(irs)[1]
    st = EA.analyze_escapes(
        ir, length(ir.argtypes), Core.Compiler.SimpleInferenceLattice.instance, Returns(false)
    )
    bad = String[]
    undet = String[]
    for i in eachindex(ir.stmts.type)
        T = Core.Compiler.widenconst(ir.stmts.type[i])
        _is_scoped_type(T) || continue
        s = ir.stmts.stmt[i]
        s isa Expr || continue        # an SSAValue alias of a statement already considered
        name = string(T)
        if s.head === :new
            EA.has_no_escape(st[Core.SSAValue(i)]) && continue
            name in bad || push!(bad, name)
        elseif s.head === :invoke || s.head === :call
            name in undet || push!(undet, name)
        end
    end
    # The escape analysis tracks heap objects. An immutable value has no identity, so it reads as
    # confined even when returned, and a returned copy of a handle carries whatever pointer it holds
    # out of the frame. A return of a handle created here is therefore an escape whatever the
    # analysis says.
    for s in ir.stmts.stmt
        (s isa Core.ReturnNode && isdefined(s, :val)) || continue
        v = s.val
        while v isa Core.SSAValue && ir.stmts.stmt[v.id] isa Core.SSAValue
            v = ir.stmts.stmt[v.id]
        end
        v isa Core.SSAValue || continue
        src = ir.stmts.stmt[v.id]
        Meta.isexpr(src, :new) || continue
        T = Core.Compiler.widenconst(ir.stmts.type[v.id])
        _is_scoped_type(T) && !(string(T) in bad) && push!(bad, string(T))
    end
    return (; escaped = bad, undetermined = undet)
end

# `:noescape`'s verdict for one signature, shared by BOTH tiers through
# `_compiled_output_finding`. The answer comes from the compiler's own escape analysis, so no
# backend has anything to add and a second copy in `StrictModeTest` could only drift.
function _noescape_finding(
        @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg; tier::Symbol = :report
    )
    r = _escaping_scoped(Tuple{typeof(f), types...})
    reason = !isempty(r.escaped) ?
        "a scoped value is not provably confined to this frame: " * join(r.escaped, ", ") *
        " — it is returned, stored, or captured, or handed to a function this analysis " *
        "cannot see through" :
        !isempty(r.undetermined) ?
        "cannot decide whether a scoped value escapes: " * join(r.undetermined, ", ") *
        " arrives from a call that did not inline, and the escape state of a call result " *
        "is assumed rather than computed" :
        "no scoped value escapes the frame"
    return _mkfinding(
        md, fn, sg, :noescape,
        !(isempty(r.escaped) && isempty(r.undetermined)), reason, "", 0,
        !isempty(r.escaped) ?
            "return a copy, keep the handle inside the scope that owns it, or inline the callee that receives it" :
            isempty(r.undetermined) ? "" :
            "mark the function that produces the handle `@inline`, or assert this where the handle is created";
        tier
    )
end

# Inference runs under an interpreter whose results never enter the compiler's own code cache. Under
# the native interpreter every body the scan reads is cached for the compiler, and a package image
# generated while a consumer precompiles holds what is cached in that process: measured on a package
# of 300 methods with a module check, the scan took the image from 8.5 MB to 58 MB and the precompile
# from 0.5 GB to 4 GB at its peak. The results live in a cache of this module's own instead, reused
# by the scans that follow and emptied with the other memos.
#
# Nothing the scan infers may be reachable from the compiler's global state either, since the
# serializer writes what is reachable into the image. Inference reaches it three ways, and all are
# turned off for this interpreter:
#   - compressing an inferred body (`jl_compress_ir`) appends every object the body names and its
#     edges do not, such as the `CodeInstance` of a call inlined from a callee, to the roots of the
#     body's method. `may_compress` is false, so a body is kept as a `CodeInfo` and nothing is
#     rooted.
#   - `finish!` records a backedge from each callee to the caller's `CodeInstance`. It does so only
#     when the result is still valid in `validation_world`, so passing `typemax(UInt)` skips it.
#   - `codeinst_as_edge`, which makes the edge to a constant-propagated result, records the same
#     backedges for it; this interpreter's method makes the edge and records none.
# Measured on Julia 1.13 with a package that checks 400 signatures at its precompile: 209 of the
# scan's `CodeInstance`s in method roots and 980 backedges to them once it was loaded; none with
# all three off.
#
# Without backedges an edit cannot invalidate a cached result, so the cache answers only in the
# world it was filled in and is emptied when inference runs in another. A world number is meaningful
# only in the process that counted it, so the comparison is inequality, not order.
# Giving up reuse across worlds has a cost: 87 signatures checked with a method definition before each,
# as `@strict_function` does at a precompile, take 4.0 s against 3.1 s.
const _CC = Base.Compiler

struct _ScanCacheOwner end

struct _ScanCodeCache
    entries::IdDict{Core.MethodInstance, Core.CodeInstance}
    world::Base.RefValue{UInt}
    lock::ReentrantLock
end
_ScanCodeCache() = _ScanCodeCache(IdDict{Core.MethodInstance, Core.CodeInstance}(), Ref(UInt(0)), ReentrantLock())

const _SCAN_CODE_CACHE = _ScanCodeCache()

function _scan_cache_lookup(c::_ScanCodeCache, mi::Core.MethodInstance, worlds)
    world = first(worlds)
    world == last(worlds) || return nothing
    return @lock c.lock (c.world[] == world ? get(c.entries, mi, nothing) : nothing)
end

Base.haskey(wvc::_CC.WorldView{_ScanCodeCache}, mi::Core.MethodInstance) =
    !isnothing(_scan_cache_lookup(wvc.cache, mi, wvc.worlds))

function Base.get(wvc::_CC.WorldView{_ScanCodeCache}, mi::Core.MethodInstance, default)
    ci = _scan_cache_lookup(wvc.cache, mi, wvc.worlds)
    return isnothing(ci) ? default : ci
end

function Base.getindex(wvc::_CC.WorldView{_ScanCodeCache}, mi::Core.MethodInstance)
    ci = _scan_cache_lookup(wvc.cache, mi, wvc.worlds)
    isnothing(ci) && throw(KeyError(mi))
    return ci
end

function Base.setindex!(wvc::_CC.WorldView{_ScanCodeCache}, ci::Core.CodeInstance, mi::Core.MethodInstance)
    c = wvc.cache
    world = first(wvc.worlds)
    @lock c.lock begin
        if world != c.world[]
            empty!(c.entries)
            c.world[] = world
        end
        c.entries[mi] = ci
    end
    return wvc
end

struct _ScanInterpreter <: _CC.AbstractInterpreter
    world::UInt
    inf_params::_CC.InferenceParams
    opt_params::_CC.OptimizationParams
    inf_cache::Vector{_CC.InferenceResult}
end

_ScanInterpreter(world::UInt = Base.get_world_counter()) =
    _ScanInterpreter(world, _CC.InferenceParams(), _CC.OptimizationParams(), _CC.InferenceResult[])

_CC.InferenceParams(interp::_ScanInterpreter) = interp.inf_params
_CC.OptimizationParams(interp::_ScanInterpreter) = interp.opt_params
_CC.get_inference_world(interp::_ScanInterpreter) = interp.world
_CC.get_inference_cache(interp::_ScanInterpreter) = interp.inf_cache
_CC.cache_owner(::_ScanInterpreter) = _ScanCacheOwner()
_CC.code_cache(interp::_ScanInterpreter) = _CC.WorldView(_SCAN_CODE_CACHE, _CC.WorldRange(interp.world))
_CC.may_compress(::_ScanInterpreter) = false
_CC.finish!(interp::_ScanInterpreter, caller::_CC.InferenceState, ::UInt, time_before::UInt64) =
    @invoke _CC.finish!(interp::_CC.AbstractInterpreter, caller::_CC.InferenceState, typemax(UInt)::UInt, time_before::UInt64)

# The `CodeInstance` that stands as the edge to a constant-propagated result. The compiler's own
# method (the same in 1.12 and 1.13) also widens a current result's `max_world` to `typemax(UInt)`
# and calls `store_backedges` for it; this one does neither.
function _CC.codeinst_as_edge(interp::_ScanInterpreter, sv::_CC.InferenceState, @nospecialize existing_edge)
    min_world, max_world = first(sv.world.valid_worlds), last(sv.world.valid_worlds)
    edges = Core.svec(sv.edges...)
    if existing_edge isa Core.CodeInstance && existing_edge.min_world >= min_world &&
            existing_edge.max_world <= max_world && existing_edge.edges == edges
        return existing_edge
    end
    return Core.CodeInstance(
        sv.linfo, _ScanCacheOwner(), Any, Any, nothing, nothing, zero(Int32),
        min_world, max_world, zero(UInt32), nothing, nothing, edges
    )
end

# A package image holds the specializations recorded while it was generated (`Base.newly_inferred`).
# What running the scan makes the compiler specialize is the scan's own, not the consumer's, so the
# records made inside an inference call are taken back when a package is being generated.
# What the scan makes the compiler specialize while a package is being generated is the scan's own
# machinery, specialized on the types it was asked about (`to_tuple_type`, `signature_type`, `code_typed`
# and everything `TypeContracts.trim_report` calls, one set per checked signature). The records of those
# specializations are taken back when the scan returns, so the package's image does not hold them:
# measured on 100 checked signatures with `:trim_compatible`, 5752 specializations and 8.6 MB of image
# against 748 and 1.0 MB.
# No closure here: a closure over a `Type` is a method specialized on that type.
_window_open() =
    (ccall(:jl_generating_output, Cint, ()) == 1 && isdefined(Base, :newly_inferred)) ? length(Base.newly_inferred) : -1

function _window_close(n::Int)
    n >= 0 && length(Base.newly_inferred) > n && resize!(Base.newly_inferred, n)
    return nothing
end

# The other readings of the compiler's inference answer under the same interpreter.
function _return_types(@nospecialize(f), @nospecialize(types))
    n = _window_open()
    try
        return Base.return_types(f, types; interp = _ScanInterpreter())
    finally
        _window_close(n)
    end
end

function _infer_effects(@nospecialize(f), @nospecialize(types))
    n = _window_open()
    try
        return Base.infer_effects(f, types; interp = _ScanInterpreter())
    finally
        _window_close(n)
    end
end

function _code_ircode_by_type(@nospecialize(sig))
    n = _window_open()
    try
        return Base.code_ircode_by_type(sig; optimize_until = _INLINING_PASS, interp = _ScanInterpreter())
    finally
        _window_close(n)
    end
end

# `code_typed` with only the results that carry code. When a `@generated` method's generator raises
# for a signature, Julia returns that `Method` in place of the `CodeInfo`. Every reader here treats
# an empty result as a body it could not read; a `Method` read as code crashed the analysis instead.
#
# Nothing in the reading below is specialized on the function or the types being read. A call that is
# handed a `Type` or a function value compiles a method for exactly that value, and a package that is
# checked at its own precompile keeps those methods in its image: one per checked signature for each
# of `signature_type`, `to_tuple_type` and `code_typed`, a few thousand on a package with a few
# hundred checked kernels.
_sigtype(@nospecialize(f), @nospecialize(types)) = Core.apply_type(Tuple, Core.Typeof(f), types...)

function _code_typed(
        @nospecialize(f), @nospecialize(types); optimize::Bool = true, debuginfo::Symbol = :default
    )
    ps = types isa Type ? Base.unwrap_unionall(types).parameters : types
    return _code_typed_by_type(Core.apply_type(Tuple, Core.Typeof(f), ps...); optimize, debuginfo)
end

function _code_typed_by_type(@nospecialize(sig); optimize::Bool = true, debuginfo::Symbol = :default)
    n = _window_open()
    try
        return filter(
            p -> first(p) isa Core.CodeInfo,
            Base.code_typed_by_type(sig; optimize, debuginfo, interp = _ScanInterpreter())
        )
    finally
        _window_close(n)
    end
end

# `:owned`'s walk to the end of the package's own code, for a call whose ordinary walk stopped at the
# depth limit. A lookup can only sit in the package's code or in a Base dictionary accessor that code
# calls, and Base is not entered, so following the package's own callees to the end — each body once —
# settles it: `:lookup`, `:clean`, or `:budget` when even this walk ran out of bodies. A body that
# cannot be read is not clean, so it ends the walk as `:budget`, "not established". A registered
# barrier is not entered; its own causes are reported where it is checked.
const _OWNED_DEEP_BUDGET = 2000
const _OWNED_DEEP_MEMO = Dict{Tuple{Any, UInt}, Symbol}()
const _OWNED_DEEP_LOCK = ReentrantLock()

# One body of the walk: whether it holds a dictionary lookup of its own, and the signatures it calls
# that the walk enters (`nothing` when its body cannot be read). This depends on the body alone, so
# it is computed once per body and world and shared by every walk that reaches it; a package's
# entry points share most of their callees, and reading each body again for every one of them is
# what made a sweep of a few hundred signatures cost minutes.
const _OWNED_NODE_MEMO = IdDict{Any, Tuple{UInt, Bool, Union{Nothing, Vector{Any}}}}()

function _owned_node(@nospecialize(s))
    world = Base.get_world_counter()
    hit = @lock _OWNED_DEEP_LOCK get(_OWNED_NODE_MEMO, s, nothing)
    (!isnothing(hit) && hit[1] == world) && return (hit[2], hit[3])
    cts = try
        _code_typed_by_type(s; optimize = true)
    catch
        Any[]
    end
    lookup = false
    succ = nothing
    if !isempty(cts)
        ci = first(cts[1])
        seen = Base.IdSet{Any}()
        push!(seen, s)
        lookup = _scan_ci(ci, s, 0, seen)[3]
        succ = Any[]
        for st in ci.code
            Meta.isexpr(st, :invoke) || continue
            mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
            (mi isa Core.MethodInstance && mi.def isa Method) || continue
            # A Base function is entered only when it was handed the package's code or types to run —
            # a closure given to `sort` or `map`, a package type whose methods it calls.
            root = Base.moduleroot(mi.def.module)
            (root === Base || root === Core) && !_carries_user_type(mi.specTypes) && continue
            (_mi_is_strictmode(mi) || _mi_is_barrier(mi)) && continue
            push!(succ, mi.specTypes)
        end
    end
    @lock _OWNED_DEEP_LOCK (_OWNED_NODE_MEMO[s] = (world, lookup, succ))
    return (lookup, succ)
end

function _owned_deep(@nospecialize(sig))
    key = (sig, Base.get_world_counter())
    hit = @lock _OWNED_DEEP_LOCK get(_OWNED_DEEP_MEMO, key, nothing)
    isnothing(hit) || return hit
    seen = Base.IdSet{Any}()
    queue = Any[sig]
    v = :clean
    while !isempty(queue)
        s = popfirst!(queue)
        s in seen && continue
        push!(seen, s)
        if length(seen) > _OWNED_DEEP_BUDGET
            v = :budget
            break
        end
        lookup, succ = _owned_node(s)
        if lookup
            v = :lookup
            break
        end
        if isnothing(succ)
            v = :budget
            break
        end
        append!(queue, succ)
    end
    @lock _OWNED_DEEP_LOCK (_OWNED_DEEP_MEMO[key] = v)
    return v
end

# What a package image generated now would hold from this process's inference: the specializations
# recorded since the process started, by the module of their method. Meant to be called from the end
# of a module body while it precompiles, to see what the checks left in the image.
function _image_report(io::IO = stderr; top::Int = 10)
    bymod = Dict{String, Int}()
    byname = Dict{String, Int}()
    for ci in Base.newly_inferred
        d = ci.def
        mi = d isa Core.MethodInstance ? d : (isdefined(d, :def) ? d.def : nothing)
        mi isa Core.MethodInstance || continue
        mi.def isa Method || continue
        bymod[string(mi.def.module)] = get(bymod, string(mi.def.module), 0) + 1
        k = string(mi.def.module, ".", mi.def.name)
        byname[k] = get(byname, k, 0) + 1
    end
    pick(d) = first(sort(collect(d); by = x -> -x[2]), top)
    println(io, "specializations for the image: ", length(Base.newly_inferred))
    println(io, "  by module: ", pick(bymod))
    println(io, "  by method: ", pick(byname))
    return nothing
end
