# Changelog

## 0.4.1

### `CpuId.cachesize()` throws on aarch64 (Apple Silicon)

It has two failure modes and the extension handled one. It RETURNS `()` on x86 parts CpuId cannot
parse, which `_set_cache_bytes!` already guarded — but it THROWS on a host with no cache leaves at
all, because CpuId's non-x86 `cpuid` is an all-zeros stub, so `hasleaf` is false for both
`0x00000004` and `0x8000001d`. That is every aarch64 host. An exception escaping an extension
`__init__` is fatal during precompilation, so any package depending on both StrictMode and CpuId was
uninstallable on Apple Silicon.

Handling moved to `StrictMode._init_cache_bytes(probe)`, which takes the probe as a function so x86
CI can inject a throwing one — a real `cachesize()` only throws on hardware no runner here has.

Note for 0.3 consumers: this fix is on the 0.4 line only. A package pinning `StrictMode = "0.3.10"`
resolves `[0.3.10, 0.4.0)` and will not see it until it moves to 0.4.

### `@strict_contract` accepts an interface description

It forwarded only two arguments to `TypeContracts.@contract`, so the 3-argument
`(type, description, block)` form failed with a `MethodError` on the macro itself. Per-method
`=> "doc"` and `:optional` ride inside the block and were never affected, which is why the feature
looked half-present rather than missing.

### A union-typed local that boxes is now reported (F39)

A non-isbits union phi is a tagged pointer, so a member that normally lives unboxed must be
heap-boxed to flow through it. The box leaves no `:new` and no allocating `foreigncall` in optimized
IR — its only trace is the phi's own type — so the scan was blind to it, JET is blind to it
structurally (union splitting is not dynamic dispatch), and AllocCheck sees it only at whichever
signature happens to box.

Member count is not the discriminator; representation is. isbits members ride the unboxed payload and
mutable members are already pointers, but an immutable struct holding heap references — `SubArray`,
`Adjoint`, `Transpose` — is boxed on the way in.

The signal rides `:typestable`, not `:noalloc`, and that is deliberate. "This local is union-typed
with a box-on-entry member" is a property of the code as written; "it allocates" is LLVM's call and
moves with inlining — the same fixture measures 16 B/call across a module boundary and 0 B once it
inlines. Folding it into an allocation verdict would red kernels LLVM made free, which is issue #17
again.

Measured on 600 compiled stdlib specializations: it fires on **2** (0.3%), both genuine —
`LinearAlgebra.wrap` builds a `Union{Adjoint, Transpose, Symmetric, Hermitian, Matrix}`, where the
four immutable wrappers box and the `Matrix` does not.

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
allocation LLVM will later elide is still present — measured 8.1% false positives over 120 compiled
PureBLAS and PureIPM specializations, every one of them 0 bytes. A check that guesses must not be
able to abort a build. The ones that still throw *observe* compiled output rather than inferring
about it.

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
a call measuring 0 bytes could be reported as allocating. `Core.Compiler.EscapeAnalysis` on the same
signature now gates both the `:new` and the `Core.memorynew` rules, and
`length(Vector{Float64}(undef, n))` — the issue's own reproducer — comes back clean. Over eleven
hand-built shapes it produces **zero false negatives**: everything that really allocates is still
flagged.

Set expectations honestly, though: on a corpus of 120 compiled PureBLAS and PureIPM specializations
this removed **zero** findings, leaving the false-positive rate at 8.1% either way. 63 of those
frames contain a non-isbits `:new` and the analysis proves the set fully non-escaping in none of
them — it separates small self-contained kernels, not the interprocedural shapes library code is
made of. It is therefore computed on demand, at the first non-isbits `:new` that nothing else has
already flagged; eagerly it doubled a sweep (45.0s vs 21.7s over that corpus), lazily it costs 28.0s.
The number that matters more for anyone tempted to gate on this scan is the other direction: it
misses 23 of the 91 signatures AllocCheck flags, a recall of 75%.

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

### Trim scan: calls that union-split past the limit (issue #13)

The static scan gained a third rule. `TypeContracts.trim_report` finds dynamic dispatch by asking
whether a call's *result* infers to `Any`; a call left unresolved because its arguments union-split
past `max_union_splitting` infers a perfectly concrete result and was invisible to it, while juliac's
verifier rejects it. `@assert_trim_safe` / `@assert_trim_compatible` now report it, naming the callee
and the specialization count.

No callee size or opacity threshold is involved: a callee small enough to inline leaves no call
behind, and a product within the limit is split before optimization ends, so both safe cases are
excluded by the IR itself. Verified against juliac's verifier on seven shapes, including three
`Union{Nothing,Int}` arguments at one call site — which the verifier genuinely rejects.

### Two ways to check a definition that names no concrete types

A generic declaration cannot be checked as written: `return_types(pick, Tuple{Tuple,Int})` is `Any`,
so verifying it directly would fail every generic function in Julia. `@strict_function` therefore
skipped such definitions entirely, warning and moving on — which left the most common shape in a
library with no guarantee at all. Two additions close that, answering different questions.

- **`@strict_function signatures = [...]`** verifies the same contract against concrete
  instantiations you name, at module load, exactly as a concrete declaration is verified:

  ```julia
  sigs = [(NTuple{3,Float64}, Int), (Tuple{Float64,String}, Int)]
  @strict_function signatures = sigs pick(t::Tuple, i::Int) = t[i]
  # the second entry infers Union{Float64,String}, so the module fails to load
  ```

  Supplying it also silences the abstract-declaration warning, since it answers what that warning
  asks. The definition is untouched.

- **`@strict_stable`** instead checks every specialization callers actually create, and costs
  nothing for the ones that hold. The body moves into a hidden inner function and the public one
  infers its return type; that inference is a compile-time constant, so a stable specialization
  compiles to the same LLVM as the unannotated definition and still inlines into its caller, while
  an unstable one throws as it is compiled.

Reach for the first when the contract is a fixed set of signatures and you want the module to fail
to load. Reach for the second for an entry point whose callers pick the types — accepting that the
verdict then forms per specialization rather than at load, and that inference is not stable under an
open world, so a definition that loaded clean can begin to throw. Only type stability can be
delivered this way; allocation and vectorization are read from compiled output.
