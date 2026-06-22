# Getting Started

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/el-oso/StrictMode.jl")
```

The real analysis is done by [AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl) and
[JET.jl](https://github.com/aviatesk/JET.jl). Both are heavyweight, so StrictMode keeps them as
weak dependencies and asks you to add them only in the places you actually run checks:

```julia
# in your dev / test / CI environment, alongside StrictMode:
Pkg.add(["AllocCheck", "JET"])
```

The backend switches on once you load them (`using AllocCheck, JET`), and
`StrictMode.backend_available()` will tell you whether it's on. Production code that depends on
StrictMode with the checks off needs neither package. If you want the live feedback loop, add
`Revise` too.

## Enable the checks

Every guarantee sits behind a [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl)
compile-time flag, and it's off by default. With it off, a production build pays nothing: the
macros expand to the bare call and there's nothing left to run. Turn the checks on while you
develop, or in CI:

```julia
using StrictMode

StrictMode.enable_checks!()    # writes the preference; **restart Julia** to apply
# ... develop with guarantees active ...
StrictMode.disable_checks!()   # back to the production default
```

!!! note "The gate is compile-time"
    `enable_checks!` writes a preference; it doesn't change the session you're already in.
    `checks_enabled()` stays `false` until you restart, which means a script that enables checks
    and then asserts in the same process is quietly checking nothing. To set it once for a
    package's dev and CI runs, put it straight in the project's `Project.toml`, where it gets
    committed alongside the code:

    ```toml
    [preferences.StrictMode]
    checks_enabled = true
    fail_mode = "error"
    ```

    A `LocalPreferences.toml` next to `Project.toml` works the same way. Either way, run your tests
    in a fresh process, as in the pattern shown below.

You can choose whether a violation throws or just warns:

```julia
StrictMode.enable_checks!(fail_mode = "warn")   # log violations instead of throwing
```

Check the current state at any time:

```@example gs
using StrictMode
StrictMode.checks_enabled(), StrictMode.fail_mode()
```

(These docs are built with the checks enabled, so every live example below is really running the
analysis as you read it.)

## Your first guarantee

Start by asking a call to be allocation-free. The macro hands back the call's own value, so you
can wrap any expression and carry on as if it weren't there:

```@example gs
square_sum(xs) = sum(x -> x^2, xs)

@assert_noalloc square_sum((1.0, 2.0, 3.0))
```

Or ask for type stability:

```@example gs
affine(x) = 2x + 1
@assert_typestable affine(3.0)
```

Or ask for everything at once with [`@strict`](@ref):

```@example gs
weighted(a, b) = 0.5a + 0.5b
y = @strict weighted(2.0, 4.0)
```

## When a guarantee fails

When a guarantee doesn't hold, you get a [`StrictViolation`](@ref) (in the default `:error` mode)
that names the call and explains what went wrong. Indexing a heterogeneous tuple with a runtime
value is a good example: it produces a `Union` return type and boxes behind your back. Here that
silence becomes an error:

```julia
state = (1, 2.0, "three")
component(s, i) = s[i]

@assert_typestable component(state, rand(1:3))
# ERROR: StrictViolation (@typestable): guarantee not satisfied
#   target:  component(state, rand(1:3))
#   reason:  return type is not concretely inferrable: ... Union{Int64, Float64, String}
```

## Zero cost when disabled

With the checks off, the macro expands to exactly the bare call. There's nothing left to run, and
nothing to pay for:

```julia
# checks OFF
@macroexpand @assert_noalloc f(x)   #  ->  :(f(x))
```

## What the checks cost when enabled

JET and AllocCheck are heavyweight, so it's worth knowing where the time actually goes:

- With checks off, in production: nothing at all. The macros are bare calls and the analyzers are
  never compiled in, so precompiling StrictMode stays quick (around 3 s here).
- With checks on, in dev or CI: a `PrecompileTools` workload warms the analyzers into StrictMode's
  precompiled image. That one-time compilation (10–20 s) happens at precompile, during install or
  CI, rather than on your first interactive call. From then on the first `@explain` or `@strict` in
  a session takes about 0.1 s, and a warm check on a small kernel runs in single-digit to tens of
  milliseconds.

The shape of it is: you pay once at precompile, not on every call, and an edit-and-rerun loop with
Revise keeps the image warm between edits. The warm cost does grow with the size of the call graph,
so these checks are happiest pointed at small hot kernels, which is exactly where the silent traps
live anyway.

### `:full` vs `:fast` analysis

If even the warm cost is too much for your loop, say a large function you're iterating on, you can
drop the per-call asserts down to cheap inference-only checks:

```julia
StrictMode.enable_checks!(analysis = "fast")   # default is "full"
```

| Mode | Type stability | No-allocation / no-boxing | Backend | Per-method cost |
|---|---|---|---|---|
| `:full` (default) | JET `@report_opt` | AllocCheck static proof | AllocCheck + JET | ~900 µs |
| `:fast` | `Base.return_types` concreteness | `code_typed` IR + `infer_effects` heuristic | none needed | ~70 µs |

`:fast` is a quick triage over all the properties at once, type stability as well as
allocation and boxing, built entirely on Base's own inference. Because of that it needs no
AllocCheck or JET backend and runs roughly 10× cheaper per method than `:full` (see
`bench/timetax.jl`). It catches the usual suspects, like explicit heap allocation, boxing, dynamic
dispatch, and non-concrete returns. Being a heuristic, it can occasionally miss or over-flag
something that AllocCheck's LLVM-level proof would get exactly right, so [`@explain`](@ref) and
[`@strict_function`](@ref) always use the full analysis. The split that works well in practice:
`:fast` while you iterate, `:full` in CI.

### Incremental re-checks

`findings`, `check`, `audit`, and `check_all` cache their results per `(method, world, signature,
mode)`. A re-run only re-analyzes the methods that actually changed, so editing one method and
running `audit` again comes back almost instantly while everything else is a cache hit. `:fast`
analysis also spreads across threads when `Threads.nthreads() > 1`. [`cache_stats`](@ref) shows you
the hits and misses, and [`clear_cache!`](@ref) is there for the one case the cache can't see: when
you edit a *callee* of a checked method rather than the method itself.

The analysis mode comes from the `analysis` preference, which is baked in at precompile. That means
a stale package image can still run `:full` even after you've switched the preference to `fast`. To
force the mode for a single run without recompiling, pass `mode`:

```julia
audit(MyPkg; sweep = true, mode = :fast)   # quick whole-package scan, regardless of the baked default
check(f, types; mode = :fast)
```

From here, the [Guarantees](guarantees.md) guide walks through each macro in turn, with examples
you can run.
