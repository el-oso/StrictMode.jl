# StrictModeTest — the proofs

`StrictMode` reads inferred types and typed IR. It needs no other package, which is what makes it
safe to depend on from `src` — and why its allocation verdicts **report**: typed IR still shows
allocations LLVM later deletes, so there they can only say something looks wrong.

`StrictModeTest` is the other half. It goes in your **test** environment, brings AllocCheck, JET and
TrimCheck, and **throws** — a violation fails the build. Keeping them apart means your users never
install those backends just to use your package.

```julia
# test/Project.toml:  [deps] StrictMode, StrictModeTest
using StrictMode, StrictModeTest

@test_noalloc kernel!(C, A, B)     # throws if AllocCheck finds any allocating path
test_compiled(MyPkg)               # gate everything the module actually compiled
```

The macro you write picks the engine. There is no mode to switch.

| report (StrictMode) | prove and gate (StrictModeTest) |
| --- | --- |
| `@assert_noalloc f(x)` | `@test_noalloc f(x)` |
| `@assert_noboxing f(x)` | `@test_noboxing f(x)` |
| `@assert_typestable f(x)` | `@test_typestable f(x)` |
| `@assert_trim_compatible f(x)` | `@test_trim_compatible f(x)` |
| `@strict f(x)` | `@test_strict f(x)` |
| `@kernel f(x)` | `@test_kernel f(x)` |
| `findings(f, types)` | `test_signatures(pairs)` |
| `audit(mod; sweep = true)` | `test_compiled(mod)` |
| — | `@test_steady_state f(x)` — allocation that STOPS once warmed, measured |
| — | `@test_no_gc_pause f(x)` — no collection runs while the call does, measured |
| — | `proof_findings(f, types)` / `proof_findings(mod)` — proved, as data |
| — | `proof_audit(mod)` — proved, as data |
| — | `test_registered()` |
| `audit(mod; require = :all)` | `test_coverage(mod)` — every method declared or visibly exempt |
| — | `test_exemptions(mod)` — an opt-out the proofs no longer need |
| — | `test_calls(mod)` — every reachable call resolves, including on a branch no test takes |
| — | `test_layers(L => (deps…), …)` — a declared layer graph holds, both ways |
| — | `test_latency(pkg)` — load time and first-call time, measured in a fresh process |
| — | `test_no_unsafe(mod)` — no `ccall`, `pointer` or `unsafe_*`, with a named allow list |
| `specialization_report(mod)` | `test_specializations(mod; baseline, workload)` — the count's GROWTH against a baseline |

### Failing on a specialization budget

[`test_specializations`](@ref) gates the **growth** of a compiled-specialization count against a
stored baseline, because there is no threshold that is right for every package — which is also why
[`specialization_report`](@ref) is `:info` and cannot fail anything on its own.

When a project has decided on a number, the report gates it with no extra machinery, because the
report already takes the limit:

```julia
@test isempty(specialization_report(MyPkg; max_specializations = 256, max_type_depth = typemax(Int)))
```

That fails the suite on any method over the budget, and the findings name which ones — sorted by
count, highest first. The report judges two limits, so pin the one you do not mean to gate:
`max_type_depth` defaults to 4 and would otherwise fail the same assertion for a reason that has
nothing to do with the specialization count. Use the growth gate to catch a regression against whatever is true today, and
the line above to hold a number the project has agreed to. They answer different questions and
compose.

```@meta
CurrentModule = StrictModeTest
```

```@docs
StrictModeTest.StrictModeTest
```

## Proving macros

```@docs
@test_noalloc
@test_noboxing
@test_typestable
@test_trim_compatible
@test_steady_state
@test_no_gc_pause
@test_strict
@test_kernel
```

### Gating drivers

```@docs
test_signatures
test_compiled
test_registered
test_coverage
test_exemptions
test_calls
test_layers
test_latency
test_no_unsafe
test_specializations
```

### Proofs as data

```@docs
proof_findings
proof_audit
AnalysisError
```

### Barriers, juliac patches, and engine divergence

`ignore_barrier` / `set_ignore_barrier!` decide whether a recognized one-time-init barrier is exempt
from AllocCheck's all-paths proof. `divergence_report` / `StrictDivergence` run both engines on one
signature and capture an **IP-free** record of any disagreement — anonymized signature shape, signal
*categories*, and versions only — that you can send to the maintainers to fix the scan.

```@docs
ignore_barrier
set_ignore_barrier!
juliac_patches
set_juliac_patches!
divergence_report
StrictDivergence
save_divergence
```

