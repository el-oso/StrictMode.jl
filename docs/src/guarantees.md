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

## `@assert_noalloc` / `@test_noalloc` — no heap allocations

`@assert_noalloc` scans the call's typed IR for allocation sites. Dynamic dispatch and boxing both
show up as allocations, so they get caught here as well.

```@example guide
dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]

@assert_noalloc dot3((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
```

`static = false` measures the call directly with `@allocated` after a warmup pass instead — a
value-dependent measurement of what actually ran, rather than a signature-level verdict:

```julia
@assert_noalloc static = false stream_step!(buffer, x)
```

An allocating hot loop gets reported:

```julia
function grow_and_sum(n)
    v = Int[]              # allocates
    for i in 1:n
        push!(v, i)        # …and grows
    end
    return sum(v)
end

@assert_noalloc grow_and_sum(10)
# ┌ Warning: StrictViolation (@noalloc): guarantee not satisfied
# │   target:  grow_and_sum(10)
# │   reason:  allocates / boxes (value-free IR scan) …
# └   note:    StrictMode's `@assert_noalloc` check is a heuristic, so it reports rather than
#              gating. Add StrictModeTest and use `@test_noalloc` for the proof.
```

**Reported, not thrown** — see [Why `@assert_noalloc` reports instead of
gating](#Why-@assert_noalloc-reports-instead-of-gating) below. The proof is
`StrictModeTest`'s `@test_noalloc`, which hands the call to
[AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl) and asks it to prove there is no way the
call can allocate, on any path:

```julia
using StrictMode, StrictModeTest        # test/Project.toml
@test_noalloc grow_and_sum(10)
# ERROR: StrictViolation (@noalloc): guarantee not satisfied
#   reason:  allocates (… site(s)) …
```

### One-time-init calibration doesn't have to break this

A `Base.OncePerProcess`/`OncePerThread`-memoized lazy calibration allocates once, then reads a
memoized value forever after — but AllocCheck's all-paths proof sees the initializer's one-time
allocation as statically reachable and would otherwise red a call that's provably alloc-free in
steady state. The IR scan recognizes the two `Base` once-guard types automatically and stops at
them, and `@test_noalloc`/`@test_noboxing` honor that: on a call whose ONLY allocation risk is the
barrier they substitute the (already-correct) steady-state scan for AllocCheck's all-paths proof,
rather than reporting the cold-path allocation as a violation — logged once per session via
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


### Why `@assert_noalloc` reports instead of gating

The scan reads **typed IR**. AllocCheck reads **LLVM IR**, after the optimizer has run. Anything
LLVM deletes in between is still visible to the scan and already gone for the proof:

```text
  your code  →  typed IR  →  LLVM optimizes  →  LLVM IR  →  machine code
                   ↑                              ↑
              the scan reads here            AllocCheck reads here
              sees the allocation            it has been deleted
```

```julia
mkvec(n::Int) = length(Vector{Float64}(undef, n))
@allocated mkvec(4)     # => 0   — the array is never materialized
```

The scan flags it, AllocCheck does not, and the truth is 0 bytes. Measured over 120 compiled
specializations from two real packages, 8.1% of the scan's findings were false this way.

So these **warn** instead of throwing. It matters most at load time: [`@strict_function`](@ref) runs
during your package's own precompile, where `StrictModeTest` cannot be loaded — it belongs to
`test/`. A guess there would stop a consumer's package installing over code that may be perfectly
clean.

The declaration is registered either way, so the proof still gets its turn:

```julia
using StrictMode, StrictModeTest     # in test/
@test_noalloc kernel!(C, A, B)       # AllocCheck's all-paths proof — throws
test_registered()                    # …or re-prove everything that was declared
```

Guarantees whose check *observes* compiled output rather than inferring about it — `:typestable`'s
return-type layer, `:memsafe`, `:vectorized`, `:no_spill`, `:inlined`, `:owned` — throw from
StrictMode directly. The ones that guess (`:noalloc`, `:noboxing`, `:no_scalar_loops`,
`:trimsafe`/`:trim_compatible`, and both of `:typestable`'s IR signals — internal dispatch and the
union-typed local) report.

## `@assert_noboxing` / `@test_noboxing` — forbid boxing, allow buffers

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
# ┌ Warning: StrictViolation (@noalloc): allocates / boxes … Vector{Float64} …
@test_noalloc fill_sum(3)
# ERROR: StrictViolation (@noalloc): allocates (1 site(s)) …
```

Boxing and dynamic dispatch, though, are still out:

```julia
boxy(t) = (s = 0.0; for i in 1:3; s += t[i]; end; s)   # heterogeneous tuple, runtime index
@assert_noboxing boxy((1, 2.0, 3.0f0))
# ┌ Warning: StrictViolation (@noboxing): boxing / dynamic dispatch (value-free IR scan)
```

Classifying an allocation as *boxing* specifically is what AllocCheck does exactly, so
`@test_noboxing` is where the distinction is proved — the scan treats an abstract-eltype container
as boxing, which is a code smell rather than a boxing proof.

## `@assert_typestable` / `@test_typestable` — concrete, stable types

Three layers, graded differently. `@assert_typestable` insists the return type is concrete — exact
for the question it asks, so a violation **throws**. On top of that it adds two IR signals, both
heuristics and so both only **warning**: internal dispatch hiding behind a concrete return, and a
union-typed local carrying a member that must be boxed to flow through it.

`@test_typestable` replaces the dispatch signal with `JET.@report_opt` and throws on it. It keeps
the union-typed-local signal as it is, because JET cannot see that class at all — union splitting is
not dynamic dispatch, so `@report_opt` is silent on it at every signature. Without it the proof
would be weaker than the scan it is meant to settle.

### A union-typed local that boxes

A non-isbits union is a tagged pointer, so a member that normally lives unboxed has to be heap-boxed
to flow through it. Member count is not what decides this; representation is. An isbits member rides
the union's inline payload and a mutable one is already a pointer, but an immutable struct holding
heap references — `SubArray`, `Adjoint`, `Transpose` — is boxed on the way in.

```julia
function through_union(A::AbstractMatrix{Float64}, take::Bool)
    local x = take ? view(A, :, 1:1) : A   # Union{SubArray, Matrix}: the SubArray boxes, the Matrix does not
    s = 0.0
    for i in eachindex(x)
        s += @inbounds x[i]
    end
    return s
 end
```

The return type here is `Float64` — concrete — so the first layer sees nothing, and the box leaves
no `:new` and no allocating `foreigncall` in optimized IR, so the allocation scan sees nothing
either. Its only trace is the phi's own type.

This rides `:typestable` rather than `:noalloc` deliberately. "This local is union-typed with a
box-on-entry member" is a property of the code as written; whether the box survives is LLVM's call
and moves with inlining — the same function measures 16 B per call across a module boundary and 0 B
once it inlines into its caller. Reporting it as an allocation would red kernels LLVM made free.

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

**Keyword arguments.** A keyword call is checked as written — StrictMode routes it through
`Core.kwcall`, so inference, AllocCheck and JET all see the keyword sorter's real specialization.
That holds under a `types = (…)` override too: the override pins the POSITIONAL types and the
kwcall wrapper is kept, so the analyzed signature stays the one the call actually reaches.

```julia
@assert_noalloc    trsm!(B, A; side='L', uplo='L', alpha=1.0)   # public kwarg entry point
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

[`@assert_trim_compatible`](@ref) reports when `f(args...)` looks incompatible with
`juliac --trim=safe`, the static-binary build mode that rejects dynamic dispatch and reflection. It
is a value-free scan of the typed IR: unresolved dynamic calls, reflection, and calls left
unresolved by exceeding the union-split limit.

The authoritative answer is a different macro, not a different mode. `StrictModeTest`'s
`@test_trim_compatible` runs juliac's own `verify_typeinf_trim` over the exact signature and
**throws**, with deduplicated, source-mapped findings. Nothing switches based on which packages
happen to be loaded — the macro you wrote decides.

Like `@assert_inlined`, this is advisory and **opt-in** — *not* part of [`@strict`](@ref): juliac's
whole-program verifier over the real build is the final word. [`@assert_trim_safe`](@ref) is the
same scan under a name that says "static only". The reactive counterpart, for a real build log, is
[`explain_trim`](@ref).

```julia
clean(x::Int) = x * 2 + 1
@assert_trim_compatible clean(3)          # ok

reflecty(x::Int) = length(Base.return_types(sin, (Float64,)))   # reflection → trim-unsafe
@assert_trim_compatible reflecty(3)
# ┌ Warning: StrictViolation (@trim_compatible): likely trim-incompatible (static scan —
# │ `@test_trim_compatible` runs the authoritative juliac verifier):
# │   Base.indexed_iterate(…)::Any  [myfile.jl:NN]; … (+N more call site(s))
```

As an engine guarantee it is `:trim_compatible` (with `:trimsafe` the static subset):

```julia
findings(reflecty, (Int,); guarantees = (:trim_compatible,))     # report
test_signatures([(reflecty, (Int,))]; guarantees = (:trim_compatible,))   # prove (StrictModeTest)
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

### When the declaration names no concrete types

A generic declaration cannot be checked as written. Inference has nothing to work with:

```@example guide
pick(t::Tuple, i::Int) = t[i]
Base.return_types(pick, Tuple{Tuple, Int})
```

`Any` — so verifying the declared signature directly would fail every generic function ever written.
That is why such a definition is skipped with a warning rather than checked. The same function is
perfectly answerable once you fix the tuple type, and the answer differs per instantiation:

```@example guide
[Base.return_types(pick, Tuple{T, Int}) for T in
    (NTuple{3, Float64}, Tuple{Int, Float64}, Tuple{Float64, String})]
```

Two ways to get an answer anyway, differing in who names the instantiations and when the verdict
forms.

**Name them yourself, still at load** — `signatures = [...]` verifies each listed instantiation
exactly as a concrete declaration is verified, so a violation still stops the module loading:

```julia
sigs = [(NTuple{3,Float64}, Int), (Tuple{Float64,String}, Int)]
@strict_function signatures = sigs pick(t::Tuple, i::Int) = t[i]
# the second entry infers Union{Float64,String}, so the module fails to load
```

**Or check whatever callers create** — [`@strict_stable`](@ref) moves the body into a hidden inner
function and has the public one infer its return type. That inference is a compile-time constant, so
a stable specialization compiles to exactly the code the unannotated definition would, and an
unstable one throws as it is compiled:

```@example guide
@strict_stable spick(t::Tuple, i::Int) = t[i]
spick((1.0, 2.0, 3.0), 2)      # stable: no check survives in the compiled code
```

```julia
spick((1.0, "a"), 2)           # Union{Float64,String}
# ERROR: StrictViolation (@typestable): return type is not concrete for this specialization …
```

The trade is real and worth stating: `@strict_stable` forms its verdict per specialization rather
than once at load, and inference is not stable under an open world — a definition that loaded clean
can begin to throw after unrelated code changes what inference can prove. Reach for `signatures`
when the contract is a fixed set of types you own; reach for `@strict_stable` for an entry point
whose callers pick the types. Only type stability travels this way: allocation and vectorization are
read from compiled output.

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

Give each type a `const` value reached by dispatch, instead of looking it up in a dict at runtime.
The name comes from the Linux-kernel principle that *data has a clear static owner, reached through
that owner — never a global registry*.

Both forms look identical at the call site (`_ws(Float64)`). They resolve through completely
different machinery:

```text
  _ws(Float64)                       _ws(Float64)
       │                                  │
  ┌────┴─────────────┐              ┌─────┴──────────────┐
  │  METHOD TABLE    │              │  IdDict at runtime │
  │  one applicable  │              │  hash the key      │
  │  method, body is │              │  probe the table   │
  │  a const read    │              │  compare, return   │
  └────┬─────────────┘              └─────┬──────────────┘
       │ compile time                     │ every single call
       ↓                                  ↓
   nothing left:                     a probe, a branch,
   the call is gone                  a result typed Any
```

The dispatch form const-folds because there is exactly one applicable method and its body is a
`const` read — by runtime the call has disappeared. The dict form cannot fold: `T` is a value at
runtime and a mutable dict's contents are not knowable at compile time.

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
**What problem it solves.** A type/symbol-keyed `Dict`/`IdDict` lookup is often non-allocating on
the warm hit (measured: 0 bytes) — and when its result is narrowed, by a type assert or a
concretely-typed dict, `@assert_typestable`, `@assert_noalloc` and `@assert_noboxing` all pass on
it. Nothing else in this package would tell you it's there. (The bare form above is *not* narrowed:
`UNITS[T]` on an `IdDict{Type,Any}` infers to `Any`, so it fails all three on the return type alone
— narrow it with `::T` and the guarantees go quiet while the probe remains.) But it
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
against a trailing `PROT_NONE` guard region, so a one-element overrun faults on *every* run, not
just when a real allocation happens to leave the trailing page unmapped. The probe runs in a
subprocess — the only way to catch an out-of-bounds *read*, since that is a fatal,
otherwise-uncatchable `SIGSEGV`. Classification of a write is done by a **poisoned canary**: the
bytes past the data are filled with a per-buffer, position-dependent pattern and read back before
the child touches the guard pages, so a store past the end is reported with its exact offset. That
is necessary because a guard-page write fault is fatal and its backtrace is destroyed (`unknown
function (ip: …)`, zero frames), so nothing can be recovered from the fault itself. Argument
positions holding the same array share one guarded buffer, so a kernel with an aliasing-dependent
path sees the aliasing it was called with.

There is no in-process mode: an in-process probe can only use the canary, and a load past the end
disturbs no canary, so its clean verdict would be indistinguishable from no overrun at all — in
exactly the case this harness exists for.

See [`memsafe_report`](@ref)'s docstring for the full scope (Linux/macOS only, `Array` arguments
only, end-of-buffer overruns only — no interior or underrun detection). Arguments the harness
cannot guard — a `view`, an `Adjoint`, a struct carrying arrays in its fields — are listed in the
report's `unguarded` field, so a clean verdict over a partially covered call does not read like a
clean verdict over a fully covered one; [`@assert_memsafe`](@ref) rejects the ones the caller can
materialize outright.

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

When a guarantee reports a violation, you usually want to know why, not just that it did.
[`@explain`](@ref) gathers `@code_warntype`, the inferred return type, and the typed-IR allocation
and dispatch signals into a single [`StrictReport`](@ref), and unlike the asserts it never throws.
It just returns the report, which the REPL prints for you; assign it if you want to poke at the
individual fields.

It runs the value-free engine, so its allocation verdict is the same structural guess
`@assert_noalloc` makes — for the proved answer, `StrictModeTest`'s `@test_noalloc` /
`@test_typestable` analyze the same call.

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
#   Local dispatch: ✗ this function's own IR dispatches dynamically
#   IR signals:     ✗ boxing / dynamic dispatch
#                   at ./tuple.jl:33
#
#   Verdict:
#     ✗ @assert_typestable would fail
#     ✗ @assert_noalloc would fail
```
