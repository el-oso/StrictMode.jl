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
| — | `proof_findings(f, types)` / `proof_findings(mod)` — proved, as data |
| — | `proof_audit(mod)` — proved, as data, formatted |
| — | `test_registered()` |

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
@test_strict
@test_kernel
```

### Gating drivers

```@docs
test_signatures
test_compiled
test_registered
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

