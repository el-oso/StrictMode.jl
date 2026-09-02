# StrictModeTest.jl

The proof tier for [StrictMode.jl](https://github.com/el-oso/StrictMode.jl). Add it to a **test**
environment; it is not meant to be a runtime dependency.

[StrictMode](../StrictMode) analyses code with a value-free engine — inferred return types plus a
scan of typed IR — and depends on no analysis backend at all, so it **reports**. StrictModeTest has
AllocCheck, JET and TrimCheck as hard dependencies and **gates**: its checks throw, so a violation
fails the build.

Which engine runs is the macro you wrote, decided when it expands:

| reports (StrictMode) | proves and throws (StrictModeTest) |
|---|---|
| `@assert_noalloc` | `@test_noalloc` — AllocCheck's all-paths proof |
| `@assert_noboxing` | `@test_noboxing` |
| `@assert_typestable` | `@test_typestable` — adds `JET.@report_opt` |
| `@assert_trim_compatible` | `@test_trim_compatible` — juliac's own `verify_typeinf_trim` |

There is no mode to switch and no ambient state selecting between them.

Beyond the macros it adds the drivers that gate a whole module — `test_signatures`,
`test_compiled`, `test_registered` — plus `proof_audit` for reporting and `divergence_report`,
which compares the two engines and therefore needs both.

```julia
# test/Project.toml:  [deps] StrictMode, StrictModeTest
using StrictMode, StrictModeTest

@test_noalloc kernel!(C, A, B)     # throws if AllocCheck finds any allocating path
test_compiled(MyPkg)               # gate everything the module actually compiled
```

Documentation for both packages lives at
<https://el-oso.github.io/StrictMode.jl/dev/>; the proof surface is on the
[API reference](https://el-oso.github.io/StrictMode.jl/dev/api) page.

Loading it while checks are disabled is an error rather than a silent pass: with
`StrictMode.checks_enabled()` false every `@assert_*` is a bare call and nothing registers, so
`test_registered()` would sweep an empty registry and report success.
