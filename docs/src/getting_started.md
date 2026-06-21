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

StrictMode.enable_checks!()    # writes the preference; **restart Julia** to apply
# ... develop with guarantees active ...
StrictMode.disable_checks!()   # back to the production default
```

!!! note "The gate is compile-time"
    `enable_checks!` only writes a preference — it does **not** affect the current session
    (`checks_enabled()` stays `false` until you restart), so an enable-then-assert script in one
    process silently checks nothing. To commit the setting for a package's dev/CI runs, add it to
    the project's `Project.toml` (committed by default):

    ```toml
    [preferences.StrictMode]
    checks_enabled = true
    fail_mode = "error"
    ```

    (a `LocalPreferences.toml` next to `Project.toml` works too). Then run tests in a fresh
    process — see the testing pattern below.

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

## What the checks cost when enabled

JET and AllocCheck are heavyweight analyzers, so it's worth knowing where the time goes:

- **Checks off (production):** nothing. The macros are bare calls and the analyzers are never
  compiled in. Precompiling StrictMode stays fast (~3 s here).
- **Checks on (dev / CI):** the analyzers are warmed into StrictMode's precompiled image by a
  `PrecompileTools` workload, so the one-time analyzer-compilation cost (~10–20 s) is paid
  **once at precompile** (install / CI), not on your first interactive call. After that, the
  first `@explain`/`@strict` in a session is ~0.1 s, and warm per-call analysis on a small
  kernel is single-digit-to-tens of milliseconds.

In other words: the cost is a one-time precompile, not a per-call tax, and an edit–rerun loop
(Revise) keeps the analyzer image warm across edits. Warm cost does scale with call-graph size,
so these are best aimed at small hot kernels — exactly where the silent traps bite.

### `:full` vs `:fast` analysis

If even the warm per-call cost is too much (e.g. a large function in a tight loop), switch the
per-call asserts to cheap inference-only checks:

```julia
StrictMode.enable_checks!(analysis = "fast")   # default is "full"
```

| Mode | Type stability | No-allocation | Warm cost |
|---|---|---|---|
| `:full` (default) | JET `@report_opt` + `@inferred` | AllocCheck static **proof** | tens of ms |
| `:fast` | `Base.return_types` concreteness | empirical `@allocated` | sub-ms |

`:fast` trades rigor for speed: it catches the common cases (non-concrete return, allocations on
the measured path) but can miss internal-dispatch-with-concrete-return that `:full` proves, and
its `@allocated` measurement reflects the call *in context* (e.g. reading a non-`const` global
will register as an allocation). [`@explain`](@ref) and [`@strict_function`](@ref) always use
the full analysis. A good split: `:fast` while iterating, `:full` in CI.

Next: the [Guarantees](guarantees.md) guide walks through every macro with runnable examples.
