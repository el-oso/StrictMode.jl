# StrictMode cookbook: trap → macro

A quick reference mapping common Julia performance traps to the StrictMode guarantee that
catches them. Enable checks first (`StrictMode.enable_checks!()`); in production they compile
away.

| Performance trap | Symptom | Catch it with |
|---|---|---|
| **Runtime tuple indexing** (`t[i]`, `t` heterogeneous, `i` a runtime value) | `Union` return type, silent boxing, the classic 135× cliff | `@assert_typestable` / `@strict` |
| **Type-unstable return** (a branch returns `Int`, another `Float64`) | `Union{...}`/`Any` return; downstream boxing | `@assert_typestable` |
| **Captured-variable boxing** (a closure mutates an outer local) | `Core.Box`, allocations, lost inference | `@assert_typestable` (flags via JET) → v0.2 `@assert_noboxing` |
| **Untyped accumulator** (`acc = []` / `acc = 0` later holding mixed types) | per-iteration allocation, dispatch | `@assert_noalloc` / `@strict` |
| **Allocating hot loop** (`push!` into a fresh `Vector`, `collect`, slices) | heap traffic, GC pressure in inner loops | `@assert_noalloc` |
| **Accidental dynamic dispatch** (abstract field types, `Any` args) | runtime dispatch shows as allocation | `@assert_noalloc` (AllocCheck counts dispatch) |
| **A whole kernel that must stay on the fast path** | any of the above, anywhere in the call | `@strict` (combines the per-call guarantees) |
| **A function that must *never* regress** | a future edit reintroduces a trap | `@strict_function` (fails at precompile / load) |
| **An interface whose implementations must be fast** | a new impl is correct but slow | `@strict_contract` + `@verify_strict` |

## Patterns

### Guard a hot call

```julia
@strict kernel(a, b)        # type-stable + non-allocating, or it throws; returns the value
```

### Lock in a definition's contract

```julia
@strict_function axpy(a::Float64, x::NTuple{4,Float64}, y::NTuple{4,Float64}) =
    a .* x .+ y
# A later edit that makes this allocate or go unstable now breaks module load — not a profiler run.
```

### Empirical fallback when static analysis can't prove it

```julia
@assert_noalloc static = false stream_step!(buf, x)   # measures @allocated after a warmup
```

### Choose error vs. warn

```julia
StrictMode.enable_checks!(fail_mode = "warn")   # log violations instead of throwing
```

## How each check works (so you can trust the failures)

- **`@assert_noalloc`** asks AllocCheck to *prove* the call cannot allocate. Any reported site —
  including dynamic dispatch and boxing — fails the guarantee. If static analysis can't run, it
  falls back to an empirical `@allocated` measurement after a warmup call.
- **`@assert_typestable`** combines `Test.@inferred` (the *return type* must be concrete) with
  `JET.@report_opt` (no *internal* instability or runtime dispatch).
- **`@strict_function`** runs the no-alloc + concrete-return checks against the declared
  argument types at precompile/load time, so a violation stops the module from loading.

## Not yet (v0.2)

- `@assert_inlined` — fail unless a call is inlined.
- `@assert_noboxing` — pinpoint the boxing / runtime-tuple-index class specifically.
- `@unroll` + `Val` helpers — emit straight-line, literal-index code so you never hand-write the
  avoid-boxing pattern.
- `@explain f(args...)` — one human-readable report aggregating `@code_warntype`, JET, and
  AllocCheck output, telling you *why* a guarantee failed.
