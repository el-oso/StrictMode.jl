# Getting Started

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/el-oso/StrictMode.jl")
```

## Enable the checks

Every guarantee is gated behind a [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl)
compile-time flag. It is **off by default**, so a production build pays nothing — the macros
expand to the bare call. Turn the checks on in development / CI:

```julia
using StrictMode

StrictMode.enable_checks!()    # writes LocalPreferences.toml; restart Julia to apply
# ... develop with guarantees active ...
StrictMode.disable_checks!()   # back to the production default
```

You can choose whether a violation throws or just warns:

```julia
StrictMode.enable_checks!(fail_mode = "warn")   # log violations instead of throwing
```

Check the current state at any time:

```@example gs
using StrictMode
StrictMode.checks_enabled(), StrictMode.fail_mode()
```

(This documentation is built with checks **enabled**, so every live example below really runs
the analysis.)

## Your first guarantee

Assert that a call is allocation-free. The macro evaluates to the call's value, so you can wrap
an expression transparently:

```@example gs
square_sum(xs) = sum(x -> x^2, xs)

@assert_noalloc square_sum((1.0, 2.0, 3.0))
```

Assert that a call is type stable:

```@example gs
affine(x) = 2x + 1
@assert_typestable affine(3.0)
```

Or assert everything at once with [`@strict`](@ref):

```@example gs
weighted(a, b) = 0.5a + 0.5b
y = @strict weighted(2.0, 4.0)
```

## When a guarantee fails

A failing guarantee throws a [`StrictViolation`](@ref) (in the default `:error` mode) that names
the offending call and the reason. For example, indexing a heterogeneous tuple with a runtime
value yields a `Union` return type and silently boxes — StrictMode makes that loud:

```julia
state = (1, 2.0, "three")
component(s, i) = s[i]

@assert_typestable component(state, rand(1:3))
# ERROR: StrictViolation (@typestable): guarantee not satisfied
#   target:  component(state, rand(1:3))
#   reason:  return type is not concretely inferrable: ... Union{Int64, Float64, String}
```

## Zero cost when disabled

When checks are off, the macro expands to *exactly* the bare call — there is nothing left to
pay for at runtime:

```julia
# checks OFF
@macroexpand @assert_noalloc f(x)   #  ->  :(f(x))
```

Next: the [Guarantees](guarantees.md) guide walks through every macro with runnable examples.
