# Guarantees

Each guarantee pins a *necessary* property of a hot kernel — allocation-free, type-stable,
vectorized — and fails loudly the moment an edit breaks it. Once an assert is in place it fences
every future edit: refactor freely and get told the instant something crosses the line. They keep
you on the fast path; they don't promise you've found the *fastest* path. For diagnostics that
address the gap between "passing" and "fast," see [Performance diagnostics](performance_diagnostics.md).

## Key concepts

If these terms are unfamiliar, a quick definition before diving in:

- **Type stability** — the compiler can predict a function's return type without running it. A
  stable function always returns `Float64`, say; an unstable one might return `Float64` or `Int`
  depending on a runtime condition. Instability forces the compiler to generate slower, more
  general code downstream.

- **Boxing** — wrapping a value in a generic heap-allocated container because its type can't be
  predicted at compile time. A runtime index into a heterogeneous tuple (e.g. `t[i]` where `t`
  holds mixed types) causes boxing. Each box costs a heap allocation and prevents SIMD vectorization.

- **Dynamic dispatch** — resolving which method to call at runtime rather than at compile time.
  Happens when the compiler can't pin down the type of a receiver, and adds a function-table lookup
  to every call.

Allocation-free code avoids all three. Type-stable code avoids instability (and usually boxing
too). The macros below enforce each property separately so you can be precise about what you need.
See [Key Concepts](concepts.md) for worked examples of each.

Every example here is live. The docs are built with checks enabled, so the analysis runs as the
page is generated. Calls that pass are shown as real `@example` blocks; calls that are meant to
fail are shown as annotated code, so the build itself stays green.

```@example guide
using StrictMode
```

## `@assert_noalloc` — no heap allocations

For this one, StrictMode hands the call to [AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl)
and asks it to prove there's no way the call can allocate. Dynamic dispatch and boxing both show up
as allocations, so they get caught here as well.

```@example guide
dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]

@assert_noalloc dot3((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
```

When static analysis can't run on a call, `static = false` falls back to measuring it directly
with `@allocated`, after a warmup pass:

```julia
@assert_noalloc static = false stream_step!(buffer, x)   # measures @allocated, not a static proof
```

An allocating hot loop gets turned away:

```julia
function grow_and_sum(n)
    v = Int[]              # allocates
    for i in 1:n
        push!(v, i)        # …and grows
    end
    return sum(v)
end

@assert_noalloc grow_and_sum(10)
# ERROR: StrictViolation (@noalloc): guarantee not satisfied
#   target:  grow_and_sum(10)
#   reason:  call provably allocates (… site(s)): …
```

### One-time-init calibration doesn't have to break this

A `Base.OncePerProcess`/`OncePerThread`-memoized lazy calibration allocates once, then reads a
memoized value forever after — but AllocCheck's all-paths proof sees the initializer's one-time
allocation as statically reachable and would otherwise red a call that's provably alloc-free in
steady state. `@assert_noalloc`/`@assert_noboxing` recognize the two `Base` once-guard types
automatically and substitute the (already-correct) `:fast` steady-state heuristic for that one
call, rather than reporting the cold-path allocation as a violation — logged once per session via
`@info`, never silently:

```julia
const _NP_ONCE = Base.OncePerProcess{Int}(_measure_calibration)
steady(x::Int) = x + _NP_ONCE()

@assert_noalloc steady(1)   # passes: the once-guard's cold path is exempted, not the caller's own code
```

For a hand-rolled memoization pattern that doesn't use one of those two `Base` types, register it
explicitly with [`register_alloc_barrier!`](@ref). `Base.OncePerTask` is **not**
auto-recognized (its implementation has no detectable non-inlined callee boundary to key off of —
wrap it in your own function and register that instead).

## `@assert_noboxing` — forbid boxing, allow buffers

[`@assert_noboxing`](@ref) is the easygoing cousin of `@assert_noalloc`. It only objects to the
allocations that come from type uncertainty: boxing (the runtime-tuple-index trap, or a captured
variable wrapped in a `Core.Box`) and dynamic dispatch. Honest typed heap allocations are fine by
it. Reach for it on a hot path that's allowed to allocate a working buffer but must never box.

```@example guide
function fill_sum(n)
    v = Vector{Float64}(undef, n)   # a real heap allocation …
    for i in 1:n
        @inbounds v[i] = i
    end
    return sum(v)
end

@assert_noboxing fill_sum(3)        # passes: it allocates, but it does not box
```

That same call doesn't get past `@assert_noalloc`, which forbids allocation of any kind:

```julia
@assert_noalloc fill_sum(3)
# ERROR: StrictViolation (@noalloc): call provably allocates … Vector{Float64} …
```

Boxing and dynamic dispatch, though, are still out:

```julia
boxy(t) = (s = 0.0; for i in 1:3; s += t[i]; end; s)   # heterogeneous tuple, runtime index
@assert_noboxing boxy((1, 2.0, 3.0f0))
# ERROR: StrictViolation (@noboxing): call boxes / dynamically dispatches …
#   Allocating runtime call to "jl_get_nth_field_checked" …
```

Because it has to classify each allocation, it always runs the static AllocCheck analysis, and so
it ignores the `:fast` [`analysis_mode`](@ref).

## `@assert_typestable` — concrete, stable types

This one pairs two checks: `Test.@inferred` insists the return type is concrete, and
`JET.@report_opt` insists there's no instability or runtime dispatch hiding inside.

```@example guide
affine(x) = 2x + 1

@assert_typestable affine(3.0)
```

Runtime tuple indexing, the trap that keeps coming up, produces a `Union` return type and boxes.
It doesn't pass:

```julia
state = (1, 2.0, "three")     # heterogeneous tuple
component(s, i) = s[i]        # i is a runtime value → Union{Int,Float64,String}

@assert_typestable component(state, rand(1:3))
# ERROR: StrictViolation (@typestable): guarantee not satisfied
#   target:  component(state, rand(1:3))
#   reason:  return type is not concretely inferrable: …
```

## Keyword calls and explicit signatures

Every guarantee macro accepts two extra forms, so you can point them straight at a real API instead
of an internal positional driver.

**Keyword arguments.** A keyword call is guaranteed as written — StrictMode routes it through
`Core.kwcall`, so inference, AllocCheck and JET all see the keyword sorter's real specialization:

```julia
@assert_noalloc    trsm!(B, A; side='L', uplo='L', alpha=1.0)   # public kwarg entry point, proved
@assert_typestable scale(x; by=2)
```

**`types = (…)` — pin the analyzed signature.** By default the signature comes from
`typeof.(args)`, so `typeof(Float64) == DataType`. For a *type-argument* function that widens a
genuine false positive: over `Tuple{DataType, …}` the parameter `T` is unresolvable, so the return
type widens to non-concrete. Supply the real specialization explicitly:

```julia
tmp(::Type{T}, n) where {T} = Vector{T}(undef, n)

@assert_typestable tmp(Float64, 4)
# ERROR: StrictViolation (@typestable): return type is not concrete: Vector  (DataType widened `T`)

@assert_typestable tmp(Float64, 4) types=(Type{Float64}, Int)   # ok: real call-site specialization
```

`types = (…)` works on `@assert_noalloc`, `@strict`, `@kernel` and the rest the same way. It is the
general escape hatch whenever `typeof.(args)` doesn't name the specialization you actually run.

## `@assert_inlined` — keep the call on the fast path (best-effort)

[`@assert_inlined`](@ref) fails unless the compiler actually inlined the call. To find out,
StrictMode compiles a tiny wrapper around it and reads the optimized IR: if the call is still
sitting there as an `:invoke`, it wasn't absorbed, and the assert fails.

Inlining is a heuristic, not a promise, so this one is best-effort by nature. A failure only means
the compiler chose not to inline under the current settings, which may or may not matter to you.
That's why it isn't part of [`@strict`](@ref).

```julia
@inline   hot(x) = x * x + 1
@assert_inlined hot(3.0)        # ok: small, inlined

@noinline cold(x) = x * x + 1
@assert_inlined cold(3.0)
# ERROR: StrictViolation (@inlined): call to `cold` was not inlined — it survives as an `:invoke` …
```

## `@assert_trim_compatible` — static-binary (`juliac --trim`) compatibility

[`@assert_trim_compatible`](@ref) fails unless `f(args...)` is compatible with `juliac --trim=safe`, the
static-binary build mode that rejects dynamic dispatch and reflection. It **escalates** with
[`analysis_mode`](@ref): in `:fast` (or when `TrimCheck` is not loaded) it runs a value-free `TypeContracts`
scan of the typed IR; in `:full` with the optional `TrimCheck` weak dependency it runs juliac's
*authoritative* `verify_typeinf_trim` verifier over the exact signature, returning deduplicated,
source-mapped findings.

Like `@assert_inlined`, this is advisory and **opt-in** — *not* part of [`@strict`](@ref): juliac's
whole-program verifier over the real build is the final word. [`@assert_trim_safe`](@ref) is the
static-only subset (never escalates; needs no `TrimCheck`). The reactive counterpart, for a real build log,
is [`explain_trim`](@ref).

```julia
clean(x::Int) = x * 2 + 1
@assert_trim_compatible clean(3)          # ok

reflecty(x::Int) = length(Base.return_types(sin, (Float64,)))   # reflection → trim-unsafe
@assert_trim_compatible reflecty(3)
# ERROR: StrictViolation (@trim_compatible): trim-incompatible (juliac --trim=safe):
#   Base.indexed_iterate(…)::Any  [myfile.jl:NN]; … (+N more call site(s))
```

As an engine guarantee it is `:trim_compatible` (with `:trimsafe` the static subset):

```julia
check(reflecty, (Int,); guarantees = (:trim_compatible,))
```

## `@strict` — every per-call guarantee at once

[`@strict`](@ref) checks type stability first, since that's usually what's behind a surprise
allocation, and then allocation-freedom. It returns the call's value, so you can drop it in around
an expression you already have:

```@example guide
saxpy(a, x, y) = a .* x .+ y

result = @strict saxpy(2.0, (1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
```

## `@strict_function` — verify a definition at load time

Put it on a definition and StrictMode checks that definition against its declared argument types,
at precompile or module-load time. A clean one loads like any other:

```@example guide
@strict_function scaled(a::Float64, x::NTuple{3, Float64}) = a .* x

scaled(2.0, (1.0, 2.0, 3.0))
```

If some later edit makes it allocate or go unstable, the module won't load at all — the violation
is caught immediately rather than at the next profiling session:

```julia
@strict_function leaky(n::Int) = sum(collect(1:n))   # collect allocates
# ERROR: StrictViolation (@strict_function): call provably allocates …

@strict_function maybe(x::Int) = x > 0 ? x : 1.0     # Union{Int,Float64} return
# ERROR: StrictViolation (@strict_function): return type is not concrete …
```

Signatures with abstract argument types or varargs can't be pinned down statically. Those emit a
one-time warning and fall back to call-site [`@strict`](@ref) checks instead.

## Interfaces + performance with TypeContracts

When you define an interface (an abstract type with a required set of methods), you can also
require that every implementation of it is fast. [`@strict_contract`](@ref) declares the interface
with performance guarantees attached, and [`@verify_strict`](@ref) checks both sides: that an
implementation has the right methods, and that those methods are fast.

```@example guide
using TypeContracts

@strict_contract AbstractMetric begin
    score(::Self, xs::AbstractVector{<:Real})::Real
end
function score end

struct PeakMetric end
score(::PeakMetric, xs::AbstractVector{<:Real}) = @inbounds xs[begin]

m = PeakMetric()
xs = [1.5, 2.5, 3.5]
@verify_strict PeakMetric begin
    score(m, xs)
end
```

An implementation that has the right methods but allocates is turned down:

```julia
struct SlowMetric end
score(::SlowMetric, xs::AbstractVector{<:Real}) = sum(collect(xs))   # allocates

@verify_strict SlowMetric begin
    score(SlowMetric(), [1.0, 2.0, 3.0])
end
# ERROR: StrictViolation (@noalloc): guarantee not satisfied …
```

## `@unroll` — force the fast path

The assert macros tell you after the fact that you boxed. [`@unroll`](@ref) keeps it from
happening in the first place. When a loop's trip count is known at macro time, it unrolls the loop
completely and swaps the loop variable for a literal on each pass, so `t[i]` becomes
`t[1]; t[2]; …`. A heterogeneous tuple then gets indexed type-stably, with no boxing. Unlike the
asserts it isn't gated behind the checks flag; the unrolling always happens.

This is the trap that started the whole project. The naive loop is type-stable, returning a
concrete `Float64`, and it still allocates, because the runtime tuple index boxes. It's the exact
thing `@assert_noalloc` is there to catch:

```@example guide
htup = (1, 2.0, 3.0f0)

function naive(t)
    acc = 0.0
    for i in 1:3
        acc += t[i]          # runtime index over a heterogeneous tuple → boxes
    end
    return acc
end

function unrolled(t)
    acc = 0.0
    @unroll for i in 1:3
        acc += t[i]          # → acc += t[1]; t[2]; t[3]   (literal, no boxing)
    end
    return acc
end

(naive(htup), unrolled(htup), @allocated(naive(htup)), @allocated(unrolled(htup)))
```

Both give the same answer, but only the naive loop allocates, so the guarantee passes for the
unrolled version and not the other:

```@example guide
@assert_noalloc unrolled(htup)
```

```julia
@assert_noalloc naive(htup)
# ERROR: StrictViolation (@noalloc): call provably allocates …
#   [2] Allocating runtime call to "jl_get_nth_field_checked" in ./tuple.jl:33
```

When the size lives only in a type, you can lift it into the type domain with [`staticval`](@ref)
and splice the literal into `@unroll` from a `@generated` method:

```julia
@generated function tuple_sum(t::Tuple)
    N = length(t.parameters)
    quote
        acc = zero(promote_type(t.parameters...))
        @unroll for i in 1:$N        # $N is a literal inside the generated body
            acc += t[i]
        end
        acc
    end
end
```

## GKH ownership — static dispatch over runtime registries

**What it is.** GKH ownership (named for the Greg Kroah-Hartman / Linux-kernel principle that
*data has a clear static owner, reached through that owner — never a global registry*) is the
idiom of giving each concrete type a `const` value, reached by dispatch, instead of storing it in
a runtime-keyed lookup table. The two forms have the same call-site shape (`_ws(Float64)`) but
resolve the association through completely different machinery:

- **Dispatch form:** the mapping `Float64 → _WS_F64` lives in the **method table**. When the
  compiler specializes a caller for `Float64`, method selection happens at *compile time* — there
  is exactly one applicable method, its body is a `const` global read, so the whole call
  const-folds. At runtime there is nothing left: no call, no probe, no branch.
- **Dict form:** the mapping lives in a **runtime data structure**. The type `T` is a value at
  runtime, so `get!` must probe the table — hash (or an identity-scan for `IdDict`) plus a key
  comparison — on *every* call. The compiler cannot fold this away, because a mutable dict's
  contents aren't knowable at compile time.

```julia
# GKH ownership: each type owns a const value, reached by compile-time dispatch.
const _WS_F64 = Workspace{Float64}()
const _WS_F32 = Workspace{Float32}()
_ws(::Type{Float64}) = _WS_F64      # bare dispatch, const-folds — no lookup at all
_ws(::Type{Float32}) = _WS_F32
```

versus the anti-pattern it replaces:

```julia
const _WS = IdDict{Type, Any}()
_ws(::Type{T}) where {T} = get!(() -> Workspace{T}(), _WS, T)   # runtime lookup on every call
```

The smallest possible instance of the pattern, with no domain complexity at all — dispatching on a
type instead of keying a dict by it:

```julia
# anti-pattern
const UNITS = Dict{Type, Any}(Int => 1, Float64 => 1.0)
unit(::Type{T}) where {T} = UNITS[T]        # hash+eq probe every call, returns Any

# GKH ownership
unit(::Type{Int})     = 1                   # method table entry, const-folds
unit(::Type{Float64}) = 1.0
```

(Base's own `one(::Type{T})` works exactly this way — it was never going to be a dict.)

**What problem it solves.** A type/symbol-keyed `Dict`/`IdDict` lookup is often type-stable and
non-allocating on the warm hit — so `@assert_typestable`, `@assert_noalloc`, and
`@assert_noboxing` all pass on it. Nothing else in this package would tell you it's there. But it
still costs a real hash/eq-table probe on every call (measured ~130 ns) — for a hot inner-loop
accessor, that's dozens of FLOPs worth of latency spent fetching a pointer that could have cost
zero. Because it's latency, not allocation or instability, only a benchmark or a structural IR
lint exposes it — and it hides even from IR inspection when `T` is a static parameter, since the
optimizer folds `get!` down to raw `jl_eqtable_*` foreigncalls, erasing the recognizable pattern
from *optimized* IR. (That's why `static_ownership_suggestions` scans *unoptimized* typed IR —
the runtime cost is real, but the source-level pattern is gone by the time optimized IR would show
it.)

**Why it matters for `juliac --trim` and non-allocating code.** `juliac --trim` builds a static
binary by proving every reachable call resolves to a concrete method at compile time, then
discarding everything it can't prove that about. A dispatch-based accessor is trivially provable:
for a concrete call there is exactly one callee, its body is a `const`, and the whole thing inlines
away — nothing dynamic is left to trim. A `Dict` lookup keyed by a `Type` value is resolved by
*value*, at *runtime*: the trimmer can prove which `get!` *method* runs, but never what comes out
of the table, because that association lives in mutable heap memory, not the type system or the
method table. That's exactly the runtime indirection a static build cannot swallow. The same
asymmetry shows up for allocation: the dict's first-miss allocation makes an all-paths allocation
proof see a statically-reachable allocation forever, even though steady state is alloc-free; the
`const`-owner form allocates once at module load, so the hot path is provably allocation-free with
no barriers or exemptions needed.

This is also why StrictMode treats GKH-ownership violations as a *judgment call* rather than a
provable property the way "does this allocate" is: a `Dict` is sometimes exactly the right tool (a
config table parsed once, a genuinely open-ended value-keyed memo cache) — and the pattern's own
sanctioned escape hatch, a `Dict` fallback for a rare-type tail (Example 2 below), is *also* a
runtime dict lookup. A hard gate swept over a whole package would break the build on the very
fallback the idiom recommends.

**Two tools, for two different jobs.** StrictMode gives you a precise tool and a broad one, and
they don't overlap in scope (different guarantee names, no shared registry entry):

| | [`@assert_owned`](@ref) | [`static_ownership_suggestions`](@ref) |
|---|---|---|
| Use it to… | pin a **specific, known-hot** call and guard it forever | **discover** every occurrence across a whole package |
| Failure mode | hard `StrictViolation` — breaks the build | `status = :info` — never a failure, `nfailures` ignores it |
| Where it runs | one call site you write by hand, like [`@assert_inlined`](@ref) | `audit(MyPkg; static_ownership_suggest = true)`, a whole-module/whole-registry sweep |

Reach for `@assert_owned` the same way you'd reach for `@assert_inlined`: on a call you've already
identified as hot and want a permanent regression guard on. Reach for
`static_ownership_suggestions` (or `audit(...; static_ownership_suggest = true)`) when you don't
yet know where the pattern shows up and want a package-wide pass that can't break anything while
you look — the same relationship [`inline_suggestions`](@ref) has to `@assert_inlined`.

**Why `@assert_owned` isn't swept in by default.** Keep it scoped to calls you assert by hand;
don't add it to `register_strict!`'s guarantee list or a `@strict module`'s default set. The
pattern's own sanctioned escape hatch — a `Dict` fallback for a rare-type tail that doesn't earn
its own `const` — is *also* a runtime dict lookup, and a broad sweep would flag (and, since
`@assert_owned` hard-fails, break the build on) the very fallback the idiom recommends. A
narrow, opt-in `@assert_owned` on your known-hot calls avoids that; the advisory sweep is built
for exactly the "show me everywhere, break nothing" case instead.

### Example 1 — the anti-pattern, caught both ways

```@example guide
struct Workspace{T} end
const _WS = IdDict{Type, Any}()
_ws(::Type{T}) where {T} = get!(() -> Workspace{T}(), _WS, T)

only(static_ownership_suggestions(_ws, (Type{Float64},)))    # advisory: an :info finding, not a throw
```

```julia
@assert_owned _ws(Float64) types = (Type{Float64},)
# ERROR: StrictViolation (@owned): guarantee not satisfied
#   target:  _ws(Float64)
#   reason:  hot path resolves a runtime AbstractDict lookup (owned-scratch/GKH violation): …
```

The GKH-dispatch fix satisfies both — `@assert_owned` passes, and the advisory sweep has nothing
left to say:

```@example guide
const _WS_F64 = Workspace{Float64}()
const _WS_F32 = Workspace{Float32}()
_ws2(::Type{Float64}) = _WS_F64
_ws2(::Type{Float32}) = _WS_F32

@assert_owned _ws2(Float64) types = (Type{Float64},)   # passes: dispatch, no lookup
```

```@example guide
static_ownership_suggestions(_ws2, (Type{Float64},))   # empty: nothing left to suggest
```

### Example 2 — whole-package discovery, and the sanctioned fallback

The realistic shape combines dispatch for the hot types with a `Dict` fallback for a rare-type
tail — exactly the case `@assert_owned` would break the build on if swept broadly, and exactly
the case the advisory sweep is built to surface without breaking anything:

```@example guide
module Workspaces
    using StrictMode
    struct Ws{T} end
    const WS_F64 = Ws{Float64}()
    const WS_F32 = Ws{Float32}()
    const WS_FALLBACK = IdDict{Type, Any}()
    get_ws(::Type{Float64}) = WS_F64      # hot path: dispatch, no lookup
    get_ws(::Type{Float32}) = WS_F32      # hot path: dispatch, no lookup
    get_ws(::Type{T}) where {T} = get!(() -> Ws{T}(), WS_FALLBACK, T)   # rare types, off the hot path
end

Workspaces.get_ws(Float64)
Workspaces.get_ws(BigFloat)   # exercises the sanctioned fallback

fs = audit(Workspaces; static_ownership_suggest = true, format = :text)
nfailures(fs)   # 0 — only the fallback is flagged, and an advisory finding never fails a sweep
```

### Example 3 — real packages doing this

This isn't a StrictMode-specific idiom; it's how Julia packages that care about it already solve
the "per-type registry" problem.

**TypeContracts.jl** — a separate interface-contract package. The obvious design for
`@contract AbstractShape begin ... end` is a global `Dict{Type,ContractSpec}` mutated by the macro
and queried by the checker. TypeContracts deliberately has no mutable registry at all: `@contract
I` instead *emits methods* —

```julia
@generated function TypeContracts.interface_trait(::Type{I}, ::Type{T}) where {T}
    return TypeContracts._build_trait_expr(I, T, arg_lists, fns)   # contract data baked in at macro-expansion time
end
```

— plus a `_contract_specs(::Type{I})` method holding the spec. The generic fallback,
`interface_trait(::Type{I}, ::Type{T}) where {I,T} = NotImplemented{I}()`, makes "not registered"
a dispatch outcome too, not a `haskey` branch. The payoff is the GKH list verbatim: method
definitions serialize into the precompile cache and survive package reloads (a dict would be
wiped, needing an `__init__` re-registration step); no world-age problems; and `interface_trait`
is `juliac --trim`-safe precisely because there is no runtime registry lookup for the trimmer to
fail to prove — just ordinary, statically-resolvable methods.

**Julia Base — `IteratorSize`/`IteratorEltype`** (`base/generator.jl`). A textbook per-type trait
registry, shipped as pure dispatch:

```julia
IteratorSize(x) = IteratorSize(typeof(x))
IteratorSize(::Type) = HasLength()                                 # default
IteratorSize(::Type{<:Tuple}) = HasLength()
IteratorSize(::Type{<:AbstractArray{<:Any, N}}) where {N} = HasShape{N}()
```

Packages "register" by defining their own `Base.IteratorSize(::Type{MyIter}) = HasShape{2}()`
method rather than inserting into a table. `IteratorSize(Vector{Int})` const-folds to
`HasShape{1}()`, and `collect`'s dispatch on it specializes completely; a `Dict{Type,...}` version
would put an eqtable probe inside every `collect` call and be opaque to inference.

One caveat so the idiom isn't over-applied: dispatch-per-type means one compiled specialization per
type. For a handful of known-hot types that's the whole point; for an unbounded, genuinely dynamic
key population it's compile-time and method-table bloat instead — the honest answer there is a
`Dict`, or the hybrid fallback shape in Example 2. GKH ownership isn't "never use a `Dict`" — it's
"the hot, statically-known associations belong in the method table, where the compiler can see
them."

## `@assert_memsafe` — deterministic out-of-bounds detection

Every guarantee above is about **speed** — allocation, boxing, dispatch. [`@assert_memsafe`](@ref)
is about **safety**: it catches an out-of-bounds array read or write in an unsafe hand-vectorized
kernel *deterministically*, instead of the way these bugs usually surface — flakily, once in a
long benchmark run, only when the next page happens to be unmapped.

The motivating shape: a masked SIMD load reads a full lane width at a tile pointer, up to `W-1`
elements past a partial-row tile's valid region — via a raw pointer (`unsafe_load`, a
`VecElement`/LLVM-intrinsic vector load, or equivalent), not `getindex`. That kernel is
type-stable, allocation-free, and `--trim`-tolerated — every other guarantee in this package
passes it — because none of them model runtime memory addresses. A benchmark using ordinary heap
arrays (whose trailing page happens to be mapped) may never trip it at all.

```julia
function masked_load_kernel!(out::Vector{Float64}, a::Vector{Float64})
    n = length(a)
    p = pointer(a)
    @inbounds for i in 1:n
        out[i] = a[i] + unsafe_load(p, i + 1)   # raw-pointer read one element past `a`'s end
    end
    return nothing
end

@assert_memsafe masked_load_kernel!(zeros(8), rand(8))
# ERROR: StrictViolation (@memsafe): guarantee not satisfied
#   reason:  deterministic out-of-bounds access — the guarded probe subprocess was killed by
#            SIGSEGV. Child's own signal report (names the faulting op): …
```

**Why not just `julia --check-bounds=yes`?** That flag forces Julia's own bounds check even inside
`@inbounds` blocks, turning a plain `@inbounds a[i]` overrun into a catchable `BoundsError` — for
*that* bug shape it's simpler than this whole harness, and you don't need `@assert_memsafe` for it
(a `@test_throws BoundsError` run under the flag is enough). But `--check-bounds` only re-enables
the bounds branch inside `getindex`/`setindex!`/`checkbounds` lowering — it has **no effect at
all** on `unsafe_load`/`unsafe_store!`, raw `Ptr` arithmetic, or SIMD-intrinsic vector loads,
because those never go through `checkbounds` in the first place (confirmed at both the runtime and
`@code_llvm` level: `getindex` compiles a bounds branch, `unsafe_load` compiles none). That's
exactly the access pattern the motivating bug above uses, and exactly why `@assert_memsafe` exists
as a distinct tool rather than a wrapper around a compiler flag: it catches the class of
out-of-bounds access that is invisible to `--check-bounds` by construction, not the class that
flag already handles.

Mechanically: `Array` arguments are copied into `mmap`-backed buffers whose data ends flush
against a trailing `PROT_NONE` guard page, so a one-element overrun faults on *every* run, not
just when a real allocation happens to leave the trailing page unmapped. The default
`isolate=true` runs the probe in a subprocess — the only way to catch an out-of-bounds *read*,
since that's a fatal, otherwise-uncatchable `SIGSEGV` (verified: an out-of-bounds write against the
guard page converts to a catchable `ReadOnlyMemoryError` in-process, but an out-of-bounds read
kills the process outright, exit via signal, nothing to catch); `isolate=false` is a cheaper
in-process check that only catches out-of-bounds *writes*. See [`memsafe_report`](@ref)'s
docstring for the full scope (Linux/macOS only, `Array` arguments only, end-of-buffer overruns
only — no interior or underrun detection).

## Promise scope

StrictMode's guarantees cover **allocation-freedom**, **type-stability**, **vectorization**
(where asserted with [`@assert_vectorized`](@ref) or [`@kernel`](@ref)), **register pressure**
(via [`@assert_no_spill`](@ref)), **static-binary (`juliac --trim`) compatibility** (via
[`@assert_trim_compatible`](@ref)), and, deterministically rather than flakily, **out-of-bounds
array access** in unsafe kernels (via [`@assert_memsafe`](@ref)). One property is explicitly out
of scope: **bit-reproducibility**.

SIMD reduction order is LLVM-codegen-defined. The lane-combine order for a vector reduction —
for example, how four `<4 x double>` lanes are collapsed to a scalar — is chosen by the compiler
and may differ from a reference implementation, even when both produce IEEE-correct results. A
~1-ULP difference between your kernel and a Rust or C reference is expected behavior and is *not*
a StrictMode failure.

If you are testing numerical correctness against a reference, use tolerance-aware comparisons for
SIMD reductions. Exact matching remains valid for deterministic operations (non-reduction
arithmetic, memory copies, index computations). See also [the golden-harness methodology](cookbook.md)
in the cookbook for a practical port workflow.

## `@explain` — tell me *why*

When an assert fails, you usually want to know why, not just that it did. [`@explain`](@ref)
gathers `@code_warntype`, JET's `@report_opt`, and AllocCheck into a single [`StrictReport`](@ref),
and unlike the asserts it never throws. It just returns the report, which the REPL prints for you;
assign it if you want to poke at the individual fields.

A clean call comes back all green:

```@example guide
clean(a, b) = 0.5a + 0.5b

@explain clean(2.0, 4.0)
```

And the runtime tuple-index trap gets pulled apart: the non-concrete return type, the boxing
allocation site, the `@code_warntype` body, and a verdict for each guarantee:

```julia
state = (1, 2.0, "three")
component(s, i) = s[i]

@explain component(state, rand(1:3))
# StrictMode @explain — component(state, rand(1:3))
#
#   Return type:    Union{Float64, Int64, String}  ✗ not concrete
#   Allocations:    ✗ 1 site(s) (AllocCheck):
#     [1] Allocating runtime call to "jl_get_nth_field_checked" in ./tuple.jl:33 …
#
#   Verdict:
#     ✗ @assert_typestable would fail
#     ✗ @assert_noalloc would fail
```
