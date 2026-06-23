# Closing the gaps with Rust

Rust has a quiet superpower: idiomatic code is reliably fast, because the compiler (or the type
system) complains in exactly the places where Julia would have stayed silent. The goal with
StrictMode was to make Julia feel that predictable to optimize. Dogfooding it against a SIMD FFT
turned up three specific gaps, and this page walks through each one and the feature that closes it.

## 1. The time tax (closed)

Rust's guarantees are free. StrictMode's used to cost a full AllocCheck pass for every method,
enough that a whole-package sweep once blew through a ten-minute timeout. Not any more:

- `:fast` mode is a value-free, inference-only triage of every property at once (allocation,
  boxing, type-stability), built on `code_typed` IR and `Base.infer_effects`. It needs no
  AllocCheck or JET backend and runs about 10× cheaper per method than `:full`, which is still
  there as the rigorous AllocCheck proof for CI.
- An incremental cache keys findings on `(method, world, signature, mode)`, so re-running `audit`
  after a one-method edit only re-analyzes that one method. It comes back almost instantly.
- `:fast` sweeps run across threads.

A whole-module re-check on every edit is now affordable. See [Getting Started](getting_started.md).

## 2. Opt-in, not pervasive (closed)

Rust disciplines every function by default, and you opt out of safety rather than into it.
StrictMode now works the same way:

- `@strict module … end` makes every function in the module checked by default, from one
  declaration. No per-function annotations.
- `@strict_exempt` lets the occasional cold or by-design-allocating helper opt out at its
  definition.
- The whole-module load check runs on the cheap `:fast` path, and `audit` only reports
  declared-hot violations, so it stays quiet by default. See [Automating checks](automating.md).

## 3. Scheduling and vectorization (surfaced, not controlled)

The gap that's left is instruction scheduling and vectorization, the layer that lives below your
code. StrictMode can't match rustc's instruction scheduler, and that's a deliberate non-goal
rather than a missing feature, so this section stays honest about the ceiling. What it can do is
make that layer visible and reachable:

- `@assert_vectorized f(args...)` asks, best-effort, whether the loop actually emitted SIMD vector
  ops (`<N x …>` in the LLVM IR), and fails loudly if it didn't.
- `@assert_effects f(args...) (:nothrow, :effect_free, …)` verifies the compiler's inferred effects
  (`Base.infer_effects`). It's the verify side of `Base.@assume_effects`.
- [`descend`](@ref)`(f, types)` drops you into [Cthulhu](https://github.com/JuliaDebug/Cthulhu.jl)
  to see inlining, effects, type-stability, and the LLVM/native code (an optional weak dependency).

!!! note "Validated on real SIMD kernels"
    `@assert_vectorized` works on the explicit-vector pattern that hand-tuned numeric code actually
    uses, `SIMD.jl`'s `Vec` `vload`/`vstore` over a preallocated buffer. Those `<N x double>` ops
    are emitted regardless of the build's CPU target, unlike `@simd` auto-vectorization, which is
    target-gated:

    ```julia
    using SIMD
    function vscale!(dst::Vector{Float64}, src::Vector{Float64})
        @inbounds for i in 1:8:length(src)
            vstore(vload(Vec{8,Float64}, src, i) * 2.0, dst, i)
        end
        return dst
    end
    @assert_vectorized vscale!(dst, src)   # passes — the loop emitted vector ops
    @assert_noalloc    vscale!(dst, src)   # …and stayed on the fast path
    ```

    Dogfooded against PureFFT.jl: `@assert_vectorized` confirms the leaf AVX compute kernels
    (`_base_butterflies_avx!`, `_fft128_avx!`) emit vector ops, and correctly reports that the
    top-level dispatcher (`apply_unnormalized!`) does not vectorize directly, since it just routes
    to those kernels. That's an honest, informative signal rather than a false positive, and
    `@assert_noalloc` confirms the kernels stay allocation-free.

### The ceiling, and the escape hatch

When the compiler's scheduling decisions are the bottleneck, the levers, in increasing order of
control, are:

| Lever | What it influences |
|---|---|
| `@inbounds`, `@simd ivdep` | removes bounds checks / asserts no loop-carried deps → enables vectorization |
| `Base.@assume_effects` | declares effects (`:nothrow`, `:consistent`, …) the compiler can build on |
| `Base.llvmcall` | hand-written LLVM IR, the final escape hatch for the hottest kernels |

StrictMode doesn't wrap these, since they're already in Base. What it adds is a way to keep your
escape-hatch kernels verifiable: assert that your `llvmcall` kernel is still allocation-free, and
`descend` into it to confirm the codegen:

```julia
# hand-written IR for a hot kernel…
addll(x::Int64, y::Int64) = Base.llvmcall("%z = add i64 %0, %1\nret i64 %z", Int64, Tuple{Int64,Int64}, x, y)

@assert_noalloc addll(2, 3)     # …still on the fast path
descend(addll, (Int64, Int64))  # …and see exactly what it compiled to
```

The honest summary: Julia with StrictMode is now about as easy to optimize as Rust for everything
except raw instruction scheduling, which stays rustc's domain and is reachable here only through
hand-written IR.

### Necessary, but not sufficient: `kernel_report`

Dogfooding a faer-style blocked Cholesky made the ceiling concrete. We had three trailing-update
(`syrk`) kernels: a naive `Vec` loop, a register-blocked one, and a `@turbo` one. All three pass
`@assert_vectorized`, `@assert_noalloc`, and `@assert_typestable` identically, and yet they differ
by about 2× (and roughly 6× against the base kernel). The correctness-style guarantees turn out to
be necessary but not sufficient: they confirm `<N x double>` is being emitted, but they say nothing
about register blocking, cache blocking, or the FLOP:byte ratio, which is exactly what separates a
toy SIMD loop from a real microkernel.

[`kernel_report`](@ref) is the answer. It's a non-failing performance diagnostic that reads the
arithmetic intensity (FP vector ops against memory vector ops) straight from the LLVM IR, so a
green-but-slow kernel can be seen to be memory-bound. That points you at the lever instead of
leaving you to discover it by benchmarking:

```julia
julia> kernel_report(syrk_naive!, (Matrix{Float64},))
KernelReport: syrk_naive!(Matrix{Float64})
  vectorized — `<8 x>`
  FP vector ops : memory vector ops = 8 : 12  → arithmetic intensity 0.67
  → memory-bound: streams more than it computes. Reuse loaded vectors across more FMAs
    (register blocking) and tile the reduction dimension (cache blocking).
```

It's heuristic and advisory, not a profiler or a roofline, but it surfaces the kind of problem
(memory- versus compute-bound) that the pass/fail guarantees structurally can't. Think of it as the
diagnostic layer sitting just beneath the guarantees.

The division of labor is worth stating plainly. The asserts defend the **floor**: the necessary
properties (vectorized, allocation-free, type-stable) whose loss costs you 2–100× silently. Staying
above that floor is necessary but not sufficient for peak performance — the **sufficiency** layer,
cache and register blocking and microkernel scheduling, still takes human roofline reasoning.
`kernel_report` is the first locality/intensity diagnostic aimed at that layer, and it's meant to
*complement* the guardrails, not replace them: keep asserting the invariants, and reach for the
diagnostic when something is green but still slow.

## Bonus: trim-safety (the static-binary story)

Rust's other predictability win is ahead-of-time compilation to a small static binary. Julia's
answer to that is `juliac --trim=safe`, which rejects dynamic dispatch and runtime reflection.
StrictMode surfaces it as one more guarantee, powered by
[TypeContracts](https://github.com/el-oso/TypeContracts.jl) (already a dependency, so no backend
needed):

- The proactive side: `@assert_trim_safe f(args...)`, or the `:trimsafe` guarantee in `check` and
  `audit`, scans the typed IR for the patterns the trimmer rejects before you sit through the slow
  build:
  ```julia
  audit(MyPkg; sweep = true, guarantees = (:typestable, :noalloc, :trimsafe))
  ```
- The reactive side: when a real `juliac --trim` run fails, [`explain_trim`](@ref) turns its cryptic
  verifier dump into a source-mapped explanation with per-site hints.

(`@assert_trim_safe` and `:trimsafe` are advisory, since juliac's whole-program verifier is the
authority, so like `@assert_vectorized` they're opt-in and not part of `@strict`.)
