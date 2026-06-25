# StrictMode cookbook: trap → macro

A quick lookup table from the usual Julia performance traps to the StrictMode guarantee that
catches each one. Turn the checks on first with `StrictMode.enable_checks!()`; in production they
compile away to nothing.

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

## Force the fast path

Better than detecting boxing is not boxing at all. `@unroll` fully unrolls a fixed-count loop with
literal indices, so a heterogeneous tuple gets indexed type-stably instead of boxing:

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

## Numeric kernel workflow

Practical guidance for SIMD/`@generated` kernel development: audit reflexes, coverage, and
correctness verification against a reference.

### Annotate every hot loop — not just the obvious ones

StrictMode audits the kernels you point it at — it does not scan for hot loops automatically.
A scalar floating-point hot loop in the "glue" between two audited kernels will not trigger any
guarantee and can silently dominate runtime.

In a QR factorization port, a scalar triangular triple-loop (`Y = TᵀW`) accounted for ~12% of
total runtime (more via cache effects), while the suspected bottleneck — the panel reduction — was
only 3–5%. The two surrounding gemm kernels were audited and green; the scalar loop between them was
never pointed at the auditor, so it was invisible until a wall-clock profiler found it. The fix was
simple once seen: it had the same shape as an already-vectorized kernel and could reuse it — but
`@assert_vectorized` only tells you what you ask about.

Use `@strict` or `@kernel` as you write each numeric loop, not only as a post-hoc check. When
something is slow and all audited kernels pass, look at the unaudited glue.

!!! note
    An automatic whole-function scalar-loop IR scan is a planned future feature, not yet available.

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

!!! note
    A `@golden`-style gated-regression macro (exact for deterministic ops, tolerance-aware for SIMD
    reductions) is a planned future feature. For now, implement the pattern with standard `@test`.

### Guarantee the kernel, smoke-test the entry

Public functions often can't carry whole-method guarantees:

- **Union-returning entries**: a function returning `Union{Int,Nothing}` — the canonical Julia
  idiom for "index or not found" (`findfirst`, `iterate`, `tryparse`). Since F21, `@assert_typestable`
  accepts small isbits unions, so this case is now handled directly.

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

This mirrors the F11 principle: assert on the leaf where the guarantees actually hold; the thin
dispatcher is smoke-tested empirically. The audit covers the performance-critical path; edge-case
branches stay outside the guarantee boundary.

### Defeat dead-code elimination before measuring (F25)

A benchmark that only observes a derived value (a length, a checksum) lets the optimizer
eliminate the actual work — the timing then measures the derived value alone. The itoa
reference shim timed `buf.format(x).len()`, and because only the *length* was consumed,
LLVM eliminated the digit-writes entirely: the "8.7× faster" number was measuring `ndigits`,
not formatting.

The rule: **every measured kernel needs an explicit sink that consumes its output.**

```julia
# Wrong: only length observed — stores may be DCE'd
@btime length(format_int!(buf, x))

# Right: sink the buffer so the stores are required
@btime (format_int!(buf, x); Base.donotdelete(buf))
```

This applies on both sides of a Rust/Julia comparison: ensure the reference shim sinks its
output (e.g. `std::hint::black_box(buf)` in Rust) and the Julia version sinks its buffer.
`Base.donotdelete` is available in Julia 1.8+.

### Measure across representative value classes (F26)

A single benchmark input can flip a "gap" verdict into a "2× win". Re-probing `ryu` (float→
string) showed **0.76×** on `rand()` (full mantissa) vs **2.05×** on integer-valued floats
(`1000.0`) — the same code path, swinging 2.7× on input distribution alone. A one-distribution
number is not a verdict.

Required: measure across the value classes your kernel will actually see, and report the spread:

```julia
for (label, gen) in [("rand", ()->rand()), ("randn", ()->randn()), ("integer", ()->Float64(rand(1:10^6)))]
    t = @belapsed kernel($gen()) setup=nothing
    println("$label: $(round(t*1e9, digits=1)) ns")
end
```

If the spread exceeds 2×, the "typical case" number may not represent production load.
