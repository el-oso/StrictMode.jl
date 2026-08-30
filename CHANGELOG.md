# Changelog

## 0.4.0 — the tier split

**Read this before upgrading.** The breaking change is *silent*: every `StrictMode` macro keeps its
spelling, so your call sites compile and run exactly as before. What changes is that most of them
stop deciding your build. Nothing surfaces that at compile time.

### The one-sentence version

`StrictMode` **reports**; the new companion package `StrictModeTest` **gates**. Which engine a call
site uses is now the macro you wrote — `@assert_noalloc` is the value-free scan, `@test_noalloc` is
AllocCheck's proof — with no mode to switch and no ambient state deciding it.

### If you do nothing

Your suite still runs and still passes. But `@assert_noalloc`, `@assert_noboxing`,
`@assert_no_scalar_loops`, `@assert_trim_safe` and `@assert_trim_compatible` now **warn** where they
used to throw, so a real regression in any of those will no longer fail your build. Everything else
(`@assert_typestable`'s return-type layer, `@assert_memsafe`, `@assert_vectorized`,
`@assert_no_spill`, `@assert_inlined`, `@assert_owned`, `@assert_concurrency_safe`,
`@assert_no_threadid_state`) still throws.

Why: those five infer something they cannot see. The allocation scan reads typed IR, where an
allocation LLVM will later elide is still present — measured ~28% false positives on a real
consumer, every one of them 0 bytes. A check that guesses must not be able to abort a build. The
ones that still throw *observe* compiled output rather than inferring about it.

### To keep gating

Add `StrictModeTest` to your **test** environment and use the `@test_*` surface:

```julia
# test/Project.toml:  [deps] StrictMode, StrictModeTest
using StrictMode, StrictModeTest

@test_noalloc kernel!(C, A, B)     # AllocCheck's all-paths proof — throws
test_compiled(MyPkg)               # gate everything the module actually compiled
```

### Migration table

| 0.3 | 0.4 |
| --- | --- |
| `check(f, types)` | `findings(f, types)` to report, `test_signatures([(f, types)])` to gate |
| `check_all()` | `test_registered()` |
| `check_compiled(mod)` | `test_compiled(mod)` |
| `check_signatures(pairs)` | `test_signatures(pairs)` |
| `audit(mod; exit_on_fail = true)` | `test_compiled(mod)` — `audit` no longer sets an exit status |
| `mode = :fast` / `mode = :full` | removed — the macro name selects the engine |
| `fail_mode` preference | removed — throw-vs-warn is per guarantee |
| `status == :suspect`, `nsuspect` | removed — status is `:pass`/`:fail`/`:info` |
| `status == :skip` | removed — an unevaluable guarantee is `:fail` carrying the error text |
| `backend_available()` | `proofs_loaded()` |
| `BackendUnavailable` | removed — a proof cannot find its backend missing |
| `divergence_report` | moved to `StrictModeTest` |
| `StrictMode.AnalysisError` | `StrictModeTest.AnalysisError` |
| `ignore_barrier` / `set_ignore_barrier!` | moved to `StrictModeTest` |
| `@assert_noalloc static = true` | `@test_noalloc` (the old form now errors, pointing at it) |

If you match on the JSON `status` field, `"suspect"` no longer appears — match `"fail"` alone.

### Other changes

- **`checks_enabled` defaults to `true`.** A test environment needs no `[preferences.StrictMode]`
  block. A shipped application turns checks off with `disable_checks!()`, which is what makes the
  macros compile to bare calls. A preference block that *enables* checks is now redundant; one that
  disables them still works.
- **`StrictModeTest` refuses to load when checks are disabled.** With checks off every `@assert_*`
  is a bare call and nothing registers, so `test_registered()` would sweep an empty registry and
  report success.
- **Both packages announce their tier at load**, because the state worth knowing is not "checks are
  off" but "checks are on and `@assert_noalloc` is no longer a proof" — and those two used to print
  identically.
- **`@explain` stayed in `StrictMode`** and is rebuilt on the value-free engine. `StrictReport`'s
  `opt_result`/`allocs`/`alloc_error` fields are replaced by `signals`, `local_boxing` and
  `scan_error`.
- **`@assert_memsafe` lost `isolate=false`.** An in-process probe can only use the canary, and a
  load past the end disturbs no canary, so its clean verdict was indistinguishable from no overrun
  at all — in exactly the case the harness exists for. The probe always runs in a subprocess now,
  the poison is position-dependent, aliased arguments share one guarded buffer, and arguments the
  harness cannot guard are named in `MemsafeReport.unguarded` instead of being silently skipped.
- `Julia 1.12` is the minimum.

### Fewer false allocation reports (issue #17)

The allocation scan reads typed IR, where an allocation LLVM will later remove is still present, so
a call measuring 0 bytes could be reported as allocating — 19 of 68 findings on one real consumer,
every one of them 0 B. `Core.Compiler.EscapeAnalysis` on the same signature now gates both the
`:new` and the `Core.memorynew` rules: `length(Vector{Float64}(undef, n))`, the issue's own
reproducer, comes back clean.

Measured over eleven shapes — escaping, runtime-size, 100k-element, `IOBuffer`, `Dict`,
`push!`-grown, bare `Memory`, and two clean controls — this produces **zero false negatives**: every
shape that really allocates is still flagged. One residual over-flag remains (`[n, n+1]`), which is
the safe direction. Cost is ~0.7 ms cold per signature and ~0.08 ms warm, memoized and cleared with
the findings cache.

`Core.Compiler.EscapeAnalysis` is a compiler internal with no cross-version stability guarantee, so
any failure inside it falls back to "assume it escapes" — the previous behaviour. A Julia release
that moves it degrades the false-positive rate rather than weakening the guarantee.

### `migration_report` also flags deleted API

Beyond the macros that stopped gating, 0.4 **deleted** names some consumers call directly:
`analysis_mode`, `backend_available`, `trimcheck_available`, `check_all`, `check_signatures`,
`check_compiled`, `nsuspect`, `fail_mode`, `BackendUnavailable`, and the `exit_on_fail` keyword.
Those are a `UndefVarError` at load, not a silent downgrade — and three of the eight consumer
packages measured here gate a block of their **`src/`** on `analysis_mode()` / `backend_available()`,
which stops the package precompiling at all. `migration_report` scans `src/` and `ext/` for deleted
names (fatal anywhere) and `test/`, `benchmark/`, `bench/` for the reporting macros (only a problem
where the proof was available).

### Trim verification: juliac's warnings, and its Base patches

- **Warnings are no longer failures (issue #20).** `TrimVerificationErrors.errors` is a
  `Vector{Pair{Bool, Any}}` whose `Bool` is `warn`, and juliac's own gate fails only on the
  non-warning entries. `@test_trim_compatible` now splits them: a raise carrying nothing but
  warnings is a PASS, and only the real errors reach the site parser, so a warning's call site is
  no longer reported as a failing one.
- **`set_juliac_patches!` (default `false`).** juliac includes `juliac-trim-base.jl` and
  `juliac-trim-stdlib.jl` before trim inference, and without them the verifier rejects code juliac
  builds clean — issue #19, where a ≥4-argument string interpolation on a reachable throw path is
  despecialized to `Vararg{Any}`. Enabling this applies them. It defaults **off** because
  `juliac-trim-base.jl` stubs `Base.CoreLogging.current_logger_for_env`, which silences every
  `@warn` and `@info` for the rest of the session — including the entire StrictMode reporting tier.
  Turn it on only in a process that does nothing but trim verification.
