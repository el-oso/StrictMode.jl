# StrictMode cookbook: trap → macro

A quick lookup table from the usual Julia performance traps to the StrictMode guarantee that
catches each one. Turn the checks on first with `StrictMode.enable_checks!()`; in production they
compile away to nothing.

| Performance trap | Symptom | Catch it with |
|---|---|---|
| **Runtime tuple indexing** (`t[i]`, `t` heterogeneous, `i` a runtime value) | `Union` return type, silent boxing | `@assert_noboxing` / `@unroll` to fix |
| **Type-unstable return** (a branch returns `Int`, another `Float64`) | `Union{...}`/`Any` return; downstream boxing | `@assert_typestable` |
| **Captured-variable boxing** (a closure mutates an outer local) | `Core.Box`, allocations, lost inference | `@assert_noboxing` |
| **Untyped accumulator** (`acc = []` / `acc = 0` later holding mixed types) | per-iteration allocation, dispatch | `@assert_noalloc` / `@strict` |
| **Allocating hot loop** (`push!` into a fresh `Vector`, `collect`, slices) | heap traffic, GC pressure in inner loops | `@assert_noalloc` |
| **Boxing, but buffers are fine** (must not box, may allocate scratch space) | runtime dispatch / `jl_get_nth_field_checked` only | `@assert_noboxing` (allows typed allocations) |
| **Accidental dynamic dispatch** (abstract field types, `Any` args) | runtime dispatch shows as allocation | `@assert_noboxing` / `@assert_noalloc` |
| **A call that should inline but doesn't** (cost-model misfire, `@noinline`) | call overhead, lost cross-call optimization | `@assert_inlined` (best-effort) |
| **A whole kernel that must stay on the fast path** | any of the above, anywhere in the call | `@strict` (combines the per-call guarantees) |
| **A `@generated`/SIMD kernel that must vectorize and stay on the fast path** | silent ~100× regression from boxing, or vectorization silently disabled — easy to miss during exploration | `@kernel` (bundles `@assert_noalloc` + `@assert_vectorized` + `@assert_typestable`; makes the boxing check reflexive) |
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

When you want the reason rather than a thrown error, reach for `@explain`. It gathers
`@code_warntype`, JET, and AllocCheck into one `StrictReport`, and it never throws:

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

## SIMD kernel workflow

Practical guidance for SIMD/`@generated` kernel development: audit reflexes, coverage, and
correctness verification against a reference.

### Annotate every hot loop — not just the obvious ones

StrictMode audits the kernels you point it at — it does not scan for hot loops automatically. A
scalar loop in the "glue" between two audited kernels will not trigger any guarantee and can
silently dominate runtime.

Use `@strict` or `@kernel` as you write each numeric loop, not only as a post-hoc check. When
something is slow and all audited kernels pass, look at the unaudited glue between them.

[`@assert_no_scalar_loops`](@ref) can help: it checks that a function's compiled body contains no
scalar FP or integer hot loops (loop-carried `phi` with no vector ops). Apply it to any function
where you expect auto-vectorization to have kicked in.

### Port against a golden reference

When porting a numeric kernel from a reference implementation (Rust, C, Fortran), a layer-by-layer
bit-exact comparison is the most reliable way to verify correctness and catch subtle semantic
differences.

1. **Port one layer at a time.** Implement a single kernel (e.g. a Householder reflector), run it
   against the reference's *own output* for the same input, and assert bit-exact agreement before
   moving on. Do not wait until the full algorithm is assembled — errors compound.

2. **Bit-exact where possible.** Pure arithmetic (multiply-add chains, memory copies, index
   arithmetic) can be matched exactly. Reference-output comparison caught three deviations in a QR
   port that a source-reading pass would have missed: a norm kernel that was single-accumulator
   rather than the 2-way its source appeared to be; an `abs2_add` implemented as FMA rather than
   `mul + add`; and a `hypot` that used a custom overflow-safe path rather than `libm`.

3. **Allow ~1 ULP for SIMD reductions.** The lane-combine order for vector reductions is
   LLVM-codegen-defined (see [Promise scope](guarantees.md) in the Guarantees guide). Brute-forcing
   accumulation models showed that the last ULP of a 4-way reduction cannot always be reproduced
   cross-codegen. Use a tolerance of 1–2 ULP for reduction-shaped operations; require exact match
   for everything else.

4. **Keep the harness alive.** The bit-exact tests become a regression suite. A later optimization
   that shifts a value beyond tolerance is a real signal worth investigating.

```julia
# bit-exact check for a deterministic kernel
@test my_norm(x) === ref_norm

# tolerance for a SIMD reduction
@test abs(my_dot(a, b) - ref_dot) ≤ eps(ref_dot)
```

StrictMode provides [`@golden`](@ref) for this pattern. Record mode writes a typed golden file;
compare mode does exact or ULP-tolerant comparison and throws `StrictViolation` on mismatch:

```julia
@golden norm_check my_norm(x)            # exact comparison (deterministic kernel)
@golden dot_check my_dot(a, b) ulps=2    # tolerance-aware (SIMD reduction)
```

For problems with multiple valid outputs (e.g. "any shortest round-trip decimal"), pass a
`validator=` predicate instead of a golden file:

```julia
@golden ryu_check ryu_format(x) validator = s -> parse(Float64, s) === x
```

### Guarantee the kernel, smoke-test the entry

Public functions often can't carry whole-method guarantees:

- **Union-returning entries**: a function returning `Union{Int,Nothing}` — the canonical Julia
  idiom for "index or not found" (`findfirst`, `iterate`, `tryparse`). `@assert_typestable`
  accepts small isbits unions like this, so this case is handled directly.

- **Base-delegating entries**: the public wrapper forwards edge cases to Base (e.g.
  `length(needle) ≤ 1 && return findfirst(...)`), which may allocate or dispatch dynamically
  across the full call graph. Whole-method `@assert_noalloc` can't be placed on such entries.

The pattern for Base-delegating entries: assert on the **inner kernel** (concrete return,
alloc-free), and empirically smoke-test the **public entry** with a runtime `@allocated` check:

```julia
# Inner pointer kernel: concrete return, fully assertable
@kernel _find_substr(ph, lh, pn, ln)   # noalloc + vectorized + typestable

# Public entry: delegates to Base for edge cases — empirical check only
@test @allocated(find_substr(haystack, needle)) == 0   # runtime zero-alloc on the hot path
@test find_substr(haystack, needle) == expected         # correctness
```

The pattern: assert on the leaf kernel where the guarantees actually hold; the thin dispatcher
is smoke-tested empirically. The audit covers the performance-critical path; edge-case branches
stay outside the guarantee boundary.

### Defeat dead-code elimination before measuring

A benchmark that only observes a derived value (a length, a checksum) lets the optimizer
eliminate the actual work — the timing then measures the derived value alone, not the kernel.

The rule: **every measured kernel needs an explicit sink that consumes its output.**

```julia
# Wrong: only length observed — stores may be DCE'd
@btime length(format_int!(buf, x))

# Right: sink the buffer so the stores are required
@btime (format_int!(buf, x); Base.donotdelete(buf))
```

If benchmarking against a reference implementation, ensure the reference also sinks its output
(e.g. `std::hint::black_box(buf)` in Rust, `volatile` write in C). `Base.donotdelete` is
available in Julia 1.8+.

### Measure across representative value classes

A single benchmark input can be misleading when the kernel does different amounts of work
depending on the value — a formatter, search function, or compression codec may run several times
faster on "easy" inputs than on "hard" ones. A one-distribution number is not a verdict.

Required: measure across the value classes your kernel will actually see, and report the spread:

```julia
for (label, gen) in [("rand", ()->rand()), ("randn", ()->randn()), ("integer", ()->Float64(rand(1:10^6)))]
    t = @belapsed kernel($gen()) setup=nothing
    println("$label: $(round(t*1e9, digits=1)) ns")
end
```

If the spread exceeds 2×, the "typical case" number may not represent production load.
