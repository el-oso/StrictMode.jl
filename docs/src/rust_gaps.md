# Closing the gaps with Rust

Rust makes idiomatic code reliably fast: the compiler errors (or the type system guarantees)
where Julia stays silent. StrictMode set out to make Julia *as predictable to optimize* — and
dogfooding a SIMD FFT located exactly three gaps. Here is each gap and the feature that closes it.

## 1. The time tax — *closed*

Rust's guarantees are free; StrictMode's used to cost an AllocCheck pass per method (a
whole-package sweep once blew a 10-minute timeout). Now:

- **`:fast` mode** is a value-free, inference-only triage of *all* properties — allocation,
  boxing, type-stability — built on `code_typed` IR + `Base.infer_effects`. It needs **no
  AllocCheck/JET backend** and runs **~10× cheaper per method** than `:full`. `:full` remains the
  rigorous AllocCheck proof for CI.
- An **incremental cache** keys findings on `(method, world, signature, mode)`, so re-running
  `audit` after a one-method edit only re-analyzes that method — near-instant.
- `:fast` sweeps run **across threads**.

A whole-module re-check on every edit is now affordable. See [Getting Started](getting_started.md).

## 2. Opt-in, not pervasive — *closed*

Rust disciplines *every* function by default; you opt out of safety, not into it. StrictMode now
mirrors that:

- **`@strict module … end`** — one declaration makes every function in the module hot (checked)
  automatically. No per-function annotations.
- **`@strict_exempt`** — the rare cold / by-design-allocating helper opts *out* at its definition.
- The whole-module load check uses the cheap `:fast` path, and `audit` reports only declared-hot
  violations — so it's quiet by default. See [Automating checks](automating.md).

## 3. Scheduling & vectorization — *surfaced, not controlled*

The residual gap is instruction scheduling and vectorization, which live **below** user code.
StrictMode **cannot** match rustc's instruction scheduler — that is an explicit non-goal, and
this section is honest about the ceiling. What it *can* do is make the layer visible and reachable:

- **`@assert_vectorized f(args...)`** — best-effort: did the loop emit SIMD vector ops
  (`<N x …>` in the LLVM IR)? Loud failure if it didn't.
- **`@assert_effects f(args...) (:nothrow, :effect_free, …)`** — verify the compiler's inferred
  effects (`Base.infer_effects`); the *verify* side of `Base.@assume_effects`.
- **[`descend`](@ref)`(f, types)`** — drop into [Cthulhu](https://github.com/JuliaDebug/Cthulhu.jl)
  to *see* inlining, effects, type-stability, and the LLVM/native code (optional weak dependency).

### The ceiling, and the escape hatch

When the compiler's scheduling decisions are the bottleneck, the levers — in increasing order of
control — are:

| Lever | What it influences |
|---|---|
| `@inbounds`, `@simd ivdep` | removes bounds checks / asserts no loop-carried deps → enables vectorization |
| `Base.@assume_effects` | declares effects (`:nothrow`, `:consistent`, …) the compiler can build on |
| `Base.llvmcall` | hand-written LLVM IR — the final escape hatch for the hottest kernels |

StrictMode does not wrap these (they are Base); its contribution is to keep your escape-hatch
kernels **verifiable** — assert your `llvmcall` kernel is still allocation-free, and `descend`
into it to confirm the codegen:

```julia
# hand-written IR for a hot kernel…
addll(x::Int64, y::Int64) = Base.llvmcall("%z = add i64 %0, %1\nret i64 %z", Int64, Tuple{Int64,Int64}, x, y)

@assert_noalloc addll(2, 3)     # …still on the fast path
descend(addll, (Int64, Int64))  # …and see exactly what it compiled to
```

**The honest summary:** Julia + StrictMode is now as easy to optimize as Rust for *everything
except raw instruction scheduling* — which remains rustc's domain, reachable here only through
hand-written IR.
