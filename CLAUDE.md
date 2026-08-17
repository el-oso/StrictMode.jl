# StrictMode.jl — contributor context for Claude

## What this is

StrictMode.jl is a Julia package that makes performance guarantees (no allocations, type
stability, vectorization) enforceable at dev/CI time and free in production. The macros
expand to the bare call when checks are off. **The analysis tier is the dependency graph, not a
preference:** `StrictMode` alone analyzes with a value-free Base-inference heuristic and needs no
backend; adding `StrictModeTest` (a `test/Project.toml` dep) supplies AllocCheck + JET + TrimCheck
and every guarantee escalates to the proof at CALL time, with nothing recompiled.

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
                        noalloc/noboxing/owned), @assert_effects internals, _DICT_ACCESSORS,
                        register_alloc_barrier!/_is_base_barrier_type/_mi_is_barrier (issue #14
                        one-time-init allocation barriers: OncePerProcess/OncePerThread auto-
                        recognized (NOT OncePerTask — different Base implementation, no detectable
                        :invoke boundary) + user-registered, both feed the `barrier` alloc signal)
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
  backend.jl          — the backend SEAM only (`_be_*` stubs, backend_available/trimcheck_available,
                        _require_backend, set_ignore_throw!). StrictModeTest fills the stubs; nothing
                        here imports AllocCheck/JET/TrimCheck. Also
                        _checked_allocs/set_ignore_barrier! (issue #14: substitutes the barrier-
                        aware :fast heuristic for AllocCheck's proof on a barrier-containing call
                        — filtering AllocCheck's own per-instance backtraces does not work, ~half
                        merge into generic Base scheduler internals with no traceable origin)
  idioms.jl           — @unroll, staticval (fix for heterogeneous-tuple boxing)
  golden.jl           — @golden (gated bit-exact / ULP-tolerant regression harness)
  trimsafe.jl         — @assert_trim_safe, @assert_trim_compatible, explain_trim (juliac --trim gate;
                        issue #13: a heuristic-path PASS logs a one-time _TRIM_HEURISTIC_CAVEAT note
                        that reachability-limit union-splits aren't covered — status/reason on the
                        structured StrictFinding are untouched, macro-path-only visibility)
  memsafe.jl          — @assert_memsafe, memsafe_report/MemsafeReport, _guarded_array/GuardedBuffer
                        (mmap/mprotect guard-page harness for deterministic OOB read/write detection;
                        isolate=true runs the probe in a subprocess via Serialization + Base.run)
  mca.jl              — @assert_mca, mca_report/McaReport (issue #16 Tier 2: llvm-mca-backed
                        throughput/IPC estimate, informational only — never fails without an
                        explicit max_rthroughput=/min_ipc= bound). _sanitize_asm_for_mca (drops the
                        `;`-comment Function-Signature line llvm-mca's assembler chokes on),
                        _innermost_loop_span/_wrap_mca_region (region markers around the ymm/zmm-
                        containing loop — NOT bare xmm, which scalar SSE ops also use — to avoid the
                        whole-function false-loop-carried-dependency trap), _resolve_mcpu (llvm-mca's
                        CLI hard-fails on an unrecognized -mcpu, unlike Julia's own codegen path, so
                        this validates against `-mcpu=help` and falls back to "generic")
ext/
  StrictModeCthulhuExt.jl   — descend() fills _CTHULHU_DESCEND
  StrictModeCpuIdExt.jl     — CPU-specific _CACHE_BYTES override (weak dep, `using CpuId`)
  StrictModeReviseExt.jl    — cache invalidation on code change
  StrictModeMcaExt.jl       — llvm-mca CLI glue for mca_report (weak dep, `using LLVM_full_jll`,
                              ~680MiB — never a test/CI default, see test/mca_test.jl's live-path guard)
StrictModeTest/       — the :full tier, a SEPARATE package (subdir), test-environment only
  src/StrictModeTest.jl — AllocCheck/JET/TrimCheck as HARD deps; fills StrictMode's `_be_*` stubs and
                        flips backend_available()/trimcheck_available() in __init__. No macros of its
                        own: tier selection is auto-escalation inside StrictMode, decided at call
                        time, so `using StrictMode, StrictModeTest` is harmless and there is no
                        duplicate macro surface to keep in sync.
test/
  runtests.jl         — TestItemRunner @run_package_tests; `using StrictModeTest` supplies the proofs
  Project.toml        — [preferences.StrictMode] checks_enabled=true, fail_mode="error"
  standalone/         — a StrictMode-ONLY environment (deps: StrictMode + Test). The only place the
                        split's premise can be falsified: every item under test/ runs with the backend
                        loaded, so none of them can catch a guarantee that re-acquires a hard
                        AllocCheck/JET dependency. Run as its own CI step.
  round5_test.jl      — kernel_report / @assert_vectorized (F10–F15, F38)
  kernel_test.jl      — @kernel macro
  *_test.jl           — one file per guarantee
```

This table is a map, not a promise — when adding/moving a top-level definition, update the entry for
the file you touched rather than trusting this list; it has drifted before (verify with `ls src/`).

## Running tests

`Pkg.test()` from the MAIN environment — not `test/runtests.jl` directly. Running the file directly
leaves bounds checking at `auto`, whereas `Pkg.test()` forces `--check-bounds=yes`, and the two
generate different code: five vectorization-shape tests only fail under forced bounds checks, which
is how they stayed invisible in CI. `+release` selects 1.12 when 1.13 is the juliaup default.

```bash
julia +release --project=. -e 'import Pkg; Pkg.test()'
```

The test `Project.toml` enables checks and depends on `StrictModeTest`, which supplies the
AllocCheck/JET/TrimCheck proofs. Tests use `@testitem` (TestItemRunner.jl, macros from TestItems.jl
— `@testmodule`, not ReTestItems' `@testsetup`). Iterate on one item by name through the warm daemon:

```bash
JULIAUP_CHANNEL=release jl -e 'using StrictMode, StrictModeTest, TestItemRunner; @run_package_tests filter = ti -> occursin(r"F10", ti.name)'
```

The backend-free premise has its own environment; run it whenever you touch a guarantee's dispatch:

```bash
julia --project=test/standalone -e 'import Pkg; Pkg.instantiate()'
julia --project=test/standalone test/standalone/runtests.jl
```

## Key invariants

- **No Python**. No PythonCall/PyCall, no pip deps.
- **No new main-Project.toml deps** for test-only packages — those go in `test/Project.toml`.
- `_gate(checked, fallback)` in `preferences.jl` is the zero-cost expansion switch — every macro routes through it. The `checks_enabled` preference is a compile-time const baked at precompile; changing it requires a restart.
- `@contract`-style macro headers in the sibling TypeContracts package can't be module-qualified (e.g. `@contract Base.AbstractLock` fails to parse — needs `import Base: AbstractLock` first) — worth knowing if you're pairing `@strict_contract`/`@verify_strict` with a foreign type.
- AllocCheck/JET/TrimCheck are **not dependencies of StrictMode at all** — not even weak ones. They are hard deps of `StrictModeTest`, which fills the `_be_*` stubs. Never import them from `src/`, and never add them back to `Project.toml`: `test/standalone` exists to fail if you do.
- **Tier selection is auto-escalation, decided at CALL time** (`backend_available()` inside `_assert_*`), never at macro expansion. That is what lets one precompiled call site run the heuristic in a consumer's own environment and the proof under test. Consequence: `@strict_function`/`@strict module` can NEVER escalate — they run at the annotated module's own precompile, where `StrictModeTest` is not loadable — so the suite re-checks those signatures via `check_signatures`/`audit` at runtime instead.
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
