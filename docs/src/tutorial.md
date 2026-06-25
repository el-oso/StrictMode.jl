# Tutorial: from slow to strict

This walks through the full StrictMode workflow on a concrete example. By the end, a numeric
kernel goes from "works correctly" to "guaranteed fast and regression-proof."

Assumes checks are enabled — see [Getting Started](getting_started.md) if not.

## The starting point

A dot product over a fixed-size tuple:

```@example tut
using StrictMode

dot3(a::NTuple{3,Float64}, b::NTuple{3,Float64}) =
    a[1]*b[1] + a[2]*b[2] + a[3]*b[3]

a = (1.0, 2.0, 3.0)
b = (4.0, 5.0, 6.0)
dot3(a, b)
```

Clean, correct, fast. Now ask StrictMode to verify the fast-path properties:

```@example tut
@strict dot3(a, b)
```

All three guarantees pass (type-stable, allocation-free). Good.

## Lock it in

A call-site check only covers that one call. To make the guarantee permanent — enforced at
precompile time against the declared types — use `@strict_function`:

```@example tut
@strict_function dot3_locked(a::NTuple{3,Float64}, b::NTuple{3,Float64}) =
    a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
```

This definition loads cleanly. If the body violates the guarantee, the enclosing module fails
to load — before any tests run and before anything else uses the function.

## Simulating a regression

Three months later, someone refactors `dot3_locked` for readability:

```julia
# Proposed change: use a loop + collect for "clarity"
@strict_function dot3_locked(a::NTuple{3,Float64}, b::NTuple{3,Float64}) =
    sum(a[i]*b[i] for i in 1:3)
```

The generator expression `a[i]*b[i] for i in 1:3` allocates a temporary. If you load this
definition with checks enabled, you get:

```
ERROR: StrictViolation (@noalloc): guarantee not satisfied
  target:  dot3_locked(NTuple{3,Float64}, NTuple{3,Float64})
  reason:  allocates (1 site(s))
```

Caught at load time instead of at the next profiling session.

## Diagnosing a failure

When a guarantee fails on more complex code, `@explain` gives the full picture without
throwing — it runs all the checks and explains each verdict:

```julia
@explain dot3_candidate(a, b)
```

The report collects `@code_warntype`, JET analysis, and AllocCheck into one place. Use it to
find the allocation site before trying to fix it.

## A realistic trap: runtime tuple indexing

`dot3` above uses literal indices, which is why it's stable. The common mistake is switching
to a loop:

```julia
function dot3_loop(a::NTuple{3,Float64}, b::NTuple{3,Float64})
    s = 0.0
    for i in 1:3
        s += a[i] * b[i]   # still fine — NTuple is homogeneous
    end
    s
end
```

This is still fine for a *homogeneous* `NTuple{3,Float64}`. The trap strikes with a
**heterogeneous** tuple:

```julia
function weighted_sum(weights, values)
    s = 0.0
    for i in 1:3
        s += weights[i] * values[i]   # values[i] is Union{...} if types differ → boxes
    end
    s
end

mixed = (1, 2.0, 3.0f0)   # Tuple{Int64, Float64, Float32}
@strict weighted_sum((1.0, 0.5, 0.25), mixed)
# ERROR: StrictViolation — type instability / boxing
```

`@explain weighted_sum((1.0, 0.5, 0.25), mixed)` will point at `values[i]` as the source.
The fix: `@unroll` replaces the runtime index with compile-time literals, making each access
a known concrete type:

```julia
function weighted_sum(weights, values)
    s = 0.0
    @unroll for i in 1:3
        s += weights[i] * values[i]   # expands to i=1, i=2, i=3 — each concrete
    end
    s
end

@strict weighted_sum((1.0, 0.5, 0.25), mixed)   # passes
```

See [Avoiding boxing](api.md#avoiding-boxing) in the API reference for `@unroll` and
`staticval`.

## CI enforcement

Add a programmatic check to your test suite so CI catches regressions without any call-site
annotation:

```julia
using StrictMode, AllocCheck, JET

# In your test file:
fs = check(dot3_locked, (NTuple{3,Float64}, NTuple{3,Float64}))
@test nfailures(fs) == 0
```

Or sweep everything the module has registered at once:

```julia
fs = audit(MyModule)
@test nfailures(fs) == 0
```

See [Automating checks](automating.md) for the full sweep options.
