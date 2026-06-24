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
code. StrictMode doesn't try to *control* instruction scheduling — that's a deliberate non-goal,
not a missing feature. (How high that ceiling actually is turned out to be a pleasant surprise —
see the honest summary below, where pure `SIMD.jl` beat a Rust library's hand-written assembly.)
What it can do is make that layer visible and reachable:

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

The honest summary: with StrictMode, idiomatic Julia is about as predictable to optimize as Rust —
and the ceiling is higher than this page first assumed. A later QR-factorization port found that
pure `SIMD.jl`, lowered by LLVM with **no** hand-written IR, matched and then **beat** a
state-of-the-art Rust library's hand-written **assembly** gemm (73 vs 70 GFLOP/s, single-thread)
once the kernel's memory orchestration matched. So raw instruction scheduling is not reliably
rustc's private domain: LLVM-from-idiomatic-`SIMD.jl` reached the same ceiling, and the residual
gap was **algorithmic** — how the surrounding code blocks and streams memory — which is human
roofline reasoning, not a language or codegen limit. The `Base.llvmcall` escape hatch stays
available and verifiable, but in that case it proved unnecessary (an inline-asm version was *slower*
than the SIMD.jl one).

!!! note "Scope of that claim"
    This is parity of *ceiling* on a specific kernel and machine — evidence that the
    language/codegen is not the bottleneck — **not** a claim that Julia is faster than Rust in
    general. The defensible statement is: where the Rust library was ahead, the cause was an
    algorithmic orchestration choice (portable to either language), not Rust, LLVM, or the
    algorithm; pure Julia reproduced it and pulled ahead. Most kernels matched the reference
    *bit-for-bit*; one SIMD reduction (`inner_prod`) did not, because reduction order is
    LLVM-codegen-defined — see [the promise scope](guarantees.md) on why bit-reproducibility is
    not a StrictMode guarantee.

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

Two additional signals complement intensity (F13):

- **Alignment** (`unaligned_mem_ops`): vector loads/stores whose recorded `align` annotation is
  less than the vector width in bytes — a proxy for buffer-alignment issues that can stall wide
  SIMD. A triangular loop that starts at the diagonal instead of the column base, for example,
  will show up here.
- **Masking** (`masked_mem_ops`): `@llvm.masked.*` intrinsics — a proxy for variable-length
  inner-loop trip counts (remainder tiling). Fixed-width tiles eliminate these.

For cache-residency context (F14/F15), pass `working_set_bytes`:

```julia
julia> kernel_report(syrk_naive!, (Matrix{Float64},); working_set_bytes = 8*64*64)
# → "L1-resident. Low intensity is acceptable at this size; memory-bound advice applies as n grows."

julia> kernel_report(syrk_tiled!, (Matrix{Float64},); working_set_bytes = 8*512*512)
# → "Good register intensity, but working set spills L3 — BLIS-style packing needed
#    for the cache-locality leg (beyond per-kernel IR analysis)."
```

The second case (F15) is the limit of what per-kernel IR inspection can guide: once the working
set exceeds L2 and register blocking is already good, closing the gap requires BLIS-style packing
of the panel operand — a memory-traffic decision above the single-kernel view. `kernel_report`
names the ceiling; the human has to cross it.

The default cache thresholds (L1=32 KiB, L2=512 KiB, L3=16 MiB) match a typical desktop/server.
Tune them with `StrictMode._CACHE_BYTES[] = (l1 = …, l2 = …, l3 = …)`.

The ceiling also shows up in algorithmic choices that sit above the per-kernel view. In a QR
factorization port, two versions of the same panel-gemm accumulation kernel were fully green on
every guarantee — vectorized, allocation-free, type-stable — yet differed by ~25% (58 vs 73
GFLOP/s). The difference was an orchestration choice: one version read the large operand in place;
the other packed it first to improve cache reuse. `@assert_vectorized` and `kernel_report` reported
identical results for both. The guarantees confirmed that each kernel was healthy at the LLVM-IR
level, but the performance gap lived above the per-kernel view, in how the surrounding code accessed
memory. (That faster, read-in-place version is the one that went on to beat the reference Rust
library's hand-written assembly — see the honest summary above. The point here is that StrictMode's
guarantees correctly certified *both* kernels as healthy and, rightly, stayed silent about the
orchestration choice that actually decided the race: that decision is the human's, and it sits above
what per-kernel IR inspection can see.)

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
