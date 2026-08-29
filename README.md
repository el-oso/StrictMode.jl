# StrictMode.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/StrictMode.jl/dev/)
[![CI](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml)
[![Coverage](https://coveralls.io/repos/github/el-oso/StrictMode.jl/badge.svg?branch=master)](https://coveralls.io/github/el-oso/StrictMode.jl?branch=master)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**The fast path should be the default, and leaving it should be loud, not something you discover
later with a profiler.**

Julia will happily let your code box a value, miss an inline, drift into a type instability, or
allocate inside a hot loop, and say nothing about it. Rust would have stopped you at compile time.
StrictMode lets you ask for those properties out loud: attach a macro, and the code either holds
the property or fails, at test time or even at module load.

> StrictMode grew out of a JuliaCon 2024 talk, *"Why do we need a stricter Julia mode?"* The traps
> that kept coming up turned up while tuning a SIMD FFT, where indexing a tuple with a runtime value
> quietly boxed and cost a measured **135× slowdown** — the kind of thing you only find by profiling.

It covers both halves of the job. There's the forcing half, which pushes your code onto the fast
path, and the telling half, which speaks up when you've fallen off it. StrictMode itself analyzes
with a value-free engine built on Base's own inference — no heavy dependencies at all — and the
rigorous proofs from [AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl) and
[JET.jl](https://github.com/aviatesk/JET.jl) live in a companion package you add to `test/`.

## Two packages: one reports, one gates

There is no preference to switch between "quick" and "rigorous", and no ambient state deciding
which engine runs. **The macro you wrote is the engine.**

| Environment | Add | What you get |
|---|---|---|
| **Production** | nothing | `disable_checks!()` → macros are bare calls |
| **Your `Project.toml`** | `StrictMode` | `@assert_*`: a value-free scan, no backend, cheap enough to run at load time |
| **Your `test/Project.toml`** | `+ StrictModeTest` | `@test_*` and `test_*`: AllocCheck + JET + TrimCheck |

```julia
# Project.toml            [deps] StrictMode
@assert_noalloc kernel!(C, A, B)     # value-free scan; warns on a violation

# test/Project.toml       [deps] StrictMode, StrictModeTest
@test_noalloc kernel!(C, A, B)       # AllocCheck's all-paths proof; throws on a violation
```

Nothing in `StrictMode` can break a build. Its `noalloc`/`noboxing` verdicts come from a scan of
typed IR, where an allocation LLVM will later elide is still present — measured ~28% false on a real
consumer — and a check that guesses must not be able to abort a build. So those report. The
guarantees whose check *observes* compiled output rather than inferring about it (`typestable`'s
return-type layer, `memsafe`, `vectorized`, `no_spill`, …) do throw.

`StrictModeTest` is the authority: `@test_*` for a call site, and `test_signatures` /
`test_compiled` / `test_registered` for a whole scope — each collects every failure and raises once,
so one unanalyzable method never leaves the rest unchecked.

## Zero cost when disabled

Every check sits behind a [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl)
compile-time flag, on by default so a dev or test environment needs no setup. Turn it off for a
shipped application and every guarantee macro expands to the bare call, so the deployment pays
nothing:

```julia
using StrictMode
StrictMode.disable_checks!()      # writes LocalPreferences.toml; restart Julia to apply
StrictMode.enable_checks!()       # back on
```

```julia
# checks ON  →  @assert_noalloc f(x)  expands to a guarded check
# checks OFF →  @assert_noalloc f(x)  expands to exactly  f(x)
```

## Quick start

```julia
using StrictMode   # (with checks enabled)

@assert_noalloc    sum(rand(100))        # fails if the call provably/empirically allocates
@assert_typestable muladd(2.0, 3.0, 1.0) # fails on type instability (return type or internals)
@strict            dot(u, v)             # all per-call guarantees at once; returns the value
```

## Before / after

**Before:** a hot kernel that boxes behind your back. Nothing warns you, and you only notice once
you profile:

```julia
component(state, i) = state[i]        # state::Tuple{Int,Float64,String}, i is a runtime value
#                     ^ runtime tuple index → Union return → boxing → 135× slower, silently
```

**After:** the same kernel, guarded. The violation is loud now, and it points right at the cause:

```julia
@assert_typestable component(state, rand(1:3))
# ERROR: StrictViolation (@typestable): guarantee not satisfied
#   target:  component(state, rand(1:3))
#   reason:  return type is not concretely inferrable: ... Union{Int64,Float64,String}
```

## What it guarantees, and what it doesn't

Think of StrictMode as **guardrails**, not a performance oracle. The asserts defend the *necessary*
properties of a hot kernel, the floor below which you're definitely leaving time on the table:

- `@assert_vectorized` — the loop still emits `<W x double>`
- `@assert_noalloc` — no heap traffic on the hot path
- `@assert_typestable` — concrete types, no boxing

These are the failures that cost 2–100× silently and that you'd otherwise catch commits later in a
noisy benchmark: a tuple indexed by a runtime variable that starts boxing, a type instability that
creeps in, a refactor that quietly breaks SIMD codegen. StrictMode turns each one into a loud
failure at the moment you introduce it. Three things follow:

1. **Silent becomes loud.** A regression throws where it's written, not in production.
2. **The invariant gets pinned.** Once an assert is in place it fences every future edit, so you
   can experiment aggressively — tile, block, rewrite the kernel — and hear about it the instant you
   cross the line.
3. **Intent lands on the page.** An assert says "this is a load-bearing hot kernel, and these
   properties must hold," for whoever reads it next.

What it does **not** do is promise you're fast. These properties are necessary, not sufficient.
Dogfooding a pure-Julia Cholesky against [faer](https://github.com/sarah-quinones/faer-rs) made the
boundary concrete: naive, hand-tiled, and `@turbo` versions of the same trailing-update kernel *all*
passed the same asserts, yet spanned roughly **0.24×–0.47×** of faer, because no per-call assert can
see cache and register blocking, leading-dimension conflicts, or microkernel scheduling. That
sufficiency layer still needs human roofline reasoning. [`kernel_report`](https://el-oso.github.io/StrictMode.jl/dev/rust_gaps)
is the first diagnostic aimed at it — it reads arithmetic intensity from the IR, so a green-but-slow
kernel shows up as memory-bound — and it's meant to *complement* the guardrails, not replace them.

## The "won't load if it's wrong" guarantee

`@strict_function` checks a definition against its declared argument types at precompile time. If
the contract is broken, the module won't load. It's the same forcing function Rust's compiler gives
you:

```julia
@strict_function dot3(a::NTuple{3,Float64}, b::NTuple{3,Float64}) =
    a[1]*b[1] + a[2]*b[2] + a[3]*b[3]    # loads: type-stable + non-allocating

@strict_function leaky(n::Int) = sum(collect(1:n))
# ERROR at load: StrictViolation (@strict_function): call provably allocates ...
```

## Interfaces + performance, together

Pair a [TypeContracts.jl](https://github.com/el-oso/TypeContracts) interface with StrictMode's
performance guarantees. `@contract` checks that the right methods are there; StrictMode checks that
they're fast.

```julia
@strict_contract AbstractMetric begin
    score(::Self, xs::AbstractVector{<:Real})::Real
end

m = MyMetric(); xs = rand(100)
@verify_strict MyMetric begin   # checks the interface AND that score is stable + non-allocating
    score(m, xs)
end
```

## Automation & agents

Per-call macros aren't the only way in. StrictMode can also check on its own:

```julia
findings(f, (T1, T2))              # function API — never collides with other macros/syntax
@strict module Kernels … end       # mark a module; checked automatically when it loads
StrictMode.watch()                 # live re-checking on each edit (with `using Revise`)
audit(MyPkg; format = :json)       # one-shot, structured report — for AI agents and the dev loop
audit(MyPkg; require = :public)    # coverage gate: FAIL any public function with no declared guarantee
assert_enabled()                   # first line of your strictmode tests: errors under CI if checks are off

# …and from the test environment, where StrictModeTest supplies the proofs:
test_signatures([(f, (T1, T2))])   # gate an explicit list of signatures
test_compiled(MyPkg)               # gate whatever actually compiled
test_registered()                  # re-prove everything @strict_function declared
```

`audit` emits machine-readable findings (with a `file`, `line`, `reason`, and an actionable
`suggestion` per violation) and returns them. `require = :public` and `assert_enabled()` make
non-use loud: an unregistered public function, or a CI run with checks silently disabled, is a red
build instead of a vacuous green. See
[Automating checks](https://el-oso.github.io/StrictMode.jl/dev/automating) and
[Agentic feedback](https://el-oso.github.io/StrictMode.jl/dev/agents).

## Checking a library *without* depending on StrictMode

You can gate a library's performance from its test suite, without ever adding StrictMode to its
`src`:

1. Add `StrictMode` and `StrictModeTest` to the **test** `Project.toml`. Nothing goes in your
   package's own `Project.toml` unless you also want load-time checks there.
2. Nothing else to configure: `checks_enabled` defaults to `true`, and `StrictModeTest` refuses to
   load if something has turned it off — a suite that silently disarmed would pass vacuously.
3. List the guaranteed entry points — no `src` annotations needed:
   ```julia
   using StrictMode, StrictModeTest
   test_signatures([(dot3, (NTuple{3,Float64}, NTuple{3,Float64})), (kernel!, (Matrix{Float64},))])
   ```
   Or sweep what actually compiled, scoping out cold/plan-time helpers with a regex or predicate:
   ```julia
   test_compiled(MyPkg; exempt = r"^_plan")
   ```

The choice between the two is the main trade-off. A signature list is targeted and says what you
promised; a sweep is broad but noisy, since it covers whatever happened to compile. Annotate the hot
kernels, or sweep everything and exempt the rest.

## API

| Macro / function | Guarantee |
|---|---|
| `@assert_noalloc f(args...)` | report if the call allocates (value-free IR scan, or `@allocated` with `static=false`) |
| `@assert_noboxing f(args...)` | forbid boxing / dynamic dispatch, but **allow** legitimate buffer allocation |
| `@assert_owned f(args...)` | fail on a runtime `AbstractDict` lookup on the hot path (GKH-ownership: an owned scratch/workspace must resolve via a const-dispatched accessor, not a keyed probe) |
| `@assert_typestable f(args...)` | concrete return type (throws) + an internal-dispatch IR signal (warns) |
| `@assert_inlined f(args...)` | fail unless the call is inlined (best-effort; not part of `@strict`) |
| `@assert_vectorized f(args...)` | fail unless the loop SIMD-vectorized (best-effort, LLVM IR scan) |
| `@assert_no_scalar_loops f(args...)` | fail if a scalar (non-vectorized) hot loop is detected between audited kernels (best-effort) |
| `@assert_effects f(args...) (…)` | verify the compiler's inferred effects (`Base.infer_effects`) |
| `@assert_trim_safe f(args...)` | fail on dynamic dispatch / reflection that `juliac --trim=safe` rejects (`:trimsafe` guarantee; static scan only) |
| `@assert_trim_compatible f(args...)` | the same static scan, under the name that pairs with `@test_trim_compatible` (juliac's authoritative verifier) |
| `@assert_concurrency_safe f(plan, args...)` | fail unless `f` treats its plan arg as read-only (no write of, or through, the plan) — proof that one plan is safe to share across concurrent tasks |
| `@assert_no_threadid_state f(args...)` | fail on mutable state indexed by `Threads.threadid()` (the task-migration hazard) |
| `descend(f, types)` | drop into Cthulhu to *see* inlining/effects/LLVM (weak dep) |
| `kernel_report(f, types)` | performance-quality diagnostic (not pass/fail): arithmetic intensity, alignment/masking, branch/serial-dep/noalias/shuffle/prefetch signals, and fast-math-flag usage, read from LLVM IR |
| `register_report(f, types)` | post-register-allocation diagnostic: zmm register usage and spills from `code_native` (x86-64 AVX-512) |
| `explain_trim(output)` | translate raw `juliac --trim` verifier output into a source-mapped explanation |
| `@golden name expr` | gated bit-exact (or ULP-tolerant) regression harness for numeric kernels; always runs regardless of `checks_enabled` |
| `@strict f(args...)` | all per-call guarantees at once; returns the call's value |
| `@strict_function def` | verify the definition's contract at precompile time |
| `@strict_contract I begin … end` | declare a TypeContracts interface carrying perf guarantees |
| `@verify_strict T begin … end` | verify an implementation's surface *and* performance |
| `@explain f(args...)` | aggregate `@code_warntype`, the inferred return type, and the IR signals into one "why did it fail" report (never throws) |
| `@unroll for i in lo:hi …` | fully unroll a fixed-count loop with literal indices (kills runtime-tuple-index boxing); not gated |
| `staticval(n)` | lift a count into the type domain (`Val{n}`) for compile-time specialization |
| `findings(f, types)` | function API — guarantees on a `(function, signature)`, no macro interference |
| `@strict module … end` | mark a whole module; checked automatically at load |
| `audit` / `watch` | structured one-shot report for agents / live Revise loop for humans |
| `@test_noalloc` / `@test_noboxing` / `@test_typestable` / `@test_trim_compatible` | **StrictModeTest**: the proofs of the same properties, and they throw |
| `test_signatures` / `test_compiled` / `test_registered` | **StrictModeTest**: gate a signature list / what actually compiled / the registry |
| `divergence_report(f, types)` | **StrictModeTest**: compare the scan's and the proof's verdicts for a signature; `save_divergence` persists a corpus sweep |
| `pool_balance_report(...)` | diagnostic for `@assert_no_threadid_state`-adjacent thread-pool balance questions |
| `enable_checks!` / `disable_checks!` / `checks_enabled` | toggle / query the compile-time gate |

Every guarantee macro also accepts **keyword-argument calls** — `@assert_noalloc trsm!(B, A; side='L')`
(routed through `Core.kwcall`, so a keyword public API is guaranteed directly) — and a **`types = (…)`
signature override** — `@assert_typestable f(Float64) types=(Type{Float64},)` — to pin the analyzed
specialization when `typeof.(args)` would widen a type-argument function to a false positive.

See the [documentation](https://el-oso.github.io/StrictMode.jl/dev/) and
`docs/src/cookbook.md` for the trap → macro mapping.

### Status
Working through the [three gaps with Rust](https://el-oso.github.io/StrictMode.jl/dev/rust_gaps):
the time tax (a cheap value-free triage over all properties, plus an incremental cache), staying
opt-in (`@strict module` checks everything automatically, and `@strict_exempt` opts cold code out),
and scheduling visibility (`@assert_vectorized`, `@assert_effects`, and Cthulhu's `descend`). It all
sits on an ergonomics layer (`findings`, `audit`, `watch`) over the guarantee set.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/el-oso/StrictMode.jl")
```

## License

MIT.
