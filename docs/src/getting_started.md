# Getting Started

## Installation

```julia
using Pkg
Pkg.add("StrictMode")
```

`StrictMode` on its own analyzes with a value-free engine — inferred return types plus a scan of
typed IR — that needs no extra dependency and is cheap enough to run at load time. It **reports**.

The proofs — [AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl),
[JET.jl](https://github.com/aviatesk/JET.jl), and TrimCheck.jl — are heavyweight, so they live in a
companion package you add to your test environment only:

```julia
# in test/Project.toml, alongside StrictMode:
Pkg.add("StrictModeTest")
```

`StrictModeTest` **gates**: it supplies `@test_noalloc` / `@test_typestable` and the
`test_signatures` / `test_compiled` / `test_registered` drivers, which throw on a violation. Which
engine a call site uses is decided by the macro you wrote, not by ambient state:
`StrictMode.proofs_loaded()` tells you which tier a session is in. Production code that depends on
StrictMode needs neither package. If you want the live feedback loop, add `Revise` too.

## Enable the checks

Every guarantee sits behind a compile-time setting, **on by default**. A dev or test environment
therefore needs no setup at all: depend on StrictMode and the guarantees run. That default is
deliberate — a preference you have to remember to add is a preference that goes missing, and with
checks off every `@assert_*` is a no-op, so a suite full of them passes vacuously.

A shipped application turns them off. Add a section to the deployed project's `Project.toml` (or a
`LocalPreferences.toml` next to it):

```toml
[preferences.StrictMode]
checks_enabled = false
```

With it off, the macros expand to the bare call and there's nothing left to run.

Either way, run in a **fresh Julia process** after changing the setting — it is read when Julia
compiles the package, not while a session is already running.

To catch the setting having been turned off where it matters, start your strict tests with
[`assert_enabled`](@ref): it returns `checks_enabled()` locally but **errors under CI** when checks
are disabled.

For interactive use, `disable_checks!()`/`enable_checks!()` write the setting for you:

```julia
using StrictMode

StrictMode.disable_checks!()   # writes the setting; restart Julia to apply
# ... run without the guarantees ...
StrictMode.enable_checks!()    # back on
```

!!! note "Why does a restart matter?"
    StrictMode's checks compile away to nothing when disabled, so the setting must be fixed before
    Julia compiles the package. Calling `disable_checks!()` and then asserting in the same process
    still runs every check — the existing compiled image is already baked. Restart Julia (or start
    a fresh process for your tests) after changing the setting.

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

Everything above **reports**. `@assert_noalloc` reads typed IR, where an allocation LLVM later
deletes is still visible, so it can only tell you something looks wrong — and a check that guesses
must not be able to break your build.

When you want the same property to actually fail CI, reach for the macro from `StrictModeTest`. It
is the same question asked of AllocCheck instead, and it throws:

```julia
using StrictMode, StrictModeTest

@assert_noalloc square_sum((1.0, 2.0, 3.0))   # warns — the scan's opinion
@test_noalloc   square_sum((1.0, 2.0, 3.0))   # throws — AllocCheck's proof, over every path
```

This pairing is the thing to carry away from this page. Which engine runs is decided by **the macro
you wrote**, when it expands — there is no mode to switch, no environment variable, and nothing
ambient choosing for you. `@assert_*` while you iterate, `@test_*` in the test suite, and
[`proofs_loaded()`](@ref) if you ever need to ask which tier a session is in.

See [StrictModeTest](proof_tier.md) for the whole proving surface.

## When a guarantee fails

When a guarantee doesn't hold you get a [`StrictViolation`](@ref) naming the call and explaining
what went wrong — for the guarantees that gate. There is no mode to set: whether a given guarantee
throws or warns is fixed per guarantee, and the ones that infer rather than observe only warn (see
[Guarantees](guarantees.md)). Indexing a heterogeneous tuple with a runtime
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
- With checks on, in dev or CI: a warmup step built into StrictMode runs once when the package is
  first compiled (10–20 s during install). After that the first `@explain` or `@strict` in a
  session takes about 0.1 s, and a warm check on a small kernel runs in single-digit to tens of
  milliseconds.

The shape of it is: you pay once at precompile, not on every call, and an edit-and-rerun loop with
Revise keeps the image warm between edits. The warm cost does grow with the size of the call graph,
so these checks are happiest pointed at small hot kernels, which is exactly where the silent traps
live anyway.

### The two analysis engines

`@assert_*` runs the cheap value-free engine; `@test_*` runs the proof. There is no rigor/speed
preference to set and no ambient state to read — the macro name selects the engine.

| Package | Macro | Type stability | No-allocation / no-boxing | Per-method cost | On a violation |
|---|---|---|---|---|---|
| `StrictMode` | `@assert_*` | `Base.return_types` concreteness + an IR boxing signal | `code_typed` IR + `infer_effects` scan | ~70 µs | reports |
| `StrictModeTest` | `@test_*` | JET `@report_opt` | AllocCheck static proof | ~900 µs | throws |

`StrictMode`'s engine is a quick triage over all the properties at once, type stability as well as
allocation and boxing, built entirely on Base's own inference. Because of that it needs no
AllocCheck or JET and runs roughly 10× cheaper per method than the proof (see `bench/timetax.jl`).
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
