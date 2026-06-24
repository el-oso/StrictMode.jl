# StrictMode.jl — contributor context for Claude

## What this is

StrictMode.jl is a Julia package that makes performance guarantees (no allocations, type
stability, vectorization) enforceable at dev/CI time and free in production. The macros
expand to the bare call when checks are off; they run JET + AllocCheck analysis when on.

## Key architecture

```
src/
  StrictMode.jl       — module root, exports
  macros.jl           — @assert_noalloc, @assert_typestable, @assert_noboxing, @assert_inlined
  typestability.jl    — _typestable_check_expr, @assert_typestable internals
  effects.jl          — @assert_effects, fast-mode heuristics (_alloc_signals, _boxing_signals)
  scheduling.jl       — @assert_vectorized, kernel_report, KernelReport, _CACHE_BYTES
  strict.jl           — @strict (composite guarantee), @kernel (SIMD shorthand)
  strict_function.jl  — @strict_function (load-time enforcement), @strict_contract
  registry.jl         — @strict_function registry, _demangle (kwsorter name stripping)
  check.jl            — check/findings/check_all/check_compiled/audit (batch drivers)
  findings.jl         — StrictFinding struct, format_findings, nfailures
  explain.jl          — @explain, StrictReport
  cache.jl            — (method, world, signature, mode) → findings cache
  report.jl           — StrictViolation exception
  preferences.jl      — checks_enabled, fail_mode, analysis_mode, enable_checks!
  unroll.jl           — @unroll, staticval (fix for heterogeneous-tuple boxing)
  trimsafe.jl         — @assert_trim_safe, explain_trim (juliac --trim gate)
ext/
  StrictModeAnalysisExt.jl  — AllocCheck + JET backend (weak dep, loaded on `using AllocCheck, JET`)
  StrictModeCthulhuExt.jl   — descend() fills _CTHULHU_DESCEND
  StrictModeReviseExt.jl    — cache invalidation on code change
test/
  runtests.jl         — uses ReTestItems.runtests(StrictMode); loads AllocCheck+JET backend
  Project.toml        — has [preferences.StrictMode] checks_enabled=true, fail_mode="error"
  round5_test.jl      — kernel_report / @assert_vectorized (F10–F15)
  kernel_test.jl      — @kernel macro
  *_test.jl           — one file per guarantee
```

## Running tests

```bash
julia --project=test -e 'import Pkg; Pkg.instantiate()'
julia --project=test test/runtests.jl
```

The test `Project.toml` enables checks and loads the AllocCheck/JET backend. Tests use
`@testitem` (ReTestItems.jl). Run a single item by name with:

```bash
julia --project=test -e 'using ReTestItems, StrictMode, AllocCheck, JET; runtests(StrictMode; name=r"F10")'
```

## Key invariants

- **No Python**. No PythonCall/PyCall, no pip deps.
- **No new main-Project.toml deps** for test-only packages — those go in `test/Project.toml`.
- `_gate(checked, fallback)` in `macros.jl` is the zero-cost expansion switch — every macro routes through it. The `checks_enabled` preference is a compile-time const baked at precompile; changing it requires a restart.
- AllocCheck/JET are **weak deps** (`[weakdeps]` in Project.toml, loaded via extension). Never import them unconditionally from `src/`.
- `_demangle(sym)` in `registry.jl` strips `#foo#NN` kwsorter mangling so `only`/`exempt` match keyword-argument functions correctly.
- `ignore_throw = true` is the default for AllocCheck calls — throw-path allocations don't count.
- `kernel_report` and `@assert_vectorized` work from `InteractiveUtils.code_llvm` — no backend needed. `_CACHE_BYTES` is a tunable `Ref` for cache-residency annotation thresholds.

## FEEDBACK.md

Documents dogfooding findings (F1–F20) from PureFFT.jl and BlazingPorts.jl/QR campaign.
All findings are now ✅. Update the status table when closing a finding.
