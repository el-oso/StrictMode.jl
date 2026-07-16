# StrictMode.jl — contributor context for Claude

## What this is

StrictMode.jl is a Julia package that makes performance guarantees (no allocations, type
stability, vectorization) enforceable at dev/CI time and free in production. The macros
expand to the bare call when checks are off; they run JET + AllocCheck analysis when on.

## Key architecture

```
src/
  StrictMode.jl       — module root, exports, top-level docstring
  macros.jl           — @strict (composite guarantee), @kernel (SIMD shorthand)
  preferences.jl      — checks_enabled/analysis_mode/enable_checks!/disable_checks!, _gate (the
                        zero-cost compile-time expansion switch), and the shared macro-parsing
                        plumbing every guarantee macro uses: _callinfo/_call_parts/_macro_call
  static_checks.jl    — @assert_noalloc, @assert_noboxing, @assert_owned
  typestability.jl    — @assert_typestable, _typestable_check_expr/_typestable_fast
  inlining.jl         — @assert_inlined, inline_suggestions (module-sweep advisory)
  effects.jl          — _alloc_signals (the `:fast`-mode value-free IR heuristic engine used by
                        noalloc/noboxing/owned), @assert_effects internals, _DICT_ACCESSORS
  scheduling.jl       — @assert_vectorized, @assert_effects, @assert_no_scalar_loops,
                        @assert_no_spill, kernel_report/KernelReport, register_report/RegisterReport,
                        spill_report/SpillReport, descend, _CACHE_BYTES
  static_ownership.jl — static_ownership_suggestions (module-sweep GKH-ownership advisory)
  concurrency.jl      — @assert_concurrency_safe, @assert_no_threadid_state, pool_balance_report
  strict_function.jl  — @strict_function (load-time enforcement), @strict_exempt
  contracts.jl        — @strict_contract, @verify_strict (pairs a TypeContracts interface with
                        StrictMode performance guarantees)
  registry.jl         — @strict_function registry, check_all/check_compiled, register_strict!,
                        watch/unwatch, _demangle (kwsorter name stripping)
  audit.jl            — audit (single entry point wrapping check_compiled/check_all)
  check.jl            — check/findings/_build_finding/_findings_fast — the interference-proof
                        core every guarantee funnels through: no macro parsing, no execution
  findings.jl         — StrictFinding struct, format_findings, nfailures
  explain.jl          — @explain, StrictReport
  divergence.jl       — divergence_report/StrictDivergence (fast-vs-full comparison), save_divergence
  cache.jl            — (method, world, signature, mode) → findings cache
  report.jl           — StrictViolation exception
  backend.jl          — AllocCheck/JET backend glue (_be_*), _require_backend, set_ignore_throw!
  idioms.jl           — @unroll, staticval (fix for heterogeneous-tuple boxing)
  golden.jl           — @golden (gated bit-exact / ULP-tolerant regression harness)
  trimsafe.jl         — @assert_trim_safe, @assert_trim_compatible, explain_trim (juliac --trim gate)
  memsafe.jl          — @assert_memsafe, memsafe_report/MemsafeReport, _guarded_array/GuardedBuffer
                        (mmap/mprotect guard-page harness for deterministic OOB read/write detection;
                        isolate=true runs the probe in a subprocess via Serialization + Base.run)
ext/
  StrictModeAnalysisExt.jl  — AllocCheck + JET backend (weak dep, loaded on `using AllocCheck, JET`)
  StrictModeCthulhuExt.jl   — descend() fills _CTHULHU_DESCEND
  StrictModeCpuIdExt.jl     — CPU-specific _CACHE_BYTES override (weak dep, `using CpuId`)
  StrictModeReviseExt.jl    — cache invalidation on code change
  StrictModeTrimExt.jl      — TrimCheck-backed juliac --trim=safe verifier (weak dep, `using TrimCheck`)
test/
  runtests.jl         — uses ReTestItems.runtests(StrictMode); loads AllocCheck+JET backend
  Project.toml        — has [preferences.StrictMode] checks_enabled=true, fail_mode="error"
  round5_test.jl      — kernel_report / @assert_vectorized (F10–F15, F38)
  kernel_test.jl      — @kernel macro
  *_test.jl           — one file per guarantee
```

This table is a map, not a promise — when adding/moving a top-level definition, update the entry for
the file you touched rather than trusting this list; it has drifted before (verify with `ls src/`).

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
- `_gate(checked, fallback)` in `preferences.jl` is the zero-cost expansion switch — every macro routes through it. The `checks_enabled` preference is a compile-time const baked at precompile; changing it requires a restart.
- `@contract`-style macro headers in the sibling TypeContracts package can't be module-qualified (e.g. `@contract Base.AbstractLock` fails to parse — needs `import Base: AbstractLock` first) — worth knowing if you're pairing `@strict_contract`/`@verify_strict` with a foreign type.
- AllocCheck/JET are **weak deps** (`[weakdeps]` in Project.toml, loaded via extension). Never import them unconditionally from `src/`.
- `_demangle(sym)` in `registry.jl` strips `#foo#NN` kwsorter mangling so `only`/`exempt` match keyword-argument functions correctly.
- `ignore_throw = true` is the default for AllocCheck calls — throw-path allocations don't count.
- `kernel_report` and `@assert_vectorized` work from `InteractiveUtils.code_llvm` — no backend needed. `_CACHE_BYTES` is a tunable `Ref` for cache-residency annotation thresholds.

## FEEDBACK.md

Documents dogfooding findings (F1–F38 as of this writing — check the file's own status table for
the current count, it moves faster than this file) from the PureFFT.jl and BlazingPorts.jl/QR
campaigns. Most findings are ✅ closed; a few are 🔴 open by design (e.g. F29/F30 — necessary-but-
not-sufficient axes `kernel_report`/the guarantees don't yet cover: data-dependent load latency,
scalar-gather transpose cost). Update the status table when closing or opening a finding — don't
trust "all ✅" without checking, it has been wrong before.
