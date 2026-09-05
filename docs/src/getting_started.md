# Getting Started

## Installation

```julia
using Pkg
Pkg.add("StrictMode")
```

`StrictMode` reads inferred types and typed IR. It needs no other package and is fast enough to run
at load time. Where it is **guessing** — the allocation and trim checks — it warns instead of
failing your build. Where it reads the compiled output and knows, it throws.

The proofs are heavy, so they live in a second package you add to your test environment only:
[AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl),
[JET.jl](https://github.com/aviatesk/JET.jl) and TrimCheck.jl.

```julia
# in test/Project.toml, alongside StrictMode:
Pkg.add("StrictModeTest")
```

`StrictModeTest` **gates**: `@test_noalloc`, `@test_typestable` and the `test_signatures` /
`test_compiled` / `test_registered` drivers all throw. The macro you write picks the engine —
nothing else does. `proofs_loaded()` says which one a session has.

Code that only depends on StrictMode needs neither. For the live loop, add `Revise`.

## Enable the checks

Checks are **on by default**, so a dev or test environment needs no setup. That matters: with checks
off every `@assert_*` is a no-op, and a suite full of them passes while testing nothing.

Turn them off for a shipped application in the deployed `Project.toml` (or a `LocalPreferences.toml`
next to it):

```toml
[preferences.StrictMode]
checks_enabled = false
```

With it off, the macros expand to the bare call and there's nothing left to run.

Restart Julia after changing it. The setting is read when the package compiles, not while a session
runs.

Start your strict tests with [`assert_enabled`](@ref). It returns `checks_enabled()` locally and
**errors under CI** when checks are off, so a disarmed suite cannot pass quietly.

For interactive use, `disable_checks!()`/`enable_checks!()` write the setting for you:

```julia
using StrictMode

StrictMode.disable_checks!()   # writes the setting; restart Julia to apply
# ... run without the guarantees ...
StrictMode.enable_checks!()    # back on
```

!!! note "Why the restart?"
    Disabled checks compile away to nothing, so the setting has to be fixed before the package
    compiles. Call `disable_checks!()` and keep asserting in the same session and every check still
    runs — that image is already built.

Check the current state at any time:

```@example gs
using StrictMode
StrictMode.checks_enabled()
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

## The other half: proving it

The allocation check above **reports**. `@assert_noalloc` reads typed IR, which still shows
allocations LLVM later deletes — so it can only say something looks wrong, and a guess must not
break your build.

To make the same property fail CI, use the `StrictModeTest` macro. Same question, asked of
AllocCheck, and it throws:

```julia
using StrictMode, StrictModeTest

@assert_noalloc square_sum((1.0, 2.0, 3.0))   # warns — the scan's opinion
@test_noalloc   square_sum((1.0, 2.0, 3.0))   # throws — AllocCheck's proof, over every path
```

That pairing is what to take from this page:

```text
  your Project.toml          your test/Project.toml
  ─────────────────          ─────────────────────
  StrictMode                 StrictMode + StrictModeTest
  @assert_noalloc            @test_noalloc
  reads typed IR             asks AllocCheck
  warns  ⚠                   throws  ✗
```

The macro you write picks the column. There is no mode to switch and no environment variable.
`@assert_*` while you iterate, `@test_*` in the test suite.

See [StrictModeTest](proof_tier.md) for the full proving surface.

## When a guarantee fails

A guarantee that gates throws a [`StrictViolation`](@ref) naming the call and what went wrong.
Whether a guarantee throws or warns is fixed per guarantee, not configured — the ones that observe
compiled output throw, the ones that infer only warn. [Guarantees](guarantees.md) lists which is
which.

Indexing a heterogeneous tuple with a runtime value is the classic case: it returns a `Union` and
boxes behind your back. Here the silence becomes an error:

```julia
state = (1, 2.0, "three")
component(s, i) = s[i]

@assert_typestable component(state, rand(1:3))
# ERROR: StrictViolation (@typestable): guarantee not satisfied
#   target:  component(state, rand(1:3))
#   reason:  return type is not concrete or isbits-union (inference): Union{Float64, Int64, String}
```

## Zero cost when disabled

With the checks off, the macro expands to exactly the bare call. There's nothing left to run, and
nothing to pay for:

```julia
# checks OFF
@macroexpand @assert_noalloc f(x)   #  ->  :(f(x))
```

## What the checks cost when enabled

`StrictMode` has no analysis backend and no warmup step. It reads Base's own inference and nothing
else, so it costs about what any small package costs to load. With checks off the macros are bare
calls, so a shipped application pays nothing at all.

`StrictModeTest` is where the heavy machinery is: it warms JET and AllocCheck at its own precompile.
That is why it belongs in `test/` and not in your `Project.toml`.

The per-check cost is in the table below. It grows with the size of the call graph, so these checks
are happiest pointed at small hot kernels — which is where the silent traps live anyway. With
Revise, an edit-and-rerun loop keeps the image warm between edits.

### The two analysis engines

`@assert_*` runs the cheap value-free engine; `@test_*` runs the proof. There is no rigor/speed
preference to set and no ambient state to read — the macro name selects the engine.

| Package | Macro | Type stability | No-allocation / no-boxing | Per-method cost | On a violation |
|---|---|---|---|---|---|
| `StrictMode` | `@assert_*` | `Base.return_types` concreteness + an IR boxing signal | `code_typed` IR + `infer_effects` scan | ~70 µs | reports |
| `StrictModeTest` | `@test_*` | JET `@report_opt` | AllocCheck static proof | ~900 µs | throws |

`StrictMode`'s engine is a quick triage over all the properties at once, type stability as well as
allocation and boxing, built entirely on Base's own inference. Because of that it needs no
AllocCheck or JET and runs roughly 10× cheaper per method than the proof
(see `StrictMode/bench/timetax.jl`).
It catches the usual suspects, like explicit heap allocation, boxing, dynamic dispatch, and
non-concrete returns. Being a scan of typed IR it can miss or over-flag something that AllocCheck's
LLVM-level proof would get exactly right — which is exactly why it reports rather than gating. The
split that works well in practice: `StrictMode`'s `@assert_*` while you iterate, `StrictModeTest`'s
`@test_*` and `test_*` drivers in CI.

Two guarantees are graded per layer rather than per package. `@assert_typestable`'s return-type
concreteness is exact for the question it asks, so it throws; its IR boxing signal is a heuristic,
so that layer warns. And `@assert_memsafe`, `@assert_vectorized`, `@assert_no_spill` and friends all
throw, because they *observe* compiled output rather than inferring about it.

### Incremental re-checks

`findings` and `audit` cache their results per `(method, world, signature, guarantees)`. A re-run
only re-analyzes the methods that actually changed, so editing one method and running `audit` again
comes back almost instantly while everything else is a cache hit. [`cache_stats`](@ref) shows you
the hits and misses, and [`clear_cache!`](@ref) is there for the one case the cache can't see: when
you edit a *callee* of a checked method rather than the method itself.

From here, the [Guarantees](guarantees.md) guide walks through each macro in turn, with examples
you can run.
