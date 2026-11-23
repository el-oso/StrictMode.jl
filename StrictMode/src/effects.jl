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
    # Unoptimized IR keeps a local as a slot, and a call whose result is stored in one is the
    # right-hand side of an assignment: `b = unsafe_trust(u)` is `_3 = (%1)(_2)`. Read as a
    # statement that is no call, it hid every read whose result was given a name.
    Meta.isexpr(st, :(=)) && (st = st.args[2])
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

# A builtin whose result has no concrete type and which neither dispatches nor boxes: it hands back a
# value that is already a reference. `typeassert` and `Core.current_scope` (behind every `ScopedValue`
# read) return what they were given or what the task holds. A `getfield` with a run-time field name
# boxes only a field that is stored inline; when every field of the receiver is held by reference
# (`getproperty(F::QRPivoted, d::Symbol)` falling through to `getfield(F, d)`) it is a field lookup
# and a load: measured 0 bytes, against 16 for a struct of an `Int` and a `Float64`.
# `Core.compilerbarrier` (`Base.inferencebarrier`) returns its argument typed `Any`, which boxes a
# value stored inline and nothing else. Every guarantee macro leaves one in the caller's body, around
# the checked function, so reading it as boxing reports the guard against the function it guards.
function _plain_load(ci, @nospecialize(sig), @nospecialize(callee), st::Expr)
    (callee === Core.typeassert || (isdefined(Core, :current_scope) && callee === Core.current_scope)) && return true
    if callee === Core.compilerbarrier && length(st.args) >= 3
        A = _stmt_arg_type(ci, sig, st.args[3])
        A isa Core.Const && (A = Core.Typeof(A.val))
        return A isa Type && (Base.issingletontype(A) || !(isconcretetype(A) && Base.allocatedinline(A)))
    end
    (callee === Core.getfield && length(st.args) >= 3) || return false
    R = _stmt_arg_type(ci, sig, st.args[2])
    R isa Core.Const && (R = Core.Typeof(R.val))
    (R isa DataType && isconcretetype(R) && !(R <: Tuple)) || return false
    return all(i -> !Base.allocatedinline(fieldtype(R, i)), 1:fieldcount(R))
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
the call, then check that a second identical call allocates nothing
(`StrictModeTest.@test_steady_state`). The allocation proof then reports a caller whose only
allocations are inside such exempt functions as its own result, SM0018, listing each exempt
function with its reason. That is not a pass: `@test_noalloc` and the `test_*` gates fail it unless
they are given `allow_exempt = true`, and a caller with one allocation of its own fails either way.
The exemption has to be declared in the module that defines the function, as `@strict_exempt` in
its source is: one declared with no module covers by name and excuses nothing in the proof.

**A barrier excuses allocation, and nothing else.** Under `:noalloc` a box is an allocation, so a
caller passes whatever `f` allocates or boxes. Every other guarantee still reads `f` itself: a
dictionary lookup (`:owned`) or a boxed value (`:noboxing`) inside `f` is reported when `f` is
checked, once. A caller whose
only such cause lies inside `f` is neither failed again nor passed as if it had been checked: it
gets an `:info` finding that names `f`, so the reader can follow it to the one place it is reported.
A `:owned` failure on a `OncePerTask` accessor is the usual case: the lookup is the price of
per-task state, and it belongs to the accessor, not to every kernel that reaches it.

Registering is a whole-session, function-identity-keyed decision (not per-call-site), and clears
the findings cache (it changes `:noalloc`/`:noboxing` verdicts for every caller of `f`).

A callable object is registered as its type, `register_alloc_barrier!(Table)`, and that covers a
call of every `Table`: the scan reads the callee's type and has no value to tell one instance from
another. Passing one instance, `register_alloc_barrier!(Table(4))`, raises for that reason, as does
a closure that captures a variable. A function is the only instance of its type and is passed as
itself. Registering a type does not cover its constructor.

A registration made at a package's top level, while the package precompiles, is written into that
package's cache, so it is in force again in every process that loads it. Only the package being
precompiled is written, and `mod` names it. It defaults to the module that owns `f`, so
registering a function another package owns needs `mod = @__MODULE__` and raises without it:
the registration would hold for that precompile and be gone afterwards. A raise registers
nothing, in that precompile either. A call made from an
`__init__` runs again at every load, so it registers for the session and stores nothing. So does a
call made by the owning package's own code while another package precompiles, such as a
registration on first use that a dependent's precompile workload triggers. In a
session the registration lasts for the session.

```julia
@noinline function _my_calibrator()
    ...   # measures something once, memoizes it in a Ref/const
end
register_alloc_barrier!(_my_calibrator)
```
"""
function register_alloc_barrier!(@nospecialize(f); mod::Module = _owner_module(f))
    # A barrier is recognized by the type of the callee, which is all the scan has. One instance
    # of a type with several would stand for all of them without saying so.
    (f isa Type || isdefined(typeof(f), :instance)) || throw(
        ArgumentError(
            "register_alloc_barrier!: this is one instance of `$(_type_name(typeof(f)))`, and a " *
                "barrier is matched on the callee's type, so it would cover every " *
                "`$(_type_name(typeof(f)))`. Register the type, which says so: " *
                "`register_alloc_barrier!($(_type_name(typeof(f))))`."
        )
    )
    # `_ALLOC_BARRIERS` lives in this session. A package that registers at its own precompile loses
    # it at the next load, so the registration is also kept in the package named by `mod`, which is
    # serialized with it, and read back with the other loaded packages' (`_barrier_functions`).
    # Stored first: a registration that cannot be kept raises, and must leave the session unchanged.
    if ccall(:jl_generating_output, Cint, ()) == 1
        _persist_registration!(f, mod, _LOCAL_BARRIERS, "register_alloc_barrier!($(_func_name(f)))")
    else
        # A module that is closed to writes keeps the session registration only, which is all a
        # session needs.
        try
            store = _local_store!(mod, _LOCAL_BARRIERS, Any[])
            any(g -> g === f, store) || push!(store, f)
        catch
        end
    end
    push!(_ALLOC_BARRIERS, f)
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
_is_registered_callee(@nospecialize(p)) = p isa Type && any(f -> _barrier_covers(f, p), _barrier_functions())

# Whether a registration covers a callee of type `p`: a function covers its own type, and a
# registered type covers every instance of it. `Type{T}`, the callee of a constructor call, is
# not an instance of `T`.
_barrier_covers(@nospecialize(f), @nospecialize(p)) = f isa Type ? (p isa Type && p <: f) : p === typeof(f)

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

# The type of the callable whose keyword body `mi` is, or `nothing` for any other method. Lowering
# passes a keyword body its keyword values first and the callable after them, and records how many
# keyword values there are in the method's `nkw`. The name is no guide: a callable object's keyword
# body is named `#_#N`.
function _kwbody_self(mi::Core.MethodInstance)
    m = mi.def
    (m isa Method && m.nkw > 0) || return nothing
    st = mi.specTypes
    st isa DataType || return nothing
    ps = st.parameters
    return length(ps) >= m.nkw + 2 ? ps[m.nkw + 2] : nothing
end

# A registered function called with keywords is reached through two more methods: `Core.kwcall`, which
# carries the function at parameter 3, and the keyword body, which carries it after the keyword
# values (`_kwbody_self`). Both are the barrier: the allocation is the registered function's own.
function _is_registered_kw_callee(mi::Core.MethodInstance, ps)
    bs = _barrier_functions()
    (isempty(bs) || !(mi.def isa Method)) && return false
    ps[1] === typeof(Core.kwcall) && return length(ps) >= 3 && _is_registered_callee(ps[3])
    self = _kwbody_self(mi)
    return !isnothing(self) && _is_registered_callee(self)
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
_method_in_scheduler(m::Method) = Base.moduleroot(m.module) === Base && basename(string(m.file)) in _SCHEDULER_FILES
_in_scheduler(mi::Core.MethodInstance) = mi.def isa Method && _method_in_scheduler(mi.def)

# A callee the scan follows below the Base levels: one defined outside Base and Core, a Base method
# handed the package's code or types to run (a closure given to `map`), or Base's task, lock and
# condition code. Whether a wait allocates is decided several scheduler calls down (a task queue that
# grows, a work queue made on first use), and how many depends on what Base inlines, which differs
# between Julia releases: read to a fixed depth, the same `yield()` allocates on one and not another.
function _followed_to_end(mi::Core.MethodInstance)
    mi.def isa Method || return false
    _in_scheduler(mi) && return true
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
  its own result is concrete — the "internal dispatch with a concrete return" blind spot, or
- a `Core._apply_iterate` left in the body: a splat over a collection of unknown length
  (`max(v...)`), whose callee is looked up at run time whatever its result infers as.

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
    _sync_exemptions!()   # the memo key cannot see a change to `exempt_strict()`
    sig = _entry_key(f, types)
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
    push!(seen, (sig, mode, false))
    alloc, boxing, dictlookup, abscontainer, barrier, unionphi, exempt, barrier_dict, barrier_box, truncated =
        isnothing(topci) ? (false, false, false, nothing, false, false, nothing, nothing, nothing, false) :
        _scan_ci(topci, sig, depth, seen, mode, true)
    m = try
        _which(f, types)
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

# When something was read from a signature: the world, the specialization the signature dispatched
# to, and the compiler's record of that specialization (`_record_of`).
struct _ReadStamp
    world::UInt
    mi::Union{Nothing, Core.MethodInstance}
    record::Union{Nothing, Core.CodeInstance}
end

# Whether what was read from the body `key` (`_callee_key`) at `s` is what would be read now. It is
# in the world of the read. In a later world it is while both hold: the compiler's record is valid,
# which Julia ends when anything the inference of the specialization depended on changes (a callee,
# a binding); and `key` still names that specialization. The second is not implied by the first:
# Julia ends the records of the callers of a replaced method and leaves the replaced method's own
# record valid, and a more specific method added later takes over a signature without touching the
# record of the method that used to answer it.
function _read_holds(s::_ReadStamp, @nospecialize(key), world::UInt = Base.get_world_counter())
    s.world == world && return true
    r = s.record
    (!isnothing(r) && r.min_world <= world <= r.max_world) || return false
    return _key_instance(key, world) === s.mi
end

# `s` as of `world`, for a read found to hold there: the next question in that world is answered
# by the first comparison, without asking dispatch again.
_as_of(s::_ReadStamp, world::UInt) = s.world == world ? s : _ReadStamp(world, s.mi, s.record)

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
#
# Kept while the read it came from holds (`_read_holds`): the analysis reads the signature's own
# inferred body, so a redefinition changes the answer in either direction.
const _ESCAPE_MEMO = IdDict{Any, Tuple{_ReadStamp, Bool}}()
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

function _all_news_nonescaping(@nospecialize(key))
    world = Base.get_world_counter()
    cached = @lock _ESCAPE_MEMO_LOCK get(_ESCAPE_MEMO, key, nothing)
    if !isnothing(cached) && _read_holds(cached[1], key, world)
        cached[1].world == world ||
            @lock _ESCAPE_MEMO_LOCK (_ESCAPE_MEMO[key] = (_as_of(cached[1], world), cached[2]))
        return cached[2]
    end
    v = try
        _compute_all_news_nonescaping(key)
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
    mi = _key_instance(key, world)
    stamp = _ReadStamp(world, mi, isnothing(mi) ? nothing : _record_of(mi, world))
    @lock _ESCAPE_MEMO_LOCK (_ESCAPE_MEMO[key] = (stamp, v))
    return v
end

function _compute_all_news_nonescaping(@nospecialize(key))
    EA = Core.Compiler.EscapeAnalysis
    irs = _code_ircode_of(key)
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

A throw that a catch handles is not an error path when the catch can return: every statement in the try
body has the handler as a successor, so the message it builds and the exception it boxes count, and so
does the handler. A throw raised inside a callee the try body calls counts too: the callee, and
everything it calls, is read with no statement skipped as an error path.

A handler that begins `err isa T || rethrow()` returns only for a `T`: a throw whose exception type is
known, concrete and not a `T` ends in that rethrow, so the path to it is an error path, in the try body
and in the callees below it.
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
# leads only to a throw or to an unreachable terminator. No per-statement storage outside a `try`: a
# body is a few thousand statements and this runs for every body a walk reads.
#
# A throw that a catch handles is not an error path: every statement in a try region also has the
# region's handler as a successor, so it is alive when the handler can return. A handler that
# returns only for a type `T` (`_handler_filter`) is a successor only of the statements that may
# throw something other than an exception known to be no `T` (`_rethrown`).
#
# `caught` is the context the body runs in (`_join_caught`): with a type `T`, a statement that may
# throw, or the `unreachable` after a throw, is alive unless what it throws is known to be no `T`.
# `ci` and `sig` give the statement types and flags those tests read; without them every handler
# is taken to return whatever is thrown.
function _deadend_mask(code::Vector{Any}, ci = nothing, @nospecialize(sig) = nothing, caught = false)
    n = length(code)
    iszero(n) && return falses(0)
    alive = falses(n)
    handlers = _try_handlers(code)
    filters = isnothing(handlers) || isnothing(ci) ? nothing : Dict{Int, Any}()
    filter_of(d) = isnothing(filters) ? nothing : get!(() -> _handler_filter(code, d), filters, d)
    thrown = Dict{Int, Union{Nothing, Vector{Any}}}()
    # Held in a `RefValue{Any}`: a closure capturing `sig` itself is a new type for every signature,
    # and each one compiles its own `any` below.
    sigref = Base.RefValue{Any}(sig)
    rethrown(i, T) = !isnothing(ci) && _rethrown(ci, sigref[], i, T, thrown)
    via(i, d) = (T = filter_of(d); isnothing(T) || (_maythrow(ci, i) && !rethrown(i, T)))
    changed = true
    while changed
        changed = false
        for i in n:-1:1
            alive[i] && continue
            st = code[i]
            up = if !isnothing(handlers) && any(d -> alive[d] && via(i, d), handlers[i])
                true
            elseif caught isa Type && _maythrow(ci, i) && !rethrown(i, caught)
                true
            elseif st isa Core.ReturnNode
                isdefined(st, :val) || (caught isa Type && !(i > 1 && rethrown(i - 1, caught)))
            elseif st isa Core.GotoNode
                1 <= st.label <= n && alive[st.label]
            elseif st isa Core.GotoIfNot
                (1 <= st.dest <= n && alive[st.dest]) || (i < n && alive[i + 1])
            elseif Meta.isexpr(st, :gotoifnot)
                t = st.args[2]
                (t isa Integer && 1 <= t <= n && alive[t]) || (i < n && alive[i + 1])
            elseif st isa Core.EnterNode
                # A throw in the try body continues at the handler, so a catch that returns keeps
                # everything before the `try` live.
                d = st.catch_dest
                (1 <= d <= n && alive[d]) || (i < n && alive[i + 1])
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

# For each statement, the handlers (`catch_dest`s) of the try regions it lies in, or `nothing` for a
# body with no `try`. A region is what the body of an `EnterNode` reaches before the `:leave` that
# names it, a nested handler included, since a throw there still lands in the outer one. A
# `ReturnNode` is left out: a `return` cannot throw, and an `unreachable` never executes.
function _try_handlers(code::Vector{Any})
    n = length(code)
    handlers = nothing
    for e in 1:n
        st = code[e]
        (st isa Core.EnterNode && 1 <= st.catch_dest <= n) || continue
        isnothing(handlers) && (handlers = [Int[] for _ in 1:n])
        seen = falses(n)
        work = [e + 1]
        while !isempty(work)
            i = pop!(work)
            (1 <= i <= n && !seen[i]) || continue
            seen[i] = true
            s = code[i]
            Meta.isexpr(s, :leave) && any(==(Core.SSAValue(e)), s.args) && continue
            s isa Core.ReturnNode && continue
            push!(handlers[i], st.catch_dest)
            if s isa Core.GotoNode
                push!(work, s.label)
            elseif s isa Core.GotoIfNot
                push!(work, s.dest, i + 1)
            elseif Meta.isexpr(s, :gotoifnot)
                t = s.args[2]
                t isa Integer && push!(work, t)
                push!(work, i + 1)
            elseif s isa Core.EnterNode
                1 <= s.catch_dest <= n && push!(work, s.catch_dest)
                push!(work, i + 1)
            else
                push!(work, i + 1)
            end
        end
    end
    return handlers
end

# Is statement `c` the call `x === x`, one value compared with itself? Egal is reflexive, so it is
# true whatever `x` holds. Only an SSA value or an argument counts as "the same value": two
# separate arguments may or may not be the same object, and that is not known without values.
function _reflexive_egal(code::Vector{Any}, @nospecialize(c))
    c isa Core.SSAValue && 1 <= c.id <= length(code) || return false
    st = code[c.id]
    Meta.isexpr(st, :call) && length(st.args) == 3 || return false
    _static_callee(nothing, st.args[1]) === (===) || return false
    a, b = st.args[2], st.args[3]
    return (a isa Core.SSAValue || a isa Core.Argument) && a == b
end

# Statements no execution reaches from the entry, reading a `goto … if not` whose condition is
# `x === x` as never jumping. Inlining a callee that takes the same value twice leaves exactly that
# guard: a triangular `ldiv!(U, b)` forwards to `_ldiv!(b, U, b)` and inlines to
# `b === b ? b : copyto!(b, b)`, and the copy, whose unaliasing allocates, never runs. The optimizer keeps the comparison and LLVM folds it, so AllocCheck sees
# no copy; without this the scan counts code that cannot execute. Every other branch keeps both
# successors, so the mask only removes a path that egal's reflexivity rules out.
function _unreachable_mask(code::Vector{Any})
    n = length(code)
    reached = falses(n)
    work = [1]
    while !isempty(work)
        i = pop!(work)
        (1 <= i <= n && !reached[i]) || continue
        reached[i] = true
        st = code[i]
        if st isa Core.ReturnNode
            continue
        elseif st isa Core.GotoNode
            push!(work, st.label)
        elseif st isa Core.GotoIfNot
            _reflexive_egal(code, st.cond) || push!(work, st.dest)
            push!(work, i + 1)
        elseif Meta.isexpr(st, :gotoifnot)
            t = st.args[2]
            t isa Integer && push!(work, t)
            push!(work, i + 1)
        elseif st isa Core.EnterNode
            # The catch destination is reached by a throw from anywhere in the try body.
            iszero(st.catch_dest) || push!(work, st.catch_dest)
            push!(work, i + 1)
        else
            push!(work, i + 1)
        end
    end
    return map(!, reached)
end

# The statements a scan of one body skips: those no execution reaches, and, under `ignore_throw()`,
# those from which no path returns normally. A body scanned in a caught context (`caught`) is called
# from a try region whose handler can return, so a throw anywhere in it ends in that handler and no
# statement of it is an error path.
_skip_mask(code::Vector{Any}, caught = false, ci = nothing, @nospecialize(sig) = nothing) =
    ignore_throw() && caught !== true ? _deadend_mask(code, ci, sig, caught) .| _unreachable_mask(code) :
    _unreachable_mask(code)

# The statements of a try region whose handler is not an error path (`dead`): a call there whose
# callee throws continues at a handler that can return, so the callee is scanned in a caught context.
# `nothing` for a body with no such region.
function _caught_region_mask(code::Vector{Any}, dead::BitVector)
    ctx = _caught_contexts(code, dead)
    isnothing(ctx) && return nothing
    return BitVector(c !== false for c in ctx)
end

# The caught context of each statement's callees (`_join_caught`): `false` outside a try region whose
# handler can return, else what its handlers return for. `nothing` for a body with no such region.
# Without `ci`, every handler is taken to return whatever is thrown.
function _caught_contexts(code::Vector{Any}, dead::BitVector, ci = nothing)
    handlers = _try_handlers(code)
    isnothing(handlers) && return nothing
    filters = Dict{Int, Any}()
    ctx = Any[false for _ in eachindex(code)]
    for i in eachindex(code), d in handlers[i]
        dead[d] && continue
        T = isnothing(ci) ? nothing : get!(() -> _handler_filter(code, d), filters, d)
        ctx[i] = _join_caught(ctx[i], isnothing(T) ? true : T)
    end
    return any(c -> c !== false, ctx) ? ctx : nothing
end

# A caught context says what happens to an exception a body throws: `false`, nothing catches it, so
# under `ignore_throw()` its path is an error path; `true`, a handler that can return catches
# anything; a type `T`, a handler returns for a `T` and rethrows anything else (`_handler_filter`), so
# the path to a throw known to be no `T` is still an error path. Two contexts join to what either
# returns for.
_join_caught(a, b) = (a === true || b === true) ? true : a === false ? b : b === false ? a : Union{a, b}

# Whether a throw of an `E` in the caught context `ctx` (`_join_caught`) continues at a handler that
# returns normally.
_returns_for(ctx, @nospecialize(E)) = ctx === true || (ctx isa Type && E <: ctx)

# Whether `st` is `memoryrefnew(ref, i)` or `memoryrefnew(ref, i, boundscheck)` on a memory reference,
# an `Int` and a `Bool`. The compiler proves such a call cannot throw except by its bounds check
# (`memoryref_builtin_common_nothrow`), and the check throws a `BoundsError`. On Julia 1.12 under
# `--check-bounds=yes`, codegen emits the check even when `boundscheck` is `false`.
function _bounds_checked_ref(ci, @nospecialize(sig), @nospecialize(st))
    (Meta.isexpr(st, :call) && 3 <= length(st.args) <= 4 && _static_callee(ci, st.args[1]) === Core.memoryrefnew) ||
        return false
    t(k) = _unwrap_lattice(_stmt_arg_type(ci, sig, st.args[k]))
    r, i = t(2), t(3)
    (r isa Type && r <: Core.GenericMemoryRef && i isa Type && i <: Int) || return false
    length(st.args) == 3 && return true
    b = t(4)
    return b isa Type && b <: Bool
end

# The exception type the handler at `d` returns for, when it begins `catch err; err isa T || rethrow()`:
# its first test is `isa` of the caught exception against a constant type, and the branch where the
# test fails only rethrows. `nothing` for any other handler, which is taken to return whatever is
# thrown.
function _handler_filter(code::Vector{Any}, d::Int)
    n = length(code)
    i = _skip_nothing(code, d)
    (i <= n && Meta.isexpr(code[i], :the_exception)) || return nothing
    e = Core.SSAValue(i)
    i = _skip_nothing(code, i + 1)
    i < n || return nothing
    st = code[i]
    (Meta.isexpr(st, :call) && length(st.args) == 3 && _static_callee(nothing, st.args[1]) === Core.isa &&
        st.args[2] == e) || return nothing
    a = st.args[3]
    T = a isa Type ? a : _static_callee(nothing, a)
    T isa Type || return nothing
    br = code[i + 1]
    (br isa Core.GotoIfNot && br.cond == Core.SSAValue(i)) || return nothing
    return _only_rethrows(code, br.dest, e) ? T : nothing
end

function _skip_nothing(code::Vector{Any}, i::Int)
    while i <= length(code) && code[i] === nothing
        i += 1
    end
    return i
end

# Whether the statements from `j` rethrow the caught exception `e` and stop: `rethrow()` or
# `throw(e)`, then `unreachable`.
function _only_rethrows(code::Vector{Any}, j::Int, e::Core.SSAValue)
    j = _skip_nothing(code, j)
    j < length(code) || return false
    st = code[j]
    ok = if Meta.isexpr(st, :invoke)
        mi = _invoke_mi(st.args[1])
        !isnothing(mi) && mi.def isa Method && mi.def.name === :rethrow && mi.def.module === Base &&
            length(st.args) == 2
    elseif Meta.isexpr(st, :call)
        c = _static_callee(nothing, st.args[1])
        (c === Core.throw && length(st.args) == 2 && st.args[2] == e) || (c === Base.rethrow && length(st.args) == 1)
    else
        false
    end
    ok || return false
    r = code[_skip_nothing(code, j + 1)]
    return r isa Core.ReturnNode && !isdefined(r, :val)
end

# Whether statement `i` may throw: the optimizer did not prove it cannot. Without the flags, it may.
const _IR_FLAG_NOTHROW = Base.Compiler.IR_FLAG_NOTHROW
_maythrow(ci, i::Int) = isnothing(ci) || iszero(ci.ssaflags[i] & _IR_FLAG_NOTHROW)

# Whether statement `i` throws only exceptions known to be no `T`: each type it can throw is known
# (`_thrown_types`) and none is a `T`. `memo` keeps the thrown types by statement.
function _rethrown(ci, @nospecialize(sig), i::Int, @nospecialize(T), memo::Dict{Int, Union{Nothing, Vector{Any}}})
    ts = get!(() -> _thrown_types(ci, sig, i), memo, i)
    return !isnothing(ts) && all(E -> !(E <: T), ts)
end

# The types the statement `i` can throw, when every one is known and concrete: `throw(x)` with `x` of a
# concrete type, a bounds-checked `memoryrefnew` (`_bounds_checked_ref`), which throws only a
# `BoundsError`, or a call that always throws into a body whose every throw is one (a few levels
# deep, as `throw_boundserror` is one). `nothing` otherwise.
function _thrown_types(ci, @nospecialize(sig), i::Int, level::Int = 0)
    st = ci.code[i]
    _bounds_checked_ref(ci, sig, st) && return Any[BoundsError]
    if Meta.isexpr(st, :call) && length(st.args) == 2 && _static_callee(ci, st.args[1]) === Core.throw
        E = _unwrap_lattice(_stmt_arg_type(ci, sig, st.args[2]))
        return E isa DataType && isconcretetype(E) ? Any[E] : nothing
    elseif Meta.isexpr(st, :invoke) && ci.ssavaluetypes[i] === Union{} && level < 4
        mi = _invoke_mi(st.args[1])
        isnothing(mi) && return nothing
        body = _typed_body(_callee_key(mi))
        isnothing(body) && return nothing
        out = Any[]
        for j in eachindex(body.code)
            r = body.code[j]
            r isa Core.ReturnNode || continue
            isdefined(r, :val) && return nothing
            j > 1 || return nothing
            ts = _thrown_types(body, mi.specTypes, j - 1, level + 1)
            isnothing(ts) && return nothing
            append!(out, ts)
        end
        return isempty(out) ? nothing : out
    end
    return nothing
end

# Session memo for the per-signature scan: the callee recursion re-visits shared helpers (Base
# internals especially) from every caller, and each visit pays a `code_typed_by_type`. Without
# this, `:fast`'s median went 2.9 ms → 73 ms on the corpus study. Invalidated with the findings
# cache (`clear_cache!` / the Revise extension) — same staleness contract.
#
# Identity-keyed on the signature type: concrete signature DataTypes are interned by the runtime
# (structurally equal ⇒ ===), and `hash(::DataType)` walks the whole type — on deeply-nested
# kernel signatures that hashing alone cost more than the scan (profiled: ~half the runtime).
const _SIGNAL_MEMO = IdDict{Any, Dict{Tuple{Int, UInt64, Symbol, Any}, Tuple{Bool, Bool, Bool, Any, Bool, Bool, Union{Nothing, Symbol}, Union{Nothing, Symbol}, Union{Nothing, Symbol}, Bool}}}()
const _SIGNAL_MEMO_LOCK = ReentrantLock()

# A body already on this walk contributes nothing a second time, so a result computed below such a
# cut is the walk's, not the body's own: it omits what the cut body reaches. Memoizing it would hand
# a later walk, which reaches the body by another route, a verdict with that part missing. The scan
# therefore counts its cuts, and only a body whose subtree met none is memoized.
_cut_counter() = get!(() -> Ref(0), task_local_storage(), :strictmode_scan_cuts)::Base.RefValue{Int}

# A body is scanned once per context and mode: what it allocates on its throw paths counts only in a
# caught context (`_skip_mask`), and a body below an exempt callee is also read for boxing alone, so
# the walk records and memoizes each separately.
function _signals_by_type(@nospecialize(sig), depth::Int, seen::Base.IdSet{Any}, mode::Symbol = :full, caught = false)
    visit = (sig, mode, caught)
    if visit in seen
        _cut_counter()[] += 1
        return (false, false, false, nothing, false, false, nothing, nothing, nothing, false)
    end
    push!(seen, visit)
    key = (depth, Base.get_world_counter(), mode, caught)   # any new method definition invalidates (coarse, safe)
    memo = @lock _SIGNAL_MEMO_LOCK begin
        bysig = get(_SIGNAL_MEMO, sig, nothing)
        bysig === nothing ? nothing : get(bysig, key, nothing)
    end
    memo === nothing || return memo
    cuts = _cut_counter()
    before = cuts[]
    r = _signals_by_type_uncached(sig, depth, seen, mode, caught)
    cuts[] == before || return r
    @lock _SIGNAL_MEMO_LOCK get!(Dict{Tuple{Int, UInt64, Symbol, Any}, Tuple{Bool, Bool, Bool, Any, Bool, Bool, Union{Nothing, Symbol}, Union{Nothing, Symbol}, Union{Nothing, Symbol}, Bool}}, _SIGNAL_MEMO, sig)[key] = r
    return r
end

# The optimized body `key` names (`_callee_key`), or `nothing` when none can be read. Inferring a
# body is most of what a scan costs, and the same body is reached again by every walk that passes
# through it, at each depth and from every entry point, so it is read once. An entry stays valid
# while what it was read from does (`_read_holds`; a method defined elsewhere does not end it).
#
# A body is taken from where it already exists, and inferred only when it exists nowhere: the
# compiler's own record first, then what the scan's inference kept while it inferred a caller.
const _BODY_MEMO = IdDict{Any, Tuple{_ReadStamp, Any}}()

function _typed_body(@nospecialize(key))
    world = Base.get_world_counter()
    hit = @lock _SIGNAL_MEMO_LOCK get(_BODY_MEMO, key, nothing)
    if !isnothing(hit) && _read_holds(hit[1], key, world)
        hit[1].world == world ||
            @lock _SIGNAL_MEMO_LOCK (_BODY_MEMO[key] = (_as_of(hit[1], world), hit[2]))
        return hit[2]
    end
    mi = _key_instance(key, world)
    ci = isnothing(mi) ? nothing : _compiled_body(mi, world)
    isnothing(ci) && !isnothing(mi) && (ci = _scan_source(mi, world))
    isnothing(ci) && !isnothing(mi) && (ci = _infer_body(mi, world))
    if isnothing(ci)
        cts = try
            _code_typed_of(key; optimize = true)
        catch
            Any[]
        end
        ci = isempty(cts) ? nothing : first(cts[1])
    end
    # A compiled body keeps no record of what was inlined into each statement, and a scheduler body that
    # runs a callable it was handed needs one to tell that callable's statements from its own
    # (`_stmt_in_scheduler`), so it is read again with them.
    if !isnothing(ci) && !_has_inlining_info(ci) && _runs_handed_callable(key)
        src = try
            _code_typed_of(key; optimize = true, debuginfo = :source)
        catch
            Any[]
        end
        isempty(src) || (ci = first(src[1]))
    end
    rec = (isnothing(ci) || isnothing(mi)) ? nothing : _record_of(mi, world)
    @lock _SIGNAL_MEMO_LOCK (_BODY_MEMO[key] = (_ReadStamp(world, mi, rec), ci))
    return ci
end

# Infers a specialization the way inference reaches a callee, so the result is cached for the walks
# and the return-type questions that follow, and returns the optimized body the compiler handed over:
# `nothing` when it kept none, as for a result that folds to a constant.
#
# The compiler is entered the way `Base.return_types` enters it, through a call it cannot resolve
# statically. A direct call to `typeinf_type` puts the whole of inference in the static call graph
# of every `@strict` guard, and a proof of a guarded function then compiles all of it: AllocCheck
# took 5 minutes on one guarded signature, against seconds.
function _infer_body(mi::Core.MethodInstance, world::UInt)
    _infer_for_image(mi, world)
    n = _window_open()
    interp = _ScanInterpreter(world)
    try
        Base.invoke_interp_compiler(interp, :typeinf_type, interp, mi)
    catch
        return nothing
    finally
        _keep_sources(interp)
        _window_close(n)
    end
    return _scan_source(mi, world)
end

# The one specialization a signature dispatches to in `world`, or `nothing` when there is not exactly one.
function _sig_instance(@nospecialize(sig), world::UInt)
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
    return mi isa Core.MethodInstance ? mi : nothing
end

# --- which body a call runs ----------------------------------------------------------------------
#
# A walk of the call graph names each body by a KEY, and a key names exactly one specialization:
#
#   - a signature type names the specialization that signature dispatches to. An entry point is one:
#     a call `f(args...)` dispatches.
#   - a `MethodInstance` names itself. A callee is named this way when its own signature dispatches
#     to another specialization. `invoke(f, Tuple{wider}, args...)` runs such a callee: a more
#     specific method answers the signature of the method it selects, and a read by signature
#     would be of that other method.
#
# The invariant: a walk never dispatches the signature of a callee it found in a body. It takes the
# callee's key from `_callee_key`, reads through the key (`_typed_body`, `_code_typed_of`,
# `_code_ircode_of`, `_key_method`), keeps its memo entries and visited sets under the key, and
# asks `_key_sig` only for the argument types. A callee is then read as the code the call runs,
# whichever method its signature would select.

# The key of the callee `mi` an `:invoke` statement or an inlining edge names: its signature where
# that dispatches to `mi`, so that a callee and an entry point of the same signature share their
# reads, and `mi` itself otherwise.
#
# The read of the signature's body records what the signature dispatches to in this world, so the
# question costs no second method lookup.
function _callee_key(mi::Core.MethodInstance)
    sig = mi.specTypes
    _typed_body(sig)
    hit = @lock _SIGNAL_MEMO_LOCK get(_BODY_MEMO, sig, nothing)
    return (!isnothing(hit) && hit[1].mi === mi) ? sig : mi
end

# The signature of the specialization `key` names: the types of its arguments.
_key_sig(@nospecialize(key)) = key isa Core.MethodInstance ? key.specTypes : key

# The specialization `key` names in `world`, or `nothing` for a signature that dispatches to no
# single one.
_key_instance(@nospecialize(key), world::UInt) =
    key isa Core.MethodInstance ? key : _sig_instance(key, world)

# The method `key` names, or `nothing` for a signature that dispatches to no single one.
function _key_method(@nospecialize(key))
    key isa Core.MethodInstance && return key.def isa Method ? key.def : nothing
    m = try
        Base._which(key; raise = false)
    catch
        nothing
    end
    return isnothing(m) ? nothing : m.method
end

# The compiler's record of a specialization in `world`: the cached `CodeInstance` that says in which
# worlds its inference holds.
function _record_of(mi::Core.MethodInstance, world::UInt)
    ci = isdefined(mi, :cache) ? mi.cache : nothing
    while ci isa Core.CodeInstance
        (isnothing(ci.owner) && ci.min_world <= world <= ci.max_world) && return ci
        ci = isdefined(ci, :next) ? ci.next : nothing
    end
    return nothing
end

# The optimized body the compiler holds uncompressed with its record of a specialization. A body it
# holds compressed is not read: it is the body that was compiled when the record was made, which a
# later inference of the same signature need not reproduce (it can inline a callee whose body was
# not yet known then), so reading it would change what the scan reports once a call has run.
function _compiled_body(mi::Core.MethodInstance, world::UInt)
    ci = isdefined(mi, :cache) ? mi.cache : nothing
    while ci isa Core.CodeInstance
        if isnothing(ci.owner) && ci.min_world <= world <= ci.max_world && isdefined(ci, :inferred)
            src = @atomic :monotonic ci.inferred
            src isa Core.CodeInfo && return src
        end
        ci = isdefined(ci, :next) ? ci.next : nothing
    end
    return nothing
end

# What a walk of the call graph reads below the callee `mi`. Every walk that decides or explains an
# allocation verdict asks here (`_scan_ci`, `_signal_origin`, `_nonscheduler_origin`), so they excuse
# the same code:
#
#   - `:barrier`: an allocation barrier (`_mi_is_barrier`). Nothing below it is the caller's.
#   - `:exempt`: a callee exempt from `:noalloc` whose handed-in code was read in full
#     (`_handed_code`). Only `handed`, the code its caller handed it and that it calls, is the
#     caller's. `:boxing`, which `:noboxing` reads, knows no exemption.
#   - `:own`: the callee is the caller's code. An exempt callee whose handed-in code could not be
#     read in full is of this kind, so it excuses nothing; `handed` is what was found of it.
#
# The invariant: a body counts toward a caller's verdict exactly when the caller reaches it along
# some path that enters no `:barrier` or `:exempt` callee, in whatever order the walk meets the
# paths. A walk therefore never marks a body as visited on the strength of a read made below an
# excused callee (`_excused_signals`).
const _NO_HANDED = Any[]
function _callee_excusal(mi::Core.MethodInstance, mode::Symbol)
    _mi_is_barrier(mi) && return (; kind = :barrier, handed = _NO_HANDED, name = nothing)
    name = mode === :boxing ? nothing : _mi_exempt_name(mi)
    isnothing(name) && return (; kind = :own, handed = _NO_HANDED, name)
    handed, whole = _handed_code(_callee_key(mi))
    return (; kind = whole ? :exempt : :own, handed, name)
end

# The signals of an excused callee's subtree, read for what is reported about it (the exemption or
# barrier a caller is pointed to) and for the guarantees the excusal does not cover. It marks a
# copy of `seen`: the caller's walk reads every body below the callee again if it reaches that body
# another way. This is the only place a walk reads below an excused callee.
_excused_signals(mi::Core.MethodInstance, depth::Int, seen::Base.IdSet{Any}, mode::Symbol, caught) =
    _signals_by_type(_callee_key(mi), depth, copy(seen), mode, caught)

# Where the scan finds what it reports: for every body of the call graph whose own statements set the
# signal `mode` asks about, the callees that lead to it and the statements. `_alloc_signals` says that
# something allocates; this says which statement, in which callee, reached from where.
function _signal_origin(
        @nospecialize(f), @nospecialize(types::Tuple); mode::Symbol = :alloc,
        stops::Union{Nothing, Vector{Any}} = nothing, first_only::Bool = false
    )
    top = _entry_key(f, types)
    parent = IdDict{Any, Any}()
    queue = Any[(top, _FAST_ALLOC_DEPTH[], false, mode)]
    seen = Base.IdSet{Any}()
    out = Any[]
    while !isempty(queue) && length(seen) < _SCAN_BODY_BUDGET[]
        s, depth, caught, m = popfirst!(queue)
        (s, caught, m) in seen && continue
        push!(seen, (s, caught, m))
        trace, callees = _origin_node(s, m, caught)
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
        for (mi, c) in callees
            mi = mi::Core.MethodInstance
            ex = _callee_excusal(mi, m)
            if ex.kind === :barrier
                isnothing(stops) || push!(stops, mi.specTypes)
                continue
            end
            # The scan's own rule: the package's code to the end, Base to `depth` levels.
            user = _followed_to_end(mi)
            (depth > 0 || (depth < 0 && user)) || continue
            sub = user ? depth : (depth > 1 ? depth - 1 : -1)
            k = _callee_key(mi)
            haskey(parent, k) || (parent[k] = s)
            for h in ex.handed
                haskey(parent, h) || (parent[h] = k)
                push!(queue, (h, sub, c, m))
            end
            ex.kind === :exempt || push!(queue, (k, sub, c, m))
        end
    end
    return out
end

# One body of the walk above: the statements of its own that set `mode`'s signal, and the callees it
# invokes off its throw paths, each with whether it is called in a caught context (`_skip_mask`) and
# the statement that calls it.
# Every warning walks the call graph below its call, and the calls of one package share most of that
# graph, so a body is scanned once per world and context and not once per warning.
# Emptied with the other scan memos.
const _ORIGIN_MEMO = IdDict{Any, Dict{Tuple{Symbol, Any}, Tuple{UInt, Vector{Any}, Vector{Any}}}}()

function _origin_node(@nospecialize(s), mode::Symbol, caught = false)
    world = Base.get_world_counter()
    hit = @lock _SIGNAL_MEMO_LOCK begin
        bymode = get(_ORIGIN_MEMO, s, nothing)
        isnothing(bymode) ? nothing : get(bymode, (mode, caught), nothing)
    end
    (!isnothing(hit) && hit[1] == world) && return hit[2], hit[3]
    trace = Any[]
    callees = Any[]
    ci = _typed_body(s)
    if !isnothing(ci)
        # `push!` and not `IdSet{Any}([s])`: a vector literal of a type is a method compiled for that type.
        own = Base.IdSet{Any}()
        push!(own, s)
        _scan_ci(ci, s, 0, own, mode, false, trace; caught)
        dead = _skip_mask(ci.code, caught, ci, _key_sig(s))
        region = caught === true || !ignore_throw() ? nothing : _caught_contexts(ci.code, dead, ci)
        for (j, st) in enumerate(ci.code)
            (Meta.isexpr(st, :invoke) && !dead[j]) || continue
            a1 = st.args[1]
            mi = a1 isa Core.CodeInstance ? a1.def : a1
            (mi isa Core.MethodInstance && mi.def isa Method) || continue
            _mi_is_strictmode(mi) && continue
            push!(callees, (mi, isnothing(region) ? caught : _join_caught(caught, region[j]), j))
        end
    end
    @lock _SIGNAL_MEMO_LOCK begin
        get!(Dict{Tuple{Symbol, Any}, Tuple{UInt, Vector{Any}, Vector{Any}}}, _ORIGIN_MEMO, s)[(mode, caught)] = (world, trace, callees)
    end
    return trace, callees
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
    # A wait is the nearest only because the walk meets it first: when the call also allocates
    # outside the scheduler, that allocation is the one to name.
    if _origin_in_scheduler(x)
        y = try
            _nonscheduler_origin(f, types)
        catch
            nothing
        end
        (isnothing(y) || ismissing(y)) || (x = y)
    end
    st = first(x.statements)
    via = join((first(string(_key_sig(p)), 70) for p in last(x.path, 3)), " -> ")
    return "; first at " * first(string(_key_sig(x.signature)), 110) * " [" * first(string(st[2]), 90) * "]" *
        (isempty(via) ? "" : ", reached through " * via)
end

# Whether the body `key` names (`_callee_key`) is Base's task, lock or condition code.
function _sig_in_scheduler(@nospecialize(key))
    m = _key_method(key)
    return !isnothing(m) && _method_in_scheduler(m)
end

# Whether an origin `_signal_origin` found is the scheduler's: in its code, or in Base code its code
# reached. A callable the scheduler was handed (the function given to `lock`) is its caller's code
# whoever defined its type, and so is everything below it, inlined into the scheduler call or not;
# a wait that callable makes is the scheduler's again.
function _origin_in_scheduler(o)
    chain = Any[o.path..., o.signature]
    k = findlast(_sig_in_scheduler, chain)
    isnothing(k) && return false
    if k < length(chain)
        _calls_argument(chain[k], chain[k + 1]) && return false
        return !any(_sig_runs_user_code, @view chain[(k + 1):end])
    end
    ci = _typed_body(chain[k])
    isnothing(ci) && return false
    unsplit = _unsplit(ci, chain[k])
    return all(st -> _stmt_in_scheduler(ci, chain[k], st[1], true, unsplit), o.statements)
end

function _sig_runs_user_code(@nospecialize(key))
    m = _key_method(key)
    isnothing(m) && return true
    root = Base.moduleroot(m.module)
    return !(root === Base || root === Core) || _carries_user_type(_key_sig(key))
end

# The nearest allocation or boxing the call reaches outside Base's task, lock and condition code:
# `nothing` when there is none, `missing` when the walk could not finish (a body it could not read,
# or more than `_SCAN_BODY_BUDGET` bodies).
#
# Base is followed to the end here, not to the scan's depth. The scan's verdict needs only one
# allocation and stops at the first; the claim that a call does nothing but wait is about all of
# them, and an allocation three Base calls down (`copyto!` to `unalias` to `unaliascopy`) is past
# the depth the verdict reads to. What the scheduler's own code calls is the scheduler's, except a
# callable it was handed (`_calls_argument`): a scheduler body is read for that code alone, and its
# callees only when they are that callable or are called from it inlined, since following the rest
# reads the whole scheduler.
function _nonscheduler_origin(@nospecialize(f), @nospecialize(types::Tuple))
    parent = IdDict{Any, Any}()
    queue = Any[(_entry_key(f, types), false, false)]
    seen = Base.IdSet{Any}()
    while !isempty(queue)
        s, caught, sched = popfirst!(queue)
        (s, caught, sched) in seen && continue
        length(seen) < _SCAN_BODY_BUDGET[] || return missing
        push!(seen, (s, caught, sched))
        ci = _typed_body(s)
        isnothing(ci) && return missing
        trace, callees = _origin_node(s, :alloc, caught)
        unsplit = sched && _unsplit(ci, s)
        sched && (trace = filter(st -> !_stmt_in_scheduler(ci, s, st[1], true, unsplit), trace))
        if !isempty(trace)
            path = Any[]
            c = s
            while haskey(parent, c)
                c = parent[c]
                pushfirst!(path, c)
            end
            return (; signature = s, path, statements = trace)
        end
        for (mi, c, j) in callees
            mi = mi::Core.MethodInstance
            ex = _callee_excusal(mi, :alloc)
            ex.kind === :barrier && continue
            arg = sched && (_calls_argument(s, mi.specTypes) || !_stmt_in_scheduler(ci, s, j::Int, true, unsplit))
            (sched && !arg) && continue
            k = _callee_key(mi)
            haskey(parent, k) || (parent[k] = s)
            for h in ex.handed
                haskey(parent, h) || (parent[h] = k)
                push!(queue, (h, c, false))
            end
            ex.kind === :exempt || push!(queue, (k, c, !arg && _in_scheduler(mi)))
        end
    end
    return nothing
end

# `nothing` unless every allocation or boxing the call can reach is in the task scheduler, in which
# case the nearest one: the finding is then that the call can block, not that it allocates. What the
# user can do about it differs, so it is reported as its own kind. Every place the scan finds one
# must be in the scheduler, and the walk outside the scheduler must end having found none.
function _scheduler_origin(@nospecialize(f), @nospecialize(types::Tuple))
    origins = _signal_origin(f, types; mode = :alloc)
    isempty(origins) && return nothing
    all(_origin_in_scheduler, origins) || return nothing
    isnothing(_nonscheduler_origin(f, types)) || return nothing
    o = first(origins)
    via = join((first(string(_key_sig(p)), 70) for p in last(o.path, 3)), " -> ")
    return (; call = first(string(_key_sig(o.signature)), 100), statement = first(string(o.statements[1][2]), 80), via)
end

# The registered barriers the walk from `f` stops at, so a reader can see that one was reached and not
# entered.
function _barrier_stops(@nospecialize(f), @nospecialize(types::Tuple))
    stops = Any[]
    _signal_origin(f, types; stops)
    return unique(stops)
end

function _signals_by_type_uncached(@nospecialize(sig), depth::Int, seen::Base.IdSet{Any}, mode::Symbol, caught)
    ci = _typed_body(sig)
    isnothing(ci) && return (false, false, false, nothing, false, false, nothing, nothing, nothing, true)
    return _scan_ci(ci, sig, depth, seen, mode; caught)
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

# --- a value boxed to be stored ------------------------------------------------------------------
#
# An isbits value lives in a register, on the stack or inline in its container. Written to a slot that
# holds a reference (a field or an array element of abstract type, an `Any` argument of a `ccall`),
# it is heap-allocated first: a box, with no dispatch anywhere near it. AllocCheck lists that box as
# an allocation of the value's type, and the proof tier counts an allocation of an isbits type as
# boxing, so these rules name the same event from the store's side.

# `Bool` boxes to one of two constants and an 8-bit integer to an entry of a table: no allocation.
const _PREBOXED = (Bool, UInt8, Int8)

# Is `v` heap-allocated when it is written to a slot that holds a reference? Not when it is a literal
# or a compile-time constant, whose box exists before the code runs; not when its type is not isbits,
# a singleton, or one of `_PREBOXED`; and not when it is already a reference that a `PiNode` or a
# `typeassert` narrowed to an isbits type, since the store then writes that reference.
function _boxed_on_store(ci, @nospecialize(sig), @nospecialize(v))
    for _ in 1:8
        (v isa Core.SSAValue || v isa Core.Argument) || return false
        T = _stmt_arg_type(ci, sig, v)
        T isa Core.Const && return false
        T = _unwrap_lattice(T)
        (T isa DataType && isbitstype(T) && !Base.issingletontype(T) && !(T in _PREBOXED)) || return false
        v isa Core.SSAValue || return true
        def = ci.code[v.id]
        if def isa Core.PiNode
            v = def.val
        elseif Meta.isexpr(def, :call) && _static_callee(ci, def.args[1]) === Core.typeassert
            v = def.args[2]
        else
            return true
        end
    end
    return true
end

# Does a slot declared `FT` hold a reference? One these rules cannot name is assumed to.
_reference_slot(@nospecialize(FT)) = !(FT isa Type && Base.allocatedinline(FT))

# Does this statement box a value in order to store it? Read for a `:new`, a `setfield!`, a
# `memoryrefset!`, a `setglobal!` and the `Any` arguments of a `:foreigncall` (`IdDict`'s `setindex!` is
# a `jl_eqtable_put`).
# ponytail: the swap, modify, replace and set-once forms of the store builtins are not read; add them
# to the positions below when a corpus shows one.
function _boxing_store(ci, @nospecialize(sig), st::Expr, @nospecialize(callee) = nothing)
    a = st.args
    if st.head === :new
        nt = _new_type(ci, st)
        nt isa DataType || return false
        for k in 2:min(length(a), fieldcount(nt) + 1)
            _reference_slot(fieldtype(nt, k - 1)) && _boxed_on_store(ci, sig, a[k]) && return true
        end
    elseif st.head === :foreigncall
        ats = a[3]
        ats isa Core.SimpleVector || return false
        for k in 1:min(length(ats), length(a) - 5)
            ats[k] === Any && _boxed_on_store(ci, sig, a[5 + k]) && return true
        end
    elseif st.head === :call
        if callee === Core.setfield! && length(a) >= 4
            return _reference_slot(_store_slot_type(ci, sig, callee, st, 4)) && _boxed_on_store(ci, sig, a[4])
        elseif callee === Core.memoryrefset! && length(a) >= 3
            return _reference_slot(_store_slot_type(ci, sig, callee, st, 3)) && _boxed_on_store(ci, sig, a[3])
        elseif callee === Core.setglobal! && length(a) >= 4
            m = a[2] isa GlobalRef ? _static_callee(ci, a[2]) : a[2]
            n = a[3] isa QuoteNode ? a[3].value : a[3]
            FT = (m isa Module && n isa Symbol) ? Core.get_binding_type(m, n) : nothing
            return _reference_slot(FT) && _boxed_on_store(ci, sig, a[4])
        end
    end
    return false
end

# Is statement `pc` of the body of `sig` the scheduler's: inlined from Base's task, lock or condition
# code (or in such a body, `frame`), with neither the package's code nor a callable the scheduler was
# handed (`_calls_argument`) inlined inside that? The proof tier asks the same of an allocation site's
# frames (`_scheduler_site`): boxing there is the scheduler's, not the caller's.
# `unsplit` (`_unsplit`) depends on the body alone, so a caller asking about many statements passes it.
function _stmt_in_scheduler(ci, @nospecialize(sig), pc::Int, frame::Bool = false, unsplit::Bool = frame && _unsplit(ci, sig))
    (frame && unsplit) && return false
    di = ci.debuginfo
    sched = frame
    encl = _key_sig(sig)
    for _ in 1:64
        di isa Core.DebugInfo || break
        t = try
            Core.Compiler.getdebugidx(di, pc)
        catch
            break
        end
        eidx = Int(t[2])
        (1 <= eidx <= length(di.edges)) || break
        e = di.edges[eidx]
        e isa Core.DebugInfo || break
        mi = e.def isa Core.MethodInstance ? e.def : nothing
        m = isnothing(mi) ? e.def : mi.def
        if sched && !isnothing(mi) && !isnothing(encl) && _calls_argument(encl, mi.specTypes)
            sched = false
        elseif m isa Method
            root = Base.moduleroot(m.module)
            sched = (root === Base || root === Core) && (sched || _method_in_scheduler(m))
        end
        encl = isnothing(mi) ? nothing : mi.specTypes
        di = e
        pc = Int(t[3])
    end
    return sched
end

# Whether a body records the calls inlined into its statements.
_has_inlining_info(ci) = ci.debuginfo isa Core.DebugInfo && !isempty(ci.debuginfo.edges)

# Whether a scheduler body may run a handed callable and does not record what was inlined: it cannot
# be split, and every statement is counted as the caller's.
_unsplit(ci, @nospecialize(sig)) = !_has_inlining_info(ci) && _runs_handed_callable(sig)

# Whether `sig` is a scheduler body handed a callable it may run: an argument whose type has a call
# method, as the function given to `lock(f, l)` has.
function _runs_handed_callable(@nospecialize(sig))
    _sig_in_scheduler(sig) || return false
    sig = Base.unwrap_unionall(_key_sig(sig))
    sig isa DataType || return false
    world = Base.get_world_counter()
    return any(_handed_params(sig)) do P
        P isa DataType && isconcretetype(P) || return false
        ms = Base._methods_by_ftype(Tuple{P, Vararg{Any}}, -1, world)
        return ms isa Vector && !isempty(ms)
    end
end

# Whether `callee` is a call of one of `caller`'s own arguments: the function given to `lock(f, l)`,
# which is its caller's code whoever defined its type. Only the function position counts, since the
# lock itself is an argument too and is handed on to the scheduler's own calls.
function _calls_argument(@nospecialize(caller), @nospecialize(callee))
    caller = Base.unwrap_unionall(_key_sig(caller))
    callee = Base.unwrap_unionall(_key_sig(callee))
    (caller isa DataType && callee isa DataType && !isempty(callee.parameters)) || return false
    F = callee.parameters[1]
    return any(P -> P === F, _handed_params(caller))
end

# The argument types of `sig` that a caller may have handed in, its function excluded. A keyword body
# `#f#N(kws..., ::typeof(f), args...)` is also passed `f` itself, the function it is the body of:
# that is its own code calling itself, not a callable it was given.
function _handed_params(sig::DataType)
    ps = Iterators.drop(sig.parameters, 1)
    F = sig.parameters[1]
    (F isa DataType && isdefined(F, :instance) && F.instance isa Function) || return ps
    nm = nameof(F.instance)
    owner = _demangle(nm)
    owner === nm && return ps
    return Iterators.filter(ps) do P
        !(P isa DataType && isdefined(P, :instance) && P.instance isa Function &&
          nameof(P.instance) === owner && parentmodule(P.instance) === parentmodule(F))
    end
end

# The callable types an argument of type `T` carries: a function, a closure, a callable struct (any
# number of call methods), or one of those held in a field or as an array's elements, at any depth.
# A type that is not concrete anywhere in that walk (an abstract argument, field or element type,
# `Any` included) is recorded as itself, since the values it may hold, and so the callables, cannot
# be listed from the type. A type argument (`Type{T}`, `DataType`) is not a callable here.
function _callable_types!(out::Vector{Any}, @nospecialize(T), seen::Base.IdSet{Any} = Base.IdSet{Any}())
    # A signature's `Vararg` tail carries its element type, and a type variable its upper bound.
    T isa Core.TypeofVararg && return _callable_types!(out, isdefined(T, :T) ? T.T : Any, seen)
    T isa TypeVar && return _callable_types!(out, T.ub, seen)
    (T isa Type && T !== Union{}) || return out
    if T isa Union
        for U in Base.uniontypes(T)
            _callable_types!(out, U, seen)
        end
        return out
    end
    T <: Type && return out
    T in seen && return out
    push!(seen, T)
    if !isconcretetype(T)
        push!(out, T)
        return out
    end
    if T <: Function
        push!(out, T)
    elseif T <: AbstractArray
        return _callable_types!(out, eltype(T), seen)
    elseif !(T <: Union{Number, AbstractString, Symbol})
        ms = Base._methods_by_ftype(Tuple{T, Vararg{Any}}, -1, Base.get_world_counter())
        (ms isa Vector && !isempty(ms)) && push!(out, T)
    end
    if !(T <: Union{AbstractString, Number})
        for F in fieldtypes(T)
            _callable_types!(out, F, seen)
        end
    end
    return out
end

# What an exempt function `sig` runs on its caller's behalf: the code it calls that its caller handed
# in. A value is HANDED when it is an argument or is loaded from one (a field, an element, an
# iteration's item, at any depth: `getfield`, `memoryrefget` and the like in the IR). A value the
# exempt code BUILDS around one (a closure or struct it constructs) only HOLDS it, and loading from
# that gives a handed value again. A call whose function is a handed value runs the caller's code,
# and its signature is returned so that it is read as the caller's own callee; so is a callable the
# arguments name that was inlined, read from the inlining edges. A callee passed a handed or holding
# value, or whose function holds one, is walked the same way, since it may call what it was given; a
# callee passed neither is the exempt function's own code. A value whose type can carry no callable
# (`_callable_types!` finds none) is not followed: a non-concrete field the code never calls, such as
# the `Any` fields of the task a lock holds, does not stop the exemption.
# Returns `(found, complete)`. The walk is incomplete, and the exemption then excuses nothing, when a
# body cannot be read, the body budget runs out, or a handed or holding value reaches a call that is
# not resolved (a dynamic call, or a builtin that calls a function, such as `_apply_iterate`), whose
# target cannot be read.
const _HANDED_MEMO = IdDict{Any, Tuple{UInt, Vector{Any}, Bool}}()

const _HOLDS = 0x01
const _HANDED = 0x02

# The builtins whose result is loaded from their first argument.
const _LOAD_BUILTINS = (
    :getfield, :memoryrefget, :memoryrefnew, :_svec_ref, :swapfield!, :modifyfield!,
    :replacefield!, :memoryrefswap!, :memoryrefmodify!, :memoryrefreplace!,
)

function _handed_code(@nospecialize(sig))
    world = Base.get_world_counter()
    hit = @lock _SIGNAL_MEMO_LOCK get(_HANDED_MEMO, sig, nothing)
    (!isnothing(hit) && hit[1] == world) && return hit[2], hit[3]
    found = Any[]
    complete = true
    s0 = Base.unwrap_unionall(_key_sig(sig))
    if s0 isa DataType
        carries = IdDict{Any, Bool}()
        handed = collect(Any, _handed_params(s0))
        ps = s0.parameters
        mask = UInt8[
            (i > 1 && any(P -> P === ps[i], handed) && _carries_callable!(carries, ps[i])) ? _HANDED : 0x00
                for i in eachindex(ps)
        ]
        types = filter(isconcretetype, _handed_types(sig))
        queue = Any[(sig, mask)]
        seen = Set{Any}()
        while !isempty(queue) && any(!iszero, mask)
            s, m = pop!(queue)
            (s, m) in seen && continue
            if length(seen) >= _SCAN_BODY_BUDGET[]
                complete = false
                break
            end
            push!(seen, (s, m))
            ci = _typed_body(s)
            if !isnothing(ci) && !_has_inlining_info(ci)
                src = try
                    _code_typed_of(s; optimize = true, debuginfo = :source)
                catch
                    Any[]
                end
                ci = isempty(src) ? nothing : first(src[1])
            end
            if isnothing(ci) || !_handed_body!(found, queue, ci, s, m, types, carries)
                complete = false
                break
            end
        end
    end
    @lock _SIGNAL_MEMO_LOCK (_HANDED_MEMO[sig] = (world, found, complete))
    return found, complete
end

# Whether `P` is a type with one instance that is, or holds, one of the callable `types`.
_holds_handed_type(@nospecialize(P), types) = P isa DataType && Base.issingletontype(P) &&
    any(T -> any(U -> U === T, types), _callable_types!(Any[], P))

# Whether a value of type `T` may be or hold a callable.
function _carries_callable!(memo::IdDict{Any, Bool}, @nospecialize(T))
    T = _unwrap_lattice(T)
    T isa Type || T isa Core.TypeofVararg || return true
    return get!(() -> !isempty(_callable_types!(Any[], T)), memo, T)
end

# One body of `_handed_code`'s walk, with `m` the kind of each argument: records the calls of handed
# values in `found` and queues the callees passed a handed or holding value. `false` when such a
# value reaches a call whose target cannot be read.
function _handed_body!(found, queue, ci, @nospecialize(key), m::Vector{UInt8}, types, carries)
    s = _key_sig(key)
    code = ci.code
    kinds = zeros(UInt8, length(code))
    dead = _skip_mask(code, false, ci, s)
    va = !isempty(m) && Base.unwrap_unionall(s).parameters[end] isa Core.TypeofVararg
    kind(a) = a isa Core.SSAValue ? kinds[a.id] :
        a isa Core.Argument ? (a.n <= length(m) ? m[a.n] : (va ? m[end] : 0x00)) : 0x00
    opkind(args) = isempty(args) ? 0x00 : maximum(kind, args)
    # Phi nodes read values defined later in a loop, so the kinds are propagated to a fixed point.
    changed = true
    while changed
        changed = false
        for i in eachindex(code)
            dead[i] && continue
            st = code[i]
            k = if st isa Core.PhiNode
                opkind(Any[st.values[j] for j in eachindex(st.values) if isassigned(st.values, j)])
            elseif st isa Core.PiNode
                kind(st.val)
            elseif st isa Core.UpsilonNode
                isdefined(st, :val) ? kind(st.val) : 0x00
            elseif st isa Core.PhiCNode
                opkind(st.values)
            elseif Meta.isexpr(st, :invoke)
                opkind(@view st.args[2:end])
            elseif Meta.isexpr(st, :call)
                bn = _builtin_name(st.args[1])
                if !isnothing(bn) && bn in _LOAD_BUILTINS
                    length(st.args) >= 2 && kind(st.args[2]) > 0 ? _HANDED : 0x00
                else
                    opkind(st.args)
                end
            elseif Meta.isexpr(st, :new) || Meta.isexpr(st, :splatnew)
                opkind(@view st.args[2:end]) > 0 ? _HOLDS : 0x00
            elseif Meta.isexpr(st, :foreigncall)
                length(st.args) >= 6 && opkind(@view st.args[6:end]) > 0 ? _HANDED : 0x00
            elseif st isa Expr
                opkind(st.args)
            else
                0x00
            end
            (k > 0 && _carries_callable!(carries, ci.ssavaluetypes[i])) || continue
            if k > kinds[i]
                kinds[i] = k
                changed = true
            end
        end
    end
    local_types = copy(types)
    for i in eachindex(code)
        T = _unwrap_lattice(ci.ssavaluetypes[i])
        kinds[i] === _HANDED && T isa DataType && isconcretetype(T) && !any(U -> U === T, local_types) &&
            push!(local_types, T)
    end
    _handed_inlined!(found, ci.debuginfo, local_types, 0)
    for i in eachindex(code)
        dead[i] && continue
        st = code[i]
        if Meta.isexpr(st, :invoke)
            a1 = st.args[1]
            mi = a1 isa Core.CodeInstance ? a1.def : a1
            mi isa Core.MethodInstance || return false
            ks = UInt8[kind(a) for a in @view st.args[2:end]]
            # A handed value of a type with one instance may be folded to a constant, which no load
            # names: it is recognized by its type.
            ps = (Base.unwrap_unionall(mi.specTypes)::DataType).parameters
            for j in eachindex(ks)
                j <= length(ps) && iszero(ks[j]) && _holds_handed_type(ps[j], local_types) && (ks[j] = _HANDED)
            end
            if ks[1] === _HANDED
                k = _callee_key(mi)
                any(x -> x === k, found) || push!(found, k)
            elseif any(!iszero, ks)
                push!(queue, (_callee_key(mi), ks))
            end
        elseif Meta.isexpr(st, :call)
            opkind(st.args) > 0 || continue
            bn = _builtin_name(st.args[1])
            (isnothing(bn) || haskey(_CALLING_BUILTIN_ARGS, bn)) && return false
        elseif Meta.isexpr(st, :foreigncall) && _fcall_name(st) === :jl_new_task && length(st.args) >= 6
            # A task runs the function it is created with.
            f = st.args[6]
            k = kind(f)
            k > 0 || continue
            T = _unwrap_lattice(_stmt_arg_type(ci, s, f))
            (T isa DataType && isconcretetype(T)) || return false
            if k === _HANDED
                any(x -> x === Tuple{T}, found) || push!(found, Tuple{T})
            else
                push!(queue, (Tuple{T}, UInt8[k]))
            end
        end
    end
    return true
end

function _handed_types(@nospecialize(sig))
    types = Any[]
    s = Base.unwrap_unionall(_key_sig(sig))
    s isa DataType || return types
    for P in Iterators.drop(s.parameters, 1)
        _callable_types!(types, P)
    end
    return types
end

# The specializations of `types` inlined into a body, read from the record of its inlined calls.
# Below one of them is the callable's own code, which reading its signature covers.
function _handed_inlined!(found::Vector{Any}, di, types::Vector{Any}, level::Int)
    (di isa Core.DebugInfo && level < 64) || return found
    for e in di.edges
        e isa Core.DebugInfo || continue
        mi = e.def
        if mi isa Core.MethodInstance && (P = Base.unwrap_unionall(mi.specTypes); P isa DataType) &&
                any(T -> T === P.parameters[1], types)
            k = _callee_key(mi)
            any(x -> x === k, found) || push!(found, k)
        else
            _handed_inlined!(found, e, types, level + 1)
        end
    end
    return found
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

# `ssauses` and `newsdead` are thunks: the use lists and the escape analysis are built only for a
# `:new` that the cheaper tests above them leave undecided.
function _new_allocates(ci, @nospecialize(sig), ssauses, dead, i::Int, newsdead)
    st = ci.code[i]
    nt = _new_type(ci, st)
    nt isa Type || return true
    Base.isbitstype(nt) && return false
    _boxes_into_field(ci, sig, st, nt) && return true
    nt isa DataType && !ismutabletype(nt) && return _immutable_escapes(ci, sig, ssauses(), dead, i)
    _ccall_ref_only(ci, ssauses(), i) && return false
    return !newsdead()
end

# The signals of the body `ci` of `key` (`_callee_key`) and of the callees the walk follows from it.
function _scan_ci(
        ci, @nospecialize(key), depth::Int, seen::Base.IdSet{Any}, mode::Symbol = :full, top::Bool = false,
        trace::Union{Nothing, Vector{Any}} = nothing; caught = false
    )
    sig = _key_sig(key)
    alloc = false
    boxing = false
    dictlookup = false                # a runtime AbstractDict accessor reached on the hot path
    abscontainer = nothing            # the abstract element type of the first abstract-eltype container seen
    barrier = false                   # a call reached a recognized one-time-init allocation barrier
    unionphi = false                  # a union-typed phi whose members do not all ride unboxed (F39)
    exempt = nothing                  # the first `@strict_exempt :noalloc` callee whose allocation was excused
    # The first registered barrier found to box, or to look up a dictionary, inside itself. A barrier
    # excuses only allocation: what else it does is judged at the barrier, once, and its callers
    # are pointed there rather than failed again for the same cause. Not read in mode `:alloc`,
    # where a box is an allocation and so excused with the rest.
    barrier_dict = nothing
    barrier_box = nothing
    truncated = false                 # part of the call graph was left unread
    # Per frame, so a callee's own `:new`s are judged against the callee's own escape analysis.
    # Computed on demand: the analysis costs about as much as the whole rest of the scan, and it can
    # only change the verdict at a non-isbits `:new`/`memorynew` that nothing else has flagged yet.
    # Corpus-measured (PureBLAS + PureIPM, 120 specializations): 57 frames reach no such statement.
    escmemo = Ref{Union{Nothing, Bool}}(nothing)
    newsdead() = escmemo[] === nothing ? (escmemo[] = _all_news_nonescaping(key))::Bool : escmemo[]::Bool
    dead = _skip_mask(ci.code, caught, ci, sig)
    # A callee called from a try region whose handler can return is scanned in a caught context.
    region = caught === true || !ignore_throw() ? nothing : _caught_contexts(ci.code, dead, ci)
    callee_caught(i) = isnothing(region) ? caught : _join_caught(caught, region[i])
    # Built on demand, like the escape analysis: only a non-isbits `:new` reads it.
    # Both branches are asserted, like `newsdead` above. Without it the memo's `Union{Nothing, …}`
    # is the closure's return type: the `isnothing` check narrows the FIRST load of the `Ref`, and
    # the else branch is a second, separate load that inference cannot narrow. That union reaches
    # `_ccall_ref_only` and `_new_allocates`, which then compile a `Nothing` specialization whose
    # only possible act is to throw on `uses[i]`.
    usememo = Ref{Union{Nothing, _SSAUses}}(nothing)
    ssauses() = isnothing(usememo[]) ? (usememo[] = _ssa_uses(ci))::_SSAUses : usememo[]::_SSAUses
    # Whether this body is Base's task, lock or condition code. Boxing there is the scheduler's own, off
    # the call's hot path, and is not counted, except in code the scheduler was handed to run: the
    # function given to `lock(f, l)` is its caller's, inlined or called (`_calls_argument`).
    schedmemo = Ref{Union{Nothing, Bool}}(nothing)
    insched() = isnothing(schedmemo[]) ? (schedmemo[] = _sig_in_scheduler(key))::Bool : schedmemo[]::Bool
    unsplitmemo = Ref{Union{Nothing, Bool}}(nothing)
    unsplit() = isnothing(unsplitmemo[]) ? (unsplitmemo[] = _unsplit(ci, key))::Bool : unsplitmemo[]::Bool
    schedstmt(i) = insched() ? _stmt_in_scheduler(ci, key, i, true, unsplit()) : _stmt_in_scheduler(ci, key, i, false, false)
    for (i, st) in enumerate(ci.code)
        local T = ci.ssavaluetypes[i]
        if top && abscontainer === nothing && _abstract_container(T)
            abscontainer = eltype(T)
        end
        if !boxing && (Meta.isexpr(st, :new) || Meta.isexpr(st, :foreigncall)) && !dead[i] &&
                _boxing_store(ci, sig, st) && !schedstmt(i)
            boxing = true
            isnothing(trace) || push!(trace, (i, st, :boxing))
        end
        # `:boxing` reads dispatch and boxing stores: an allocation, a dictionary lookup and a union phi are
        # other questions.
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
            if !alloc && _new_allocates(ci, sig, ssauses, dead, i, newsdead)
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
                    elseif (ex = _callee_excusal(mi, mode)).kind === :barrier
                        # The callee itself IS a recognized barrier (e.g. `(::OncePerProcess)()`,
                        # or a directly-registered function) — its one-time cold-path allocation
                        # is not a steady-state cost, so recursion stops here rather than seeing it.
                        # Under `:alloc` that is all of it: a box is an allocation. The other modes
                        # read a registered barrier for the causes it does not excuse.
                        barrier = true
                        registered = depth > 0 && mode !== :alloc && _is_registered_callee(first(mi.specTypes.parameters))
                        if registered
                            _, b2, d2, _, _, _, _, bd2, bb2, _ = _excused_signals(mi, depth - 1, seen, mode, callee_caught(i))
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
                        # first; so is the scheduler (`_followed_to_end`). Below the last Base level `depth` is -1,
                        # which follows those alone.
                        user = _followed_to_end(mi)
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
                            cc = callee_caught(i)
                            # A callee exempted from `:noalloc` has its allocation excused here
                            # too — it is the same allocation, already excused where it is made —
                            # and so has its boxing, since a box is an allocation. The excusal is
                            # recorded, so the caller is reported as reaching it rather than as
                            # clean. The callee's dictionary lookups still count. Code the callee
                            # was handed by its caller and that it calls is the caller's: each such
                            # call is read as the caller's own callee (`_callee_excusal`).
                            if ex.kind === :exempt
                                a2, b2, d2, _, br2, up2, ex2, bd2, bb2, tr2 = _excused_signals(mi, sub, seen, mode, cc)
                                ((a2 || b2) && isnothing(exempt)) && (exempt = ex.name)
                                a2 = b2 = false
                            else
                                a2, b2, d2, _, br2, up2, ex2, bd2, bb2, tr2 = _signals_by_type(_callee_key(mi), sub, seen, mode, cc)
                            end
                            tr2 && (truncated = true)
                            isnothing(barrier_dict) && (barrier_dict = bd2)
                            isnothing(barrier_box) && (barrier_box = bb2)
                            a2 && (alloc = true)
                            for h in ex.handed
                                ha, hb, _, _, _, _, _, _, _, htr = _signals_by_type(h, sub, seen, mode, cc)
                                htr && (truncated = true)
                                ha && (alloc = true)
                                hb && (boxing = true)
                            end
                            (isnothing(exempt) && !isnothing(ex2)) && (exempt = ex2)
                            (b2 && (!insched() || _in_scheduler(mi) || _calls_argument(sig, mi.specTypes) || !schedstmt(i))) &&
                                (boxing = true)
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
            if !boxing && !dead[i] && (callee === Core.setfield! || callee === Core.memoryrefset! || callee === Core.setglobal!) &&
                    _boxing_store(ci, sig, st, callee) && !schedstmt(i)
                boxing = true
                isnothing(trace) || push!(trace, (i, st, :boxing))
            end
            # A bounds-checked `memoryrefnew` throws the `BoundsError` it builds itself, so the call is an
            # allocation wherever that throw returns normally (`_returns_for`).
            if !(mode === :boxing || alloc || dead[i]) && _maythrow(ci, i) && _bounds_checked_ref(ci, sig, st) &&
                    (!ignore_throw() || _returns_for(callee_caught(i), BoundsError))
                alloc = true
                isnothing(trace) || push!(trace, (i, st, :alloc))
            end
            if callee === Core.memorynew           # 1.12 `Memory` allocation is a builtin :call
                if !(mode === :boxing || alloc || dead[i] || newsdead())
                    alloc = true
                    isnothing(trace) || push!(trace, (i, st, :alloc))
                end
            elseif callee === Core._apply_iterate
                # A splat the optimizer could not unroll (`max(v...)` over a `Vector`): the callee is
                # looked up at run time for an argument list built at run time, whatever type
                # inference gives the result.
                if !dead[i] && !(insched() && schedstmt(i))
                    boxing = true
                    isnothing(trace) || push!(trace, (i, st, :boxing))
                end
            elseif _nonconcrete(T) && !_static_getfield(callee, st) && !_plain_load(ci, sig, callee, st)
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
                if !(insched() && schedstmt(i))
                    boxing = true
                    isnothing(trace) || push!(trace, (i, st, :boxing))
                end
            elseif !boxing && !(insched() && schedstmt(i))
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
_mi_exempt_name(mi::Core.MethodInstance) =
    (e = _mi_exemption(mi); isnothing(e) ? nothing : _demangle(mi.def.name))

# The exemption that covers `:noalloc` for the method `mi` is a specialization of, at the types
# it is called with. One declared in a module is matched on that module as well as the name: a
# function of the same name elsewhere is another function. One declared with no module, from a
# session, covers by name wherever the function lives, and `declared_in_module = true` leaves
# those out, for a caller that needs the exemption to name a method.
function _mi_exemption(mi::Core.MethodInstance; declared_in_module::Bool = false)
    mi.def isa Method || return nothing
    es = _noalloc_exemptions()
    isempty(es) && return nothing
    name = _demangle(mi.def.name)
    ps = mi.specTypes.parameters
    types = length(ps) > 1 ? Tuple(ps[2:end]) : ()
    root = Base.moduleroot(mi.def.module)
    for (mod, e) in es
        (declared_in_module && isnothing(e.mod) && isnothing(mod)) && continue
        # The declaring module when recorded, else the package root of the store it came from.
        if !isnothing(e.mod)
            mi.def.module === e.mod || continue
        else
            (isnothing(mod) || mod === root) || continue
        end
        # The specialization is named by its MethodInstance, as a `_Spec` names it, so an exemption
        # that names another method of the function does not cover it.
        _covers(e, name, _Spec(mi), types, :noalloc) && return e
    end
    return nothing
end

# --- Base.infer_effects layer (cheap; basis for @assert_effects in Phase 3) -------------------

"""
    StrictMode.effects(f, types) -> Core.Compiler.Effects

The compiler's inferred effects for `f`'s signature — a cheap (inference-only) read of whether a
method is `:nothrow`, `:effect_free`, `:terminates`, `:consistent`, etc. Used by the `:fast`
triage and by `@assert_effects`.

A signature with no typed body (no method matches it, or its generator raised) raises
`_UnanalyzableSignature`: the compiler answers it with every effect but `:nothrow`, which
describes no code.
"""
function effects(@nospecialize(f), @nospecialize(types::Tuple))
    isnothing(_typed_body(_entry_key(f, types))) &&
        throw(_UnanalyzableSignature(:effects, f, types, _NO_BODY_WHY))
    return _infer_effects(f, types)
end

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
const _LOCAL_SCOPED = :__strict_scoped_types__

# Every scoped type in scope: this session's, and each loaded package's own.
_scoped_types() = _registrations(_SCOPED_TYPES, _LOCAL_SCOPED)

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

A registration made at a package's top level, while the package precompiles, is written into that
package's cache, so it is in force again in every process that loads it. Only the package being
precompiled is written, and `mod` names it. It defaults to the module that owns `T`, so
registering a type another package owns needs `mod = @__MODULE__` and raises without it:
the registration would hold for that precompile and be gone afterwards. A raise registers
nothing, in that precompile either. A call made from an
`__init__` runs again at every load, so it registers for the session and stores nothing. So does a
call made by the owning package's own code while another package precompiles, such as a
registration on first use that a dependent's precompile workload triggers. In a
session the registration lasts for the session.

See also [`@assert_noescape`](@ref), [`register_alloc_barrier!`](@ref).
"""
function register_scoped!(@nospecialize(T::Type); mod::Module = _owner_module(T))
    # Stored first: a registration that cannot be kept raises, and must leave the session unchanged.
    _keep_registration!(T, mod, _LOCAL_SCOPED, "register_scoped!($T)")
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
    for S in _scoped_types()
        T <: S && return true
    end
    return false
end

"""
    _escaping_scoped(sig) -> (; escaped, undetermined)

The registered scoped types that escape the frame the body key `sig` names, and the ones whose
fate this cannot decide. Both empty means nothing escaped, which is also the answer when no type
is registered.

Only a `:new` carries a verdict. The escape state of a value returned by a call comes from the
conservative cache callback, which assumes an uncached callee escapes its arguments — so a handle
from a producer that did not inline reads as escaping whatever it does, and reporting that as an
escape is a false positive. Those land in `undetermined` instead: a frame whose handle is created
elsewhere has to be asked about where the handle is created.
"""
function _escaping_scoped(@nospecialize(sig))
    sig = _forwarded_sig(sig)   # a default or keyword forwarder hands the handle to its body
    isempty(_scoped_types()) && return (; escaped = String[], undetermined = String[])
    EA = Core.Compiler.EscapeAnalysis
    irs = _code_ircode_of(sig)
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
    r = _escaping_scoped(_entry_key(f, types))
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
# What an emptied cache costs is the checked package's own code inferred again: Base and every loaded
# package are answered from the compiler's cache in any world (`_scan_cache_lookup`). 87 signatures
# checked with a method definition before each, as `@strict_function` does at a precompile, take 2.1 s.
const _CC = Base.Compiler

struct _ScanCacheOwner end

struct _ScanCodeCache
    entries::IdDict{Core.MethodInstance, Core.CodeInstance}
    sources::IdDict{Core.CodeInstance, Core.CodeInfo}
    world::Base.RefValue{UInt}
    lock::ReentrantLock
end
_ScanCodeCache() = _ScanCodeCache(
    IdDict{Core.MethodInstance, Core.CodeInstance}(), IdDict{Core.CodeInstance, Core.CodeInfo}(),
    Ref(UInt(0)), ReentrantLock()
)

function Base.empty!(c::_ScanCodeCache)
    @lock c.lock (empty!(c.entries); empty!(c.sources))
    return c
end

const _SCAN_CODE_CACHE = _ScanCodeCache()

# What the scan inferred itself, or else what the compiler already holds: Base, the standard
# libraries and every loaded package come with their inference in the system and package images,
# and inferring them a second time is most of what an empty cache costs. The compiler's entry
# is the one its own inference of the same caller would use, so the body read is the body compiled.
function _scan_cache_lookup(c::_ScanCodeCache, mi::Core.MethodInstance, worlds)
    world = first(worlds)
    world == last(worlds) || return nothing
    ci = @lock c.lock (c.world[] == world ? get(c.entries, mi, nothing) : nothing)
    isnothing(ci) || return ci
    return get(_CC.WorldView(_CC.InternalCodeCache(nothing), _CC.WorldRange(world)), mi, nothing)
end

# The optimized body the scan's inference kept for a specialization it inferred as a callee.
function _scan_source(mi::Core.MethodInstance, world::UInt)
    c = _SCAN_CODE_CACHE
    return @lock c.lock begin
        ci = c.world[] == world ? get(c.entries, mi, nothing) : nothing
        isnothing(ci) ? nothing : get(c.sources, ci, nothing)
    end
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
            empty!(c.sources)
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
    sources::IdDict{Core.CodeInstance, Core.CodeInfo}
end

_ScanInterpreter(world::UInt = Base.get_world_counter()) = _ScanInterpreter(
    world, _CC.InferenceParams(), _CC.OptimizationParams(), _CC.InferenceResult[],
    IdDict{Core.CodeInstance, Core.CodeInfo}()
)

_CC.InferenceParams(interp::_ScanInterpreter) = interp.inf_params
_CC.OptimizationParams(interp::_ScanInterpreter) = interp.opt_params
_CC.get_inference_world(interp::_ScanInterpreter) = interp.world
_CC.get_inference_cache(interp::_ScanInterpreter) = interp.inf_cache
_CC.cache_owner(::_ScanInterpreter) = _ScanCacheOwner()
_CC.code_cache(interp::_ScanInterpreter) = _CC.WorldView(_SCAN_CODE_CACHE, _CC.WorldRange(interp.world))
_CC.may_compress(::_ScanInterpreter) = false
# The compiler hands the optimized body of every specialization it caches to this table, including
# one too large to inline, whose body it keeps nowhere else. The walk reads those bodies next, so
# they are kept (`_keep_sources`) and not inferred a second time.
_CC.codegen_cache(interp::_ScanInterpreter) = interp.sources

# One table per interpreter, since the compiler writes to it without a lock; merged into the shared
# cache when the inference call returns, if the cache still answers for that world.
function _keep_sources(interp::_ScanInterpreter)
    isempty(interp.sources) && return nothing
    c = _SCAN_CODE_CACHE
    @lock c.lock begin
        c.world[] == interp.world && merge!(c.sources, interp.sources)
    end
    return nothing
end
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
#
# StrictMode's own image is the one place those records belong: its precompile workload runs the scan
# so that the compiler's methods specialized on `_ScanInterpreter` are compiled once, here, and not
# in every process that scans (`typeinf_local` alone takes 0.8 s to compile). No record is taken
# back while the workload runs.
#
# Windows nest, and one kind of record made inside them is the consumer's: what `_infer_for_image`
# has the compiler infer. Those are set aside and put back whenever a window closes, and forgotten
# once the outermost one has.
const _KEEP_SCAN_SPECIALIZATIONS = Ref(false)
const _WINDOW_DEPTH = Ref(0)
const _IMAGE_RECORDS = Any[]

function _window_open()
    (
        !_KEEP_SCAN_SPECIALIZATIONS[] && ccall(:jl_generating_output, Cint, ()) == 1 &&
            isdefined(Base, :newly_inferred)
    ) || return -1
    _WINDOW_DEPTH[] += 1
    return length(Base.newly_inferred)
end

function _window_close(n::Int)
    n >= 0 || return nothing
    length(Base.newly_inferred) > n && resize!(Base.newly_inferred, n)
    append!(Base.newly_inferred, _IMAGE_RECORDS)
    iszero(_WINDOW_DEPTH[] -= 1) && empty!(_IMAGE_RECORDS)
    return nothing
end

# A `Base.@ccallable` method is compiled into the image of the package that defines it whether or
# not anything calls it, so the compiler infers it and everything below it when the image is
# written. While a package is being generated, such a method is therefore inferred by the compiler's
# own interpreter, and the scan reads the results through `_scan_cache_lookup`: inferring it under
# the scan's interpreter is the same work done a second time, with a result nothing keeps. The
# compiler's results are the ones the image needs, so their records outlive the window.
# Measured on Julia 1.13 with a package of 40 such entry points over a call tree of 1440 generic
# helpers, checked with `(:typestable, :trim_compatible)`: its precompile takes 55 s with this and
# 68 s without (51 s with checks off), and its image is 125.5 MB in all three.
function _infer_for_image(mi::Core.MethodInstance, world::UInt)
    m = mi.def
    (m isa Method && isdefined(m, :ccallable) && mi.specTypes === m.sig) || return nothing
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    isnothing(_record_of(mi, world)) || return nothing
    n = isdefined(Base, :newly_inferred) ? length(Base.newly_inferred) : -1
    interp = _CC.NativeInterpreter(world)
    try
        Base.invoke_interp_compiler(interp, :typeinf_type, interp, mi)
    catch
        # The scan then infers it under its own interpreter, as it does any other method.
    end
    if n >= 0 && _WINDOW_DEPTH[] > 0
        for i in (n + 1):length(Base.newly_inferred)
            push!(_IMAGE_RECORDS, Base.newly_inferred[i])
        end
    end
    return nothing
end

# The other readings of the compiler's inference answer under the same interpreter.
function _return_types(@nospecialize(f), @nospecialize(types))
    world = Base.get_world_counter()
    mi = f isa _Spec ? f.mi : _sig_instance(_sigtype(f, types), world)
    isnothing(mi) || _infer_for_image(mi, world)
    n = _window_open()
    interp = _ScanInterpreter()
    try
        f isa _Spec && return _return_types_of(mi, interp, interp)
        f isa _Callable || return Base.return_types(f, types; interp)
        return _return_types_by_type(_sigtype(f, types), interp, interp)
    finally
        _keep_sources(interp)
        _window_close(n)
    end
end

# `Base.return_types` for the signature `tt`, with its `passed_interp` and `interp`.
function _return_types_by_type(@nospecialize(tt), passed_interp, interp)
    matches = Base.invoke_interp_compiler(passed_interp, :_findall_matches, interp, tt)
    matches === nothing && Base.raise_match_failure(:return_types, tt)
    return Any[
        something(Base.invoke_interp_compiler(passed_interp, :typeinf_type, interp, m::Core.MethodMatch), Any)
            for m in matches.matches
    ]
end

# The inferred return type of the specialization `mi`, as `_return_types_by_type` gives a match's.
_return_types_of(mi::Core.MethodInstance, passed_interp, interp) =
    Any[something(Base.invoke_interp_compiler(passed_interp, :typeinf_type, interp, mi), Any)]

# `Base.return_types(f, Tuple{types...}; world)` under the default interpreter, for a `_Callable` and
# a `_Spec` too.
function _base_return_types(@nospecialize(f), @nospecialize(types); world::UInt = Base.get_world_counter())
    f isa _Spec && return _return_types_of(f.mi, nothing, Base.invoke_default_compiler(:_default_interp, world))
    f isa _Callable || return Base.return_types(f, Tuple{types...}; world)
    return _return_types_by_type(_sigtype(f, types), nothing, Base.invoke_default_compiler(:_default_interp, world))
end

function _infer_effects(@nospecialize(f), @nospecialize(types))
    n = _window_open()
    interp = _ScanInterpreter()
    try
        if f isa _Spec
            # `Base.infer_effects` of the one specialization.
            frame = Base.invoke_interp_compiler(interp, :typeinf_frame, interp, f.mi, true)
            return frame === nothing ? _CC.Effects() : frame.result.ipo_effects
        end
        f isa _Callable || return Base.infer_effects(f, types; interp)
        # `Base.infer_effects`, read by the signature.
        tt = _sigtype(f, types)
        effects = Base.invoke_interp_compiler(interp, :_infer_effects, interp, tt, true)
        effects === nothing && Base.raise_match_failure(:infer_effects, tt)
        return effects
    finally
        _keep_sources(interp)
        _window_close(n)
    end
end

# `_code_ircode_by_type` for the body `key` names (`_callee_key`).
function _code_ircode_of(@nospecialize(key))
    key isa Core.MethodInstance || return _code_ircode_by_type(key)
    n = _window_open()
    interp = _ScanInterpreter()
    try
        ir, rt = Base.invoke_interp_compiler(interp, :typeinf_ircode, interp, key, _INLINING_PASS)
        return isnothing(ir) ? Any[] : Any[ir => rt]
    finally
        _keep_sources(interp)
        _window_close(n)
    end
end

function _code_ircode_by_type(@nospecialize(sig))
    n = _window_open()
    interp = _ScanInterpreter()
    try
        return Base.code_ircode_by_type(sig; optimize_until = _INLINING_PASS, interp)
    finally
        _keep_sources(interp)
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
_sigtype(@nospecialize(f), @nospecialize(types)) = Core.apply_type(Tuple, _ftype(f), types...)

# A callable object known by its type alone. A compiled specialization of a callable struct's
# method names the struct's type and holds no instance of it, and every analysis here reads the
# signature only, so `_Callable{F}()` stands for an instance of `F` wherever the engine takes a
# function. Base's `(f, types)` reflection reads the type of the value it is handed, so the readers
# below reach Base by the signature for it.
struct _Callable{F} end

# The callee for a function type: its singleton instance when it has one, `_Callable{F}()` otherwise.
_callee(@nospecialize(F)) = (F isa DataType && isdefined(F, :instance)) ? F.instance : _Callable{F}()

# --- the body an item names ----------------------------------------------------------------------
#
# An item `(f, types)` is checked as the body it names, and names it by a key (`_callee_key`): the
# signature `Tuple{typeof(f), types...}`, which names the specialization a call dispatches to. A
# module sweep also meets specializations that no call dispatches to: `invoke(f, Tuple{wider},
# args...)` compiles the wider method for argument types a more specific method answers. Such a
# specialization is an item `(_Spec(mi), types)`, and its key is `mi` itself.
#
# The invariant: every guarantee reads an item's body through `_entry_key`, in both tiers, and a
# `_Spec` cannot be turned into a signature. `_ftype` and `_sigtype` raise on one, so a reader that
# would dispatch its signature, and judge the other method, fails the item instead of passing it.
# `_which`, `_code_typed`, `_return_types`, `_base_return_types`, `_infer_effects`, `_llvm_ir` and
# `_native_asm` read a `_Spec` as its specialization; a backend that takes a function and argument
# types is driven through `_invoke_through`, whose body runs exactly that specialization.
struct _Spec
    mi::Core.MethodInstance
end

const _SPEC_BY_SIG = "a specialization reached only through `invoke` has no signature that " *
    "dispatches to it, so it is read by its MethodInstance (`_entry_key`), never by signature"

# The key of the body the item `(f, types)` names.
_entry_key(@nospecialize(f), @nospecialize(types)) = f isa _Spec ? f.mi : _sigtype(f, types)

# The function a `_Spec` belongs to, as `_callee` gives it.
_spec_callee(s::_Spec) = _callee((s.mi.specTypes::DataType).parameters[1])

# The item for the compiled specialization `mi` of `f`: `f` itself when its signature dispatches to
# `mi`, and `_Spec(mi)` when it dispatches to another specialization.
_entry_of(@nospecialize(f), mi::Core.MethodInstance) =
    _sig_instance(mi.specTypes, Base.get_world_counter()) === mi ? f : _Spec(mi)

# The argument types `invoke` selects the method of `s` by: the method's own, which only that method
# answers. `_invoke_through` checks that the call it compiles is of `s.mi` before a backend reads it.
function _spec_invoke_types(s::_Spec)
    m = s.mi.def::Method
    return Base.rewrap_unionall(Tuple{Base.unwrap_unionall(m.sig).parameters[2:end]...}, m.sig)
end

# The type a call to `f` dispatches on.
function _ftype(@nospecialize(f))
    f isa _Spec && throw(ArgumentError(_SPEC_BY_SIG))
    return f isa _Callable ? typeof(f).parameters[1] : Core.Typeof(f)
end

# `which(f, types)`, where `types` is a tuple of types or a tuple type.
function _which(@nospecialize(f), @nospecialize(types))
    f isa _Spec && return f.mi.def::Method
    f isa _Callable || return which(f, types)
    ps = types isa Type ? Base.unwrap_unionall(types).parameters : types
    return which(_sigtype(f, ps))
end

function _code_typed(
        @nospecialize(f), @nospecialize(types); optimize::Bool = true, debuginfo::Symbol = :default
    )
    f isa _Spec && return _code_typed_of(f.mi; optimize, debuginfo)
    ps = types isa Type ? Base.unwrap_unionall(types).parameters : types
    return _code_typed_by_type(Core.apply_type(Tuple, _ftype(f), ps...); optimize, debuginfo)
end

# `_code_typed_by_type` for the body `key` names (`_callee_key`): a specialization is inferred as
# itself, where a signature is dispatched.
function _code_typed_of(@nospecialize(key); optimize::Bool = true, debuginfo::Symbol = :default)
    key isa Core.MethodInstance || return _code_typed_by_type(key; optimize, debuginfo)
    n = _window_open()
    interp = _ScanInterpreter()
    try
        src = Base.invoke_interp_compiler(interp, :typeinf_code, interp, key, optimize)
        return src isa Core.CodeInfo ? Any[src => src.rettype] : Any[]
    finally
        _keep_sources(interp)
        _window_close(n)
    end
end

function _code_typed_by_type(@nospecialize(sig); optimize::Bool = true, debuginfo::Symbol = :default)
    n = _window_open()
    interp = _ScanInterpreter()
    try
        return filter(
            p -> first(p) isa Core.CodeInfo,
            Base.code_typed_by_type(sig; optimize, debuginfo, interp)
        )
    finally
        _keep_sources(interp)
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
        _code_typed_of(s; optimize = true)
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
            push!(succ, _callee_key(mi))
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
