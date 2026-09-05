# StrictMode cookbook: trap → macro

A quick lookup table from the usual Julia performance traps to the StrictMode guarantee that
catches each one. Checks are on by default; `StrictMode.disable_checks!()` compiles them away to
nothing for a shipped application.

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
| **A whole kernel that must stay on the fast path** | any of the above, anywhere in the call | `@strict` (type stability, owned scratch, allocation-freedom) |
| **A `@generated`/SIMD kernel that must vectorize and stay on the fast path** | silent ~100× regression from boxing, or vectorization silently disabled — easy to miss during exploration | `@kernel` (bundles `@assert_noalloc` + `@assert_vectorized` + `@assert_typestable`; makes the boxing check reflexive) |
| **A function that must *never* regress** | a future edit reintroduces a trap | `@strict_function` (return type checked at load; allocation re-proved by `test_registered()`) |
| **An interface whose implementations must be fast** | a new impl is correct but slow | `@strict_contract` + `@verify_strict` |

Every `@assert_*` above comes from `StrictMode` and reports. Where you want the same property to
fail CI, write the `@test_*` macro of the same name from
[`StrictModeTest`](proof_tier.md) — `@test_noalloc`, `@test_noboxing`, `@test_typestable`,
`@test_trim_compatible`, `@test_strict`, `@test_kernel`.

## Patterns

### Guard a hot call

```julia
@strict kernel(a, b)        # type-stable, owned scratch, non-allocating; returns the value
```

### Lock in a definition's contract

```julia
@strict_function axpy(a::Float64, x::NTuple{4,Float64}, y::NTuple{4,Float64}) =
    a .* x .+ y
# A later edit that makes this return a non-concrete type now breaks module load; one that makes
# it allocate warns here and fails under test_registered().
```

### Empirical fallback when static analysis can't prove it

```julia
@assert_noalloc static = false stream_step!(buf, x)   # measures @allocated after a warmup
```

### Report while iterating, gate in CI

Nothing to configure for the first half: `StrictMode`'s `@assert_*` run a cheap inference-only
engine (sub-ms per method, no extra dependency) and **report**. Add `StrictModeTest` to the test
environment and write `@test_*` where you want the AllocCheck/JET proof to **fail the build**:

```julia
@assert_noalloc kernel!(C, A, B)     # while you iterate — warns
@test_noalloc    kernel!(C, A, B)    # in CI — throws
```

### Diagnose instead of assert

When you want the reason rather than a verdict, reach for `@explain`. It gathers
`@code_warntype`, the inferred return type, and the typed-IR signals into one `StrictReport`, and
it never throws:

```julia
@explain component(state, rand(1:3))   # returns a report explaining each verdict
```

## How each check works (so you can trust the failures)

- **`@assert_noalloc`** scans typed IR for allocation sites — including dynamic dispatch and
  boxing. `static = false` measures `@allocated` after a warmup instead. Both are heuristics, so it
  **reports**; **`@test_noalloc`** asks AllocCheck to *prove* the call cannot allocate on any path,
  and throws.
- **`@assert_noboxing`** flags the *boxing / dynamic-dispatch* subclass from the same scan, so
  legitimate typed allocations pass. **`@test_noboxing`** classifies AllocCheck's own instances
  (`DynamicDispatch`, `jl_box_*` / `jl_get_nth_field_checked` runtime calls, `Core.Box`) — which is
  where the distinction is actually proved.
- **`@assert_typestable`** requires a concrete inferred return type (exact, so it throws) and adds
  an IR signal for internal dispatch behind a concrete return (a heuristic, so it warns).
  **`@test_typestable`** replaces that second layer with `JET.@report_opt` and throws on it.
- **`@assert_inlined`** compiles a wrapper around the call and checks its optimized IR for a
  surviving `:invoke` to the callee — best-effort, since inlining is a heuristic, but it observes
  compiled output rather than inferring, so it throws.
- **`@strict_function`** runs the same checks against the declared argument types at precompile/load
  time. A non-concrete return stops the module from loading; an allocation verdict only warns there,
  because the proof is not loadable at a package's own precompile and a guess must not break a build.
  The declaration is registered either way, so `test_registered()` re-proves it from `test/`.

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
@golden "norm_check" my_norm(x)            # exact comparison (deterministic kernel)
@golden "dot_check" my_dot(a, b) ulps=2    # tolerance-aware (SIMD reduction)
```

For problems with multiple valid outputs (e.g. "any shortest round-trip decimal"), pass a
`validator=` predicate instead of a golden file:

```julia
@golden "ryu_check" ryu_format(x) validator = s -> parse(Float64, s) === x
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

## `@unroll` — force the fast path

```@setup cookbook
using StrictMode
```

The assert macros tell you after the fact that you boxed. [`@unroll`](@ref) keeps it from
happening in the first place. When a loop's trip count is known at macro time, it unrolls the loop
completely and swaps the loop variable for a literal on each pass, so `t[i]` becomes
`t[1]; t[2]; …`. A heterogeneous tuple then gets indexed type-stably, with no boxing. Unlike the
asserts it isn't gated behind the checks flag; the unrolling always happens.

This is the trap that started the whole project. The naive loop is type-stable, returning a
concrete `Float64`, and it still allocates, because the runtime tuple index boxes. It's the exact
thing `@assert_noalloc` is there to catch:

```@example cookbook
htup = (1, 2.0, 3.0f0)

function naive(t)
    acc = 0.0
    for i in 1:3
        acc += t[i]          # runtime index over a heterogeneous tuple → boxes
    end
    return acc
end

function unrolled(t)
    acc = 0.0
    @unroll for i in 1:3
        acc += t[i]          # → acc += t[1]; t[2]; t[3]   (literal, no boxing)
    end
    return acc
end

(naive(htup), unrolled(htup), @allocated(naive(htup)), @allocated(unrolled(htup)))
```

Both give the same answer, but only the naive loop allocates, so the guarantee passes for the
unrolled version and not the other:

```@example cookbook
@assert_noalloc unrolled(htup)
```

```julia
@assert_noalloc naive(htup)
# ┌ Warning: StrictViolation (@noalloc): guarantee not satisfied
# │   reason:  allocates / boxes (value-free IR scan)
#   (@test_noalloc names the site: Allocating runtime call to "jl_get_nth_field_checked")
```

When the size lives only in a type, you can lift it into the type domain with [`staticval`](@ref)
and splice the literal into `@unroll` from a `@generated` method:

```julia
@generated function tuple_sum(t::Tuple)
    N = length(t.parameters)
    quote
        acc = zero(promote_type(t.parameters...))
        @unroll for i in 1:$N        # $N is a literal inside the generated body
            acc += t[i]
        end
        acc
    end
end
```
