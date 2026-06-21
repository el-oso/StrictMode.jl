# Guarantees

Every example on this page is **live** — the documentation is built with checks enabled, so the
analysis actually runs. Passing calls are shown as executed `@example` blocks; failing calls are
shown as annotated code so the docs build stays green.

```@example guide
using StrictMode
```

## `@assert_noalloc` — no heap allocations

StrictMode asks [AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl) to *prove* the call
cannot allocate. Dynamic dispatch and boxing count as allocations, so they are caught here too.

```@example guide
dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]

@assert_noalloc dot3((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
```

If static analysis cannot run on a call, pass `static = false` to measure empirically with
`@allocated` after a warmup:

```julia
@assert_noalloc static = false stream_step!(buffer, x)   # measures @allocated, not a static proof
```

An **allocating hot loop** is rejected:

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

## `@assert_typestable` — concrete, stable types

Combines `Test.@inferred` (the *return* type must be concrete) with `JET.@report_opt` (no
*internal* instability or runtime dispatch).

```@example guide
affine(x) = 2x + 1

@assert_typestable affine(3.0)
```

The classic trap — **runtime tuple indexing** — produces a `Union` return type and boxes. It is
rejected:

```julia
state = (1, 2.0, "three")     # heterogeneous tuple
component(s, i) = s[i]        # i is a runtime value → Union{Int,Float64,String}

@assert_typestable component(state, rand(1:3))
# ERROR: StrictViolation (@typestable): guarantee not satisfied
#   target:  component(state, rand(1:3))
#   reason:  return type is not concretely inferrable: …
```

## `@strict` — every per-call guarantee at once

[`@strict`](@ref) checks type stability first (the usual root cause of surprise allocations),
then allocation-freedom. It evaluates to the call's value, so it is a drop-in wrapper:

```@example guide
saxpy(a, x, y) = a .* x .+ y

result = @strict saxpy(2.0, (1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
```

## `@strict_function` — verify a definition at load time

Annotate a definition and StrictMode verifies its contract against the **declared argument
types** at precompile / module-load time. A clean definition loads normally:

```@example guide
@strict_function scaled(a::Float64, x::NTuple{3, Float64}) = a .* x

scaled(2.0, (1.0, 2.0, 3.0))
```

If a later edit makes it allocate or go unstable, the **module fails to load** — the same
forcing function Rust's compiler gives you:

```julia
@strict_function leaky(n::Int) = sum(collect(1:n))   # collect allocates
# ERROR: StrictViolation (@strict_function): call provably allocates …

@strict_function maybe(x::Int) = x > 0 ? x : 1.0     # Union{Int,Float64} return
# ERROR: StrictViolation (@strict_function): return type is not concrete …
```

Signatures with abstract argument types or varargs cannot be checked statically; they emit a
one-time warning and are left to call-site [`@strict`](@ref) checks.

## Interfaces + performance with TypeContracts

[`@strict_contract`](@ref) declares a [TypeContracts.jl](https://github.com/el-oso/TypeContracts)
interface that carries performance guarantees, and [`@verify_strict`](@ref) checks an
implementation's *method surface* **and** that those methods are *fast*.

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

An implementation that satisfies the interface but **allocates** is rejected:

```julia
struct SlowMetric end
score(::SlowMetric, xs::AbstractVector{<:Real}) = sum(collect(xs))   # allocates

@verify_strict SlowMetric begin
    score(SlowMetric(), [1.0, 2.0, 3.0])
end
# ERROR: StrictViolation (@noalloc): guarantee not satisfied …
```

## `@explain` — tell me *why*

When an assert fails you often want the diagnosis, not just the verdict. [`@explain`](@ref)
aggregates `@code_warntype`, JET `@report_opt` and AllocCheck into one [`StrictReport`](@ref) —
and, unlike the asserts, it never throws. It returns the report (the REPL prints it); assign it
to inspect the fields.

A clean call reports all green:

```@example guide
clean(a, b) = 0.5a + 0.5b

@explain clean(2.0, 4.0)
```

The runtime tuple-index trap is dissected — non-concrete return type, the boxing allocation
site, and the `@code_warntype` body — with a verdict for each guarantee:

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
