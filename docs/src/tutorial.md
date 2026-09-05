# Tutorial: from slow to strict

This walks through the full StrictMode workflow on a concrete example. By the end, a numeric
kernel goes from "works correctly" to "guaranteed fast and regression-proof."

Assumes checks are enabled — see [Getting Started](getting_started.md) if not.

## If you're coming from C, C++, or Java

In C++ or Java, types are part of the code — the compiler enforces them and won't let you
confuse an `int` with a `std::string`. But the compiler won't tell you if a function
unexpectedly allocates on the heap, fails to devirtualize a virtual call, or produces scalar
code where you expected SIMD. You find those out from a profiler, after the fact.

`@strict_function` fills that gap: it checks "concrete return type, no heap allocation" against the
declared argument types at precompile time, rather than leaving both to a profiler three days later.
It is closer to a compile-time performance sanitizer than to a type declaration. The return type is
settled there and then — a violation stops the module loading — while the allocation half warns and
is proved from your test suite, for reasons the regression section below makes concrete.

The failures you'll see in this tutorial — boxing and type instability — are equivalent to Java
autoboxing (`int` silently promoted to `Integer`) or a missed devirtualization in C++. The
difference is that in Julia these happen silently without any source-level change, which is what
makes them easy to miss. StrictMode makes them loud.

## If you're coming from Python or MATLAB

The thing to keep in mind: Julia compiles your code to native machine instructions, the same
kind NumPy dispatches to BLAS for. When a Julia function is type-stable, the JIT produces code
as fast as pre-compiled C. When it isn't, it silently falls back to something as slow as a
Python loop — and the source code looks identical either way.

This tutorial demonstrates how StrictMode tells you which path you're actually on, and how to
lock in the fast path so a future edit can't silently knock you back to the slow one.

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

This definition loads cleanly. A later edit that makes the return type inconcrete stops the enclosing
module loading — before any tests run, and before anything else uses the function:

```julia
@strict_function widened(x::Int) = x > 0 ? x : 1.0
# ERROR: StrictViolation (@strict_function): return type is not concrete for (Int64): Union{Float64, Int64}
```

## Simulating a regression

Three months later, someone refactors `dot3_locked` for readability:

```julia
# Proposed change: a generator, for "clarity"
@strict_function dot3_locked(a::NTuple{3,Float64}, b::NTuple{3,Float64}) =
    sum(a[i]*b[i] for i in 1:3)
```

The generator allocates a temporary. Loading this **warns** rather than failing:

```
┌ Warning: @strict_function dot3_locked(NTuple{3,Float64}, NTuple{3,Float64}): allocates / boxes
│ (value-free IR scan — a structural guess, not a proof; add StrictModeTest to your test
│ environment and call test_registered() to resolve it)
```

That is deliberate, and it is worth understanding before you rely on this macro. The check runs at
your package's own precompile, where the proof cannot be loaded — AllocCheck lives in
`StrictModeTest`, a test-environment dependency. What is left is a scan of typed IR, which still
sees allocations LLVM later deletes, so it guesses. A guess must not be able to stop a package
installing.

The declaration is registered either way, which is what makes the warning actionable. From your test
suite, where the proof *is* available, one call re-proves every `@strict_function` in the package
and throws on this one:

```julia
using StrictMode, StrictModeTest
test_registered()      # re-proves each declaration against AllocCheck and JET
```

So the regression is caught at load as a warning and in CI as a failure — the type-stability half at
load, the allocation half in the test suite.

## Diagnosing a failure

When a guarantee fails on more complex code, `@explain` gives the full picture without
throwing — it runs all the checks and explains each verdict:

```julia
@explain dot3_candidate(a, b)
```

The report collects `@code_warntype`, the inferred return type, and the typed-IR allocation and
dispatch signals into one place. Use it to find the allocation site before trying to fix it.

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

Add `StrictModeTest` to your **test** environment and gate on an explicit signature list — no
call-site annotation needed anywhere:

```julia
# test/Project.toml:  [deps] StrictMode, StrictModeTest
using StrictMode, StrictModeTest

# In your test file — throws a StrictViolation naming every failure:
test_signatures([(dot3_locked, (NTuple{3,Float64}, NTuple{3,Float64}))])
```

Or gate everything the module actually compiled:

```julia
test_compiled(MyModule)
```

Note which package each name comes from: the `test_*` drivers run AllocCheck, JET and TrimCheck,
and they **throw**. `StrictMode`'s own `audit(MyModule)` covers the same scope with the value-free
scan and only reports — reach for it while you iterate, not as the gate.

See [Automating checks](automating.md) for the full sweep options.
