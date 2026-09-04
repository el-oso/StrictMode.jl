# StrictMode.jl — contributor context for Claude

## What this is

StrictMode.jl is a Julia package that makes performance guarantees (no allocations, type
stability, vectorization) enforceable at dev/CI time and free in production. The macros expand to
the bare call when checks are off (`checks_enabled`, default **`true`**; a shipped application calls
`disable_checks!()`).

**Two packages. `StrictMode` reports; `StrictModeTest` gates.** `StrictMode` analyzes with a
value-free engine — inferred return types plus a scan of typed IR — and depends on no analysis
backend at all. `StrictModeTest` (a `test/Project.toml` dep) has AllocCheck + JET + TrimCheck as
hard deps and adds `@test_noalloc`/`@test_noboxing`/`@test_typestable`/`@test_trim_compatible` plus
`test_signatures`/`test_compiled`/`test_registered`. **Which engine a call site uses is the macro
you wrote** — decided at expansion by name, with no ambient state and nothing to switch.

## Key architecture

```
StrictMode/src/
  StrictMode.jl       — module root, exports, top-level docstring
  macros.jl           — @strict (composite guarantee), @kernel (SIMD shorthand)
  preferences.jl      — checks_enabled/enable_checks!/disable_checks!/proofs_loaded, _gate (the
                        zero-cost compile-time expansion switch), assert_enabled, _announce_tier
                        (the load-time banner naming which TIER a session is in)
  static_checks.jl    — @assert_noalloc, @assert_noboxing, @assert_owned
  typestability.jl    — @assert_typestable, _typestable_check_expr/_typestable_fast
  inlining.jl         — @assert_inlined, inline_suggestions (module-sweep advisory)
  effects.jl          — _alloc_signals (the value-free IR scan used by noalloc/noboxing/owned),
                        ignore_throw/set_ignore_throw! (both tiers honor it), _DICT_ACCESSORS,
                        register_alloc_barrier!/_is_base_barrier_type/_mi_is_barrier (issue #14
                        one-time-init allocation barriers: OncePerProcess/OncePerThread auto-
                        recognized (NOT OncePerTask — different Base implementation, no detectable
                        :invoke boundary) + user-registered, both feed the `barrier` alloc signal)
  scheduling.jl       — @assert_vectorized, @assert_effects, @assert_no_scalar_loops,
                        @assert_no_spill, kernel_report/KernelReport, register_report/RegisterReport,
                        spill_report/SpillReport, descend, _CACHE_BYTES
  static_ownership.jl — static_ownership_suggestions (module-sweep GKH-ownership advisory)
  concurrency.jl      — @assert_concurrency_safe, @assert_no_threadid_state, pool_balance_report
  strict_function.jl  — @strict_function (load-time enforcement; `signatures = [...]` verifies
                        concrete instantiations a generic declaration cannot name, since such a
                        declaration infers to `Any`), @strict_stable (per-specialization instead:
                        body moves to a hidden `#f#inner`, the wrapper infers its return type via
                        promote_op so a stable specialization folds the branch away entirely),
                        @strict_exempt
  contracts.jl        — @strict_contract, @verify_strict (pairs a TypeContracts interface with
                        StrictMode performance guarantees)
  registry.jl         — @strict_function registry, register_strict!, watch/unwatch, _demangle
                        (kwsorter name stripping), and the ITEM BUILDERS both tiers share:
                        _registry_items/_compiled_items/_map_findings/_run_and_report. The
                        reporting drivers _findings_all/_findings_compiled are here too;
                        StrictModeTest's test_registered/test_compiled reuse the same item lists
  audit.jl            — audit (the reporting entry point; no exit status, never throws)
  check.jl            — findings/_findings_fast/_compiled_output_finding — the interference-proof
                        core every guarantee funnels through: no macro parsing, no execution.
                        _compiled_output_finding covers the guarantees read from compiled output
                        (owned/inlined/vectorized/no_scalar_loops/no_spill/trimsafe), so
                        StrictModeTest delegates to it rather than keeping a second copy
  findings.jl         — StrictFinding struct, format_findings, nfailures, _failed
  explain.jl          — @explain, StrictReport (built on the value-free engine)
  cache.jl            — (method, world, signature, guarantees) → findings cache
  report.jl           — StrictViolation exception, _fail, _guarantee_gates (which guarantees
                        THROW from StrictMode and which only WARN — observation vs. inference)
  backend.jl          — the llvm-mca seam ONLY (`_be_mca_*`, mca_available). The analysis tier is
                        NOT a seam: nothing here reaches for a backend that may or may not be loaded
  idioms.jl           — @unroll, staticval (fix for heterogeneous-tuple boxing)
  golden.jl           — @golden (gated bit-exact / ULP-tolerant regression harness)
  trimsafe.jl         — @assert_trim_safe, @assert_trim_compatible, explain_trim (juliac --trim gate;
                        issue #13: a heuristic-path PASS logs a one-time _TRIM_HEURISTIC_CAVEAT note
                        that reachability-limit union-splits aren't covered — status/reason on the
                        structured StrictFinding are untouched, macro-path-only visibility)
  memsafe.jl          — @assert_memsafe, memsafe_report/MemsafeReport, _guarded_array/GuardedBuffer
                        (mmap/mprotect guard-page harness for deterministic OOB read/write detection;
                        the probe always runs in a subprocess via Serialization + Base.run — an
                        in-process probe cannot observe a read overrun. _guarded_args shares one
                        buffer between aliased argument positions; _unguarded_args names what the
                        harness could not cover)
  mca.jl              — @assert_mca, mca_report/McaReport (issue #16 Tier 2: llvm-mca-backed
                        throughput/IPC estimate, informational only — never fails without an
                        explicit max_rthroughput=/min_ipc= bound). _sanitize_asm_for_mca (drops the
                        `;`-comment Function-Signature line llvm-mca's assembler chokes on),
                        _innermost_loop_span/_wrap_mca_region (region markers around the ymm/zmm-
                        containing loop — NOT bare xmm, which scalar SSE ops also use — to avoid the
                        whole-function false-loop-carried-dependency trap), _resolve_mcpu (llvm-mca's
                        CLI hard-fails on an unrecognized -mcpu, unlike Julia's own codegen path, so
                        this validates against `-mcpu=help` and falls back to "generic")
StrictMode/ext/
  StrictModeCthulhuExt.jl   — descend() fills _CTHULHU_DESCEND
  StrictModeCpuIdExt.jl     — CPU-specific _CACHE_BYTES override (weak dep, `using CpuId`)
  StrictModeReviseExt.jl    — cache invalidation on code change
  StrictModeMcaExt.jl       — llvm-mca CLI glue for mca_report (weak dep, `using LLVM_full_jll`,
                              ~680MiB — never a test/CI default, see test/mca_test.jl's live-path guard)
StrictModeTest/       — the PROOF tier, a SEPARATE package, sibling subfolder, test-environment only
  src/StrictModeTest.jl — module root; AllocCheck/JET/TrimCheck as HARD deps. __init__ REFUSES to
                        load unless StrictMode.checks_enabled() (otherwise every @assert_* is a
                        bare call, nothing registers, and test_registered() sweeps an empty
                        registry and passes), then announces the proof tier.
  src/proofs.jl       — _raw_allocs/_is_boxing/_checked_allocs (AllocCheck), _opt_reports (JET,
                        wrapped in AnalysisError), _trim_validate (TrimCheck), _proof_findings/
                        proof_findings, ignore_barrier/set_ignore_barrier!
  src/macros.jl       — @test_noalloc/@test_noboxing/@test_typestable/@test_trim_compatible.
                        Deliberately NOT wrapped in _gate: a gate that compiles itself away under
                        a preference is a gate that can vanish silently
  src/drivers.jl      — test_signatures/test_compiled/test_registered; each collects every failure
                        and raises ONCE, so one unanalyzable method leaves the rest evaluated
  src/divergence.jl   — divergence_report/StrictDivergence/save_divergence (needs BOTH engines,
                        which is why it lives here)
  test/               — its own suite: the proof primitives StrictMode cannot test, because
                        StrictMode does not depend on those packages at all
StrictMode/test/
  runtests.jl         — TestItemRunner @run_package_tests; `using StrictModeTest` supplies the proofs
  Project.toml        — no [preferences.StrictMode] block: checks_enabled defaults to true, and this
                        env exercises that default
  standalone/         — a StrictMode-ONLY environment (deps: StrictMode + Test). The only place the
                        split's premise can be falsified: every item under test/ runs with the proofs
                        loaded, so none of them can catch a guarantee that re-acquires a hard
                        AllocCheck/JET dependency. Run as its own CI step.
  round5_test.jl      — kernel_report / @assert_vectorized (F10–F15, F38)
  kernel_test.jl      — @kernel macro
  *_test.jl           — one file per guarantee
```

This table is a map, not a promise — when adding/moving a top-level definition, update the entry for
the file you touched rather than trusting this list; it has drifted before (verify with `ls StrictMode/src/`).

## Running tests

`Pkg.test()` from the MAIN environment — not `test/runtests.jl` directly. Running the file directly
leaves bounds checking at `auto`, whereas `Pkg.test()` forces `--check-bounds=yes`, and the two
generate different code: five vectorization-shape tests only fail under forced bounds checks, which
is how they stayed invisible in CI. `+release` selects 1.12 when 1.13 is the juliaup default.

```bash
julia +release --project=StrictMode -e 'import Pkg; Pkg.test()'
```

The test `Project.toml` depends on `StrictModeTest`, which supplies the AllocCheck/JET/TrimCheck
proofs; checks are on by default, so it carries no preference block. `StrictModeTest` has its own
suite — run it whenever you touch a proof primitive:

```bash
julia --project=StrictModeTest -e 'import Pkg; Pkg.test()'
```

Tests use `@testitem` (TestItemRunner.jl, macros from TestItems.jl
— `@testmodule`, not ReTestItems' `@testsetup`). Iterate on one item by name through the warm daemon:

```bash
JULIAUP_CHANNEL=release jl -e 'using StrictMode, StrictModeTest, TestItemRunner; @run_package_tests filter = ti -> occursin(r"F10", ti.name)'
```

The proof-free premise has its own environment; run it whenever you touch a guarantee's engine:

```bash
julia --project=StrictMode/test/standalone -e 'import Pkg; Pkg.instantiate()'
JULIA_LOAD_PATH="@:@stdlib" julia --project=StrictMode/test/standalone StrictMode/test/standalone/runtests.jl
```

## Key invariants

- **`StrictMode` and `StrictModeTest` ship in lockstep.** StrictModeTest reaches into ~20 StrictMode
  internals (`_alloc_signals`, `_compiled_output_finding`, `_mkfinding`, `_call_parts`, `_gate`, …),
  so their versions move together and StrictModeTest's `[compat]` names the exact StrictMode minor
  it was built against, not the loose `"0.4"`. A signal added to the scan must also be wired into the
  matching proof, or the reporting tier ends up STRICTER than the gating one — which is what happened
  when `unionphi` (F39) landed in `_typestable_fast` and JET could not see it.

- **No Python**. No PythonCall/PyCall, no pip deps.
- **No new main-Project.toml deps** for test-only packages — those go in `test/Project.toml`.
- `_gate(checked, fallback)` in `preferences.jl` is the zero-cost expansion switch — every macro routes through it. The `checks_enabled` preference is a compile-time const baked at precompile; changing it requires a restart.
- `@contract`-style macro headers in the sibling TypeContracts package can't be module-qualified (e.g. `@contract Base.AbstractLock` fails to parse — needs `import Base: AbstractLock` first) — worth knowing if you're pairing `@strict_contract`/`@verify_strict` with a foreign type.
- AllocCheck/JET/TrimCheck are **not dependencies of StrictMode at all** — not even weak ones. They are hard deps of `StrictModeTest`. Never import them from `src/`, and never add them back to `Project.toml`: `test/standalone` exists to fail if you do.
- **Tier selection is the macro name, decided at expansion.** `@assert_noalloc` IS the value-free
  scan; `@test_noalloc` IS the AllocCheck proof. Nothing reads a flag at call time, so no ambient
  state can silently pick the other engine — and a `@test_*` macro can never find its backend
  missing, because the package that defines it is the package that depends on it. Consequence:
  `@strict_function`/`@strict module` run at the annotated module's own precompile, where
  `StrictModeTest` is not loadable, so the suite re-proves those signatures via
  `test_registered()`/`test_signatures` at runtime instead.
- **`_guarantee_gates` (report.jl) decides throw-vs-warn, per guarantee.** A check that OBSERVES
  compiled output gates (`:typestable`'s return-type layer, `:memsafe`, `:vectorized`, `:no_spill`,
  `:inlined`, `:owned`). A check that INFERS something it cannot see reports:
  `:noalloc`/`:noboxing` (typed IR cannot see what LLVM elides — ~28% false on a real consumer,
  issue #17), `:no_scalar_loops` (SLP output forges its discriminator), `:trimsafe`/
  `:trim_compatible` (the static scan does not model juliac's reachability limit), and
  `:typestable`'s depth-0 boxing signal (`gates = false` at its call site in `typestability.jl`).
  Do NOT make StrictMode's allocation verdicts gate: a heuristic false positive aborting a
  consumer's precompile is issue #18, and it made checks-on unusable in PureBLAS. The proofs in
  `StrictModeTest` gate unconditionally — that is what that package is.
- **A finding the analysis could not evaluate is `:fail`**, carrying the error text (`_unevaluated`
  in check.jl, `_errored_findings` in registry.jl). Never `:pass`: "could not check" and "is fine"
  rendering the same is how a crashed backend reported success for every method in a sweep. Tests
  should assert `StrictMode._failed(f)` rather than `f.status === :fail`, which pins a symbol
  instead of the intent.
- `_demangle(sym)` in `registry.jl` strips `#foo#NN` kwsorter mangling so `only`/`exempt` match keyword-argument functions correctly.
- `ignore_throw() = true` is the default and lives in StrictMode (`effects.jl`) — throw-path allocations don't count, and BOTH tiers honor it, so the scan and AllocCheck answer the same question.
- `kernel_report` and `@assert_vectorized` work from `InteractiveUtils.code_llvm` — no backend needed. `_CACHE_BYTES` is a tunable `Ref` for cache-residency annotation thresholds.

## FEEDBACK.md

Documents dogfooding findings (F1–F38 as of this writing — check the file's own status table for
the current count, it moves faster than this file) from the PureFFT.jl and BlazingPorts.jl/QR
campaigns. Most findings are ✅ closed; a few are 🔴 open by design (e.g. F29/F30 — necessary-but-
not-sufficient axes `kernel_report`/the guarantees don't yet cover: data-dependent load latency,
scalar-gather transpose cost). Update the status table when closing or opening a finding — don't
trust "all ✅" without checking, it has been wrong before.
