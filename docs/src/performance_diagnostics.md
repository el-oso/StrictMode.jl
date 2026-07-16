# Performance diagnostics

Green guarantees don't mean fast. `@assert_vectorized`, `@assert_noalloc`, and `@assert_typestable`
confirm that a kernel is on the right track — vectorized, allocation-free, type-stable — but they
say nothing about whether it's close to hardware capacity. This page covers the diagnostics that
live in the gap between "it's correct" and "it's fast."

## Checking for vectorization

[`@assert_vectorized`](@ref) checks whether a kernel's compiled body contains SIMD vector
operations (`<N x …>` in the LLVM IR). It works on the explicit-vector pattern that hand-tuned
numeric code actually uses — `SIMD.jl`'s `Vec` with `vload`/`vstore` over a preallocated buffer:

```julia
using SIMD
function vscale!(dst::Vector{Float64}, src::Vector{Float64})
    @inbounds for i in 1:8:length(src)
        vstore(vload(Vec{8,Float64}, src, i) * 2.0, dst, i)
    end
    return dst
end
@assert_vectorized vscale!(dst, src)   # passes — emits <8 x double>
@assert_noalloc    vscale!(dst, src)   # …and stays allocation-free
```

!!! note "Target the leaf, not the dispatcher"
    `@assert_vectorized` inspects the compiled body of the function you point it at directly. If a
    thin dispatcher calls vectorized kernels without inlining them, `@assert_vectorized` on the
    dispatcher will fail — the vector ops are in the callees, not in this body. Point it at the
    leaf kernels where the SIMD actually lives.

[`@assert_no_scalar_loops`](@ref) is the flip side: it checks that a numeric function does
*not* contain a scalar hot loop (a loop-carried `phi double` or `phi iN` with no vector ops). Use
it on functions where you expect auto-vectorization to kick in and want to be told if it doesn't.

## How fast is fast? `kernel_report`

A kernel can emit `<8 x double>` and still be slower than expected. The usual reason: it's moving
more memory than it's computing, so the bandwidth cost dominates. [`kernel_report`](@ref) reads the
LLVM IR and computes the arithmetic intensity — the ratio of compute operations to memory
operations — so you can see at a glance whether the kernel is compute-bound or memory-bound:

```julia
julia> kernel_report(syrk_naive!, (Matrix{Float64},))
KernelReport: syrk_naive!(Matrix{Float64})
  vectorized — `<8 x>`
  FP vector ops : memory vector ops = 8 : 12  → arithmetic intensity 0.67
  → memory-bound: streams more than it computes. Reuse loaded vectors across more FMAs
    (register blocking) and tile the reduction dimension (cache blocking).
```

The report is advisory, not a profiler. Think of it as a quick sanity check: a kernel with low
intensity is memory-bound and may benefit from data reuse strategies (register blocking, cache
tiling). A high-intensity kernel is compute-bound — the bottleneck is arithmetic, not bandwidth.

`kernel_report` also handles integer-SIMD kernels (byte compares, hashing, formatting). When there
are no floating-point vector ops, it falls back to counting integer vector arithmetic ops instead.

### Size context

Low arithmetic intensity is not always a problem. If the entire working set fits in L1 or L2
cache, a memory-bound kernel can still be fast because the loads are cheap. Pass
`working_set_bytes` to get a residency annotation:

```julia
kernel_report(my_kernel!, (Matrix{Float64},); working_set_bytes = 8 * 64 * 64)
# → "L1-resident. Low intensity is acceptable at this size;
#    memory-bound advice applies as n grows."

kernel_report(my_kernel!, (Matrix{Float64},); working_set_bytes = 8 * 512 * 512)
# → "working set spills L3 — BLIS-style packing needed for the cache-locality leg."
```

The default cache thresholds (L1=32 KiB, L2=512 KiB, L3=16 MiB) match a typical desktop. Override
them with `StrictMode._CACHE_BYTES[] = (l1 = …, l2 = …, l3 = …)`.

### Additional signals

`kernel_report` also reports several supplementary signals, each advisory:

**Unaligned memory ops** (`unaligned_mem_ops`): vector loads/stores whose alignment annotation is
below the vector width. Starting a vectorized loop partway through an aligned buffer — for example,
a triangular loop that starts at the diagonal — often shows up here. Misaligned loads can stall
wide SIMD.

**Masked ops** (`masked_mem_ops`): `@llvm.masked.*` intrinsics, indicating variable-length
inner-loop trips (remainder handling). Prefer fixed-width tiles when possible.

**Branches** (`branch_count`): conditional branches inside a vectorized kernel are candidates for
data-dependent misprediction. A branch that is 50/50 on real data costs ~10 cycles per call
regardless of vectorization. Consider `ifelse` or lookup tables for hot decisions.

**Serial dependency chains** (`serial_dep_count`): `div`, `rem`, or `sqrt` inside a loop where the
result feeds the next iteration. Each step must wait ~10–20 cycles for the previous one to finish —
the loop is latency-bound regardless of vectorization or branch prediction. Break the chain by
processing multiple elements per step (for example, `÷100` extracts two decimal digits at once
instead of one).

**Missing `noalias`** (`noalias_missing_count`): pointer parameters without the `noalias`
attribute. LLVM conservatively assumes two pointers may alias, which can limit vectorization across
iterations. Add `@simd ivdep` to assert no loop-carried dependencies.

**Fast-math ops** (`fastmath_ops`): FP arithmetic carrying LLVM fast-math flags (`contract`,
`reassoc`, `nnan`, `ninf`, `nsz`, `arcp`, `afn`, `fast`) — the result of `@simd`/`@fastmath`.
These permit floating-point reassociation and NaN/Inf assumptions that can change numerical
results, not just codegen, so `kernel_report`'s `show` prints a standing `⚠` warning whenever
`fastmath_ops > 0` rather than silently folding them into `fp_ops`. Verify against a non-fast-math
reference if bit-for-bit reproducibility matters.

## Register saturation: `register_report`

Even with good arithmetic intensity, a kernel can stall if it uses more vector registers than the
CPU has available, forcing the compiler to spill values to the stack. This is invisible to
`kernel_report` because it only reads LLVM IR — register allocation happens later.
[`register_report`](@ref) reads the native assembly instead:

```julia
julia> register_report(my_kernel!, (Matrix{Float64},))
RegisterReport: my_kernel!(Matrix{Float64})
  32/32 zmm registers, 53 spill(s)
  → register-saturated: all 32 zmm in use. Adding more ILP will spill and may regress.
    This is the LLVM portable-compiler ceiling (~85–87% of hand-asm).
```

A saturated reading is not a failure — it means the compiler has done everything it can. Any
attempt to add more work (wider tiles, more accumulators) will only create more spills. The
practical ceiling for pure `SIMD.jl` / LLVM on AVX-512 is roughly 85–87% of hand-written
assembly; reaching the last ~15% requires hand-written `.S` code.

A clean reading shows room to grow:

```julia
RegisterReport: my_kernel!(Matrix{Float64})
  12/32 zmm registers, 0 spill(s)
  → clean: 20 zmm free — room for more ILP or a wider tile.
```

`register_report` is meaningful only for x86-64 AVX-512 kernels; other targets return zeros.

## `@assert_no_spill` — the hard-gate sibling of `register_report`

`register_report` is advisory: it tells you a kernel is saturated, but it never fails. When you've
already identified a kernel as hot and want a permanent regression guard against a future edit
growing its live accumulator count past the register file, [`@assert_no_spill`](@ref) is the
codegen analogue of [`@assert_noalloc`](@ref) — unambiguous evidence of register pressure, not a
heuristic judgment call, so it's hard-gate-able where `register_report` deliberately isn't.

```julia
@assert_no_spill dtrsm_tile!(B, A)   # throws if the tile grew past the register budget
```

It reads the same post-register-allocation `code_native` output as `register_report`, but checks
for LLVM's `# ... Spill`/`# ... Reload` annotations on a line naming a vector (xmm/ymm/zmm)
register — syntax-independent (works whether `code_native` emitted AT&T or Intel syntax), unlike
a register-name regex tied to one syntax's operand punctuation. The programmatic form is
[`spill_report`](@ref), returning a [`SpillReport`](@ref).

## Steady-state throughput: `mca_report`

`kernel_report` and `register_report` both work from *static* IR — they can tell you a kernel is
vectorized and register-clean, but not whether its dependency chain lets the hardware actually
run at that rate. A kernel can be correct, vectorized, and register-clean and still be
*latency-bound* — e.g. a fused kernel whose accumulators form a long serial FMA chain, running at
a fraction of the throughput its instruction mix should allow. [`mca_report`](@ref) closes that
gap by running [`llvm-mca`](https://llvm.org/docs/CommandGuide/llvm-mca.html) — LLVM's static
throughput analyzer — on the kernel's own native assembly:

```julia
using LLVM_full_jll   # optional, ~680MiB weak dependency — see mca_available

r = mca_report(fma_kernel!, (Vector{Float64}, Vector{Float64}))
r.ipc                # steady-state instructions/cycle estimate
r.block_rthroughput   # cycles per iteration of the hot loop, at the hardware's real throughput
```

**Informational only — `@assert_mca` never fails on its own.** A naive whole-function `llvm-mca`
run models the entire function body as a single loop; a store→reload of the output pointer at the
function boundary then creates a *false* loop-carried dependency that serializes the estimate —
ground-truth runtime has disagreed with a naive run in exactly this shape. `mca_report` sidesteps
this by wrapping the detected innermost hot loop in region markers before handing it to
`llvm-mca`, but the region detection is a text heuristic (no real control-flow graph), so treat
the numbers as a relative signal, not an authoritative one. [`@assert_mca`](@ref) reflects that:
it only fails when you supply an explicit `max_rthroughput=`/`min_ipc=` bound yourself.

```julia
@assert_mca fma_kernel!(C, A, B)                # always passes; @info-logs the McaReport once
@assert_mca min_ipc=2.0 fma_kernel!(C, A, B)     # throws if steady-state IPC drops below 2.0
```

`-mcpu` defaults to the host's own (`Sys.CPU_NAME`), validated against what the bundled
`LLVM_full_jll` build actually recognizes — `llvm-mca`'s CLI hard-fails on an unrecognized `-mcpu`
(unlike Julia's own codegen path, which just warns and falls back), so `mca_report` checks first
and substitutes `"generic"` if needed, warning once.

## What the diagnostics can't see

Some performance problems are invisible to static IR analysis:

**Algorithmic choices above the kernel**: two kernel versions can look identical in IR — same
vectorization, same intensity — yet differ by 25% because one packs a panel operand into
contiguous memory before the inner loop. That kind of memory-orchestration choice is above the
per-kernel view.

**Input-distribution variance**: a search or formatting kernel may run 3× differently depending
on the input values — same code path, different data. Benchmark across the value classes your
kernel will actually see (small, large, uniform, worst-case) and report the spread rather than a
single median.

**Data-dependent load addresses**: a kernel that computes a slot index from a SIMD reduction and
then loads `array[index]` exposes the full cache-miss latency of that load — the load can't issue
until the reduction finishes. The guarantees are all green, but effective throughput may be limited.

The division of labor: the asserts defend the **floor** (vectorized, allocation-free,
type-stable) — properties whose loss costs 2–100× silently. The diagnostics (`kernel_report`,
`register_report`) illuminate the **ceiling** — they help you see how far you are from the
hardware limit, and why. Neither closes every gap; some require roofline reasoning or restructuring
the algorithm above the single-kernel view.

## Static-binary compatibility (`@assert_trim_safe`)

Julia's ahead-of-time compiler (`juliac --trim=safe`) rejects dynamic dispatch and runtime
reflection. StrictMode can flag incompatible patterns before a slow `juliac` build reveals them:

```julia
@assert_trim_safe my_kernel(a, b)   # fails if the compiled body would be rejected by --trim
audit(MyPkg; sweep = true, guarantees = (:typestable, :noalloc, :trimsafe))
```

When a real `juliac --trim` run fails, [`explain_trim`](@ref) translates the verifier output into
source-mapped hints with per-site suggestions.
