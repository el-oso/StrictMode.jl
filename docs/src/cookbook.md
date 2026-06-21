# StrictMode cookbook: trap → macro

A quick reference mapping common Julia performance traps to the StrictMode guarantee that
catches them. Enable checks first (`StrictMode.enable_checks!()`); in production they compile
away.

| Performance trap | Symptom | Catch it with |
|---|---|---|
| **Runtime tuple indexing** (`t[i]`, `t` heterogeneous, `i` a runtime value) | `Union` return type, silent boxing, the classic 135× cliff | `@assert_noboxing` / `@unroll` to fix |
| **Type-unstable return** (a branch returns `Int`, another `Float64`) | `Union{...}`/`Any` return; downstream boxing | `@assert_typestable` |
| **Captured-variable boxing** (a closure mutates an outer local) | `Core.Box`, allocations, lost inference | `@assert_noboxing` |
| **Untyped accumulator** (`acc = []` / `acc = 0` later holding mixed types) | per-iteration allocation, dispatch | `@assert_noalloc` / `@strict` |
| **Allocating hot loop** (`push!` into a fresh `Vector`, `collect`, slices) | heap traffic, GC pressure in inner loops | `@assert_noalloc` |
| **Boxing, but buffers are fine** (must not box, may allocate scratch space) | runtime dispatch / `jl_get_nth_field_checked` only | `@assert_noboxing` (allows typed allocations) |
| **Accidental dynamic dispatch** (abstract field types, `Any` args) | runtime dispatch shows as allocation | `@assert_noboxing` / `@assert_noalloc` |
| **A call that should inline but doesn't** (cost-model misfire, `@noinline`) | call overhead, lost cross-call optimization | `@assert_inlined` (best-effort) |
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

### Trade rigor for speed while iterating

```julia
StrictMode.enable_checks!(analysis = "fast")   # cheap inference-only checks (sub-ms); :full in CI
```

### Diagnose instead of assert

When you want the *reason* rather than a thrown error, reach for `@explain` — it aggregates
`@code_warntype`, JET and AllocCheck into one `StrictReport` and never throws:

```julia
@explain component(state, rand(1:3))   # returns a report explaining each verdict
```

## How each check works (so you can trust the failures)

- **`@assert_noalloc`** asks AllocCheck to *prove* the call cannot allocate. Any reported site —
  including dynamic dispatch and boxing — fails the guarantee. If static analysis can't run, it
  falls back to an empirical `@allocated` measurement after a warmup call.
- **`@assert_noboxing`** runs the same AllocCheck analysis but reports only the *boxing /
  dynamic-dispatch* subclass (`DynamicDispatch`, `jl_box_*` / `jl_get_nth_field_checked` runtime
  calls, `Core.Box`), so legitimate typed allocations pass.
- **`@assert_typestable`** combines `Test.@inferred` (the *return type* must be concrete) with
  `JET.@report_opt` (no *internal* instability or runtime dispatch).
- **`@assert_inlined`** compiles a wrapper around the call and checks its optimized IR for a
  surviving `:invoke` to the callee — best-effort, since inlining is a heuristic.
- **`@strict_function`** runs the no-alloc + concrete-return checks against the declared
  argument types at precompile/load time, so a violation stops the module from loading.

## Force the fast path

Don't just detect boxing — avoid it. `@unroll` fully unrolls a fixed-count loop with literal
indices, so a heterogeneous tuple is indexed type-stably instead of boxing:

```julia
function tuple_sum(t)
    s = 0.0
    @unroll for i in 1:3
        s += t[i]        # → s += t[1]; t[2]; t[3]   (no boxing; @assert_noalloc passes)
    end
    s
end
```

For a size known only from a type, lift it with `staticval(n)` and splice the literal into
`@unroll` from a `@generated` method.
