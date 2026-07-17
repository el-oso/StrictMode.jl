# StrictMode.jl release notes

## v0.3.9

Five features closing four issues (#13, #14, #15, #16), each independently reviewed and
cross-checked before landing (per-phase review, then a final whole-branch pass — two real
regressions were only visible at that level and are called out below).

- **`@assert_no_spill` / `spill_report`** (issue #16 Tier 1) — a hard-gate guarantee for
  vector-register spilling, the codegen analogue of `@assert_noalloc`: fails if the compiled
  kernel's `code_native` shows LLVM spilling a vector (xmm/ymm/zmm) register to the stack.
  Syntax-independent (works whether `code_native` emitted AT&T or Intel).
- **`@assert_memsafe` / `memsafe_report`** (issue #15) — a guard-page (electric-fence style)
  harness catching out-of-bounds array reads/writes in unsafe SIMD kernels *deterministically*
  instead of flakily. `isolate=true` (default) runs the probe in a subprocess to catch a fatal
  out-of-bounds read (an otherwise-uncatchable `SIGSEGV`); `isolate=false` is a cheaper in-process
  check that only catches out-of-bounds writes. Linux/macOS only, `Array` arguments only.
- **One-time-init allocation barrier exemption** (issue #14) — `Base.OncePerProcess`/
  `OncePerThread`-memoized lazy calibration no longer reds `:full` `@assert_noalloc`/
  `@assert_noboxing` on its one-time cold-path allocation; recognized automatically via a static
  IR scan (`Base.OncePerTask` is NOT auto-recognized — a different underlying implementation with
  no detectable non-inlined callee boundary), or register a hand-rolled pattern with
  `register_alloc_barrier!`. Always logged once via `@info`, never a silent exemption; disable
  globally with `set_ignore_barrier!(false)`.
- **Trim-heuristic coverage-gap caveat** (issue #13) — a heuristic-path `@assert_trim_safe`/
  `@assert_trim_compatible` PASS now logs a one-time session note about a known
  reachability-limit union-split class the static scan can't reliably flag without
  false-positiving on safe code. `StrictFinding.status`/`.reason` are untouched (back-compat).
- **`mca_report` / `@assert_mca`** (issue #16 Tier 2) — an `llvm-mca`-backed steady-state
  throughput/IPC estimate (new `LLVM_full_jll` weak dependency, ~680MiB, never a test/CI default).
  Informational only — `@assert_mca` never fails without an explicit `max_rthroughput=`/`min_ipc=`
  bound, since a naive whole-function `llvm-mca` run can disagree with ground truth (a false
  loop-carried dependency from the function-boundary store/reload); region markers around the
  detected innermost hot loop sidestep that.

Two regressions only surfaced in a final whole-branch review, after each phase had already passed
its own individual review — both fixed before release:

- The barrier exemption's IR-scan (`_mi_is_barrier`) matched any function whose second parameter
  happened to be a `OncePerProcess`/`OncePerThread` value, not just Base's own cold-path init
  closure — a user function with that exact parameter shape was wrongly treated as the barrier
  itself, silently hiding its own real per-call allocation. Fixed by additionally requiring the
  match come from `Base` (`mi.def.module === Base`).
- The barrier exemption was wired into `@assert_noalloc`/`@assert_noboxing`/`findings`/`check`
  but not into `@strict_function` (a barrier-containing definition could still fail to load) or
  `divergence_report`'s diagnostic signal labels (a phantom `full:alloc-sites=N` label on a call
  that no longer actually diverges). Both now route through the same `_checked_allocs` seam.

Also: `Serialization` (a stdlib, used for `@assert_memsafe`'s subprocess argument marshaling) is a
new main dependency.

## v0.3.8

Bugfix. `StrictModeCpuIdExt.__init__` blindly destructured `CpuId.cachesize()`'s result
(`l1, l2, l3 = cachesize()`), which throws `BoundsError` on CPUs `CpuId` can't parse (brand-new
models like EPYC 9455/Zen5, or VMs/hypervisors that mask the deterministic-cache CPUID leaf) — an
`InitError` that crashed the whole extension load and took `using CpuId` (and every package that
transitively loads it, e.g. PureBLAS) down with it.

- **`StrictMode._set_cache_bytes!(cs)`** guards the ingest: keeps the safe default `_CACHE_BYTES`
  unless `cs` has ≥3 positive sizes, instead of throwing. Regression test in
  `test/cpuid_ext_test.jl` covers `()`, short, and zero tuples.

## v0.3.7

Bugfix. Fixes a `:fast`-mode `@assert_typestable` false positive introduced in v0.3.6, and a
CI-only failure caught just after: `kernel_report`'s fast-math warning was unreachable whenever
the kernel didn't auto-vectorize.

- **`:fast` typestable is now THIS-LEVEL (depth-0).** v0.3.6 added the IR boxing signal to the fast
  typestable check (F38), but reused the *full-depth* `_alloc_signals` — the same signal `noalloc`/
  `noboxing` use, which follows non-inlined `:invoke` callees. That over-flagged a **type-stable**
  caller whose only "boxing" is a resolved `:invoke` into a helper that boxes internally but whose
  result is narrowed at the call site (the canonical shape: a `get!` on an abstract-valued IdDict
  behind a `::Concrete` assert — PureBLAS's complex `_l3ws` workspace accessor, reached from
  `herk!`/`_cpotrf_lower!`). Such a caller has no dispatch of its own; JET's `:full` opt-analysis
  passes it, and now `:fast` agrees. Type stability is a property of the function's OWN IR, so the
  typestable boxing scan uses depth-0 (a direct dynamic `:call` — F38's `c.f(1)` — is still caught);
  `noalloc`/`noboxing` keep the full-depth signal (a callee's runtime alloc/dispatch IS a real cost).
  Regression test in `test/typestable_test.jl`.
- **`kernel_report`'s fast-math warning is no longer gated on `vectorized`.** `Base.show`'s
  `!r.vectorized` branch returned early, before ever reaching the `fastmath_ops` warning — so a
  kernel with fast-math-flagged *scalar* ops (or one whose loop simply didn't widen into `<N x …>`
  on a given CPU target) never printed the warning, even though `fastmath_ops` was computed
  correctly. The warning print is now a shared helper (`_print_fastmath_warning`) called from both
  branches of `show`.
- **Regression test root cause**: the original F38 test exercised the fast-math signal only via
  `@simd`, whose fast-math flags land solely on ops the auto-vectorizer actually widens —
  target-CPU dependent, and the reason this passed locally but failed on CI's runner (a different
  SIMD-width decision). The test now uses `@fastmath` for its hard assertions (flags scalar ops
  unconditionally, portable across targets) and checks the `@simd`/vectorized case only when
  vectorization actually occurred.

## v0.3.6

Additive, non-breaking. Dogfooding + readability audit: a fast-math visibility gap, two
under-reported heuristic gaps, and a round of dead-code/duplication cleanup.

- **`kernel_report` fast-math visibility.** Its vector-op regexes didn't account for LLVM
  fast-math flags (`fmul contract <8 x double>` etc.), silently undercounting `fp_ops`/`mem_ops`
  for any `@simd`/`@fastmath` kernel — and gave no indication the kernel relies on relaxed IEEE
  semantics at all. `KernelReport` gains a `fastmath_ops` field, and `show` prints a standing `⚠`
  warning whenever it's nonzero, rather than folding fast-math ops silently into the normal counts.
- **`:owned` (GKH ownership) scan** now also flags `delete!`/`getkey`, not just
  `get`/`getindex`/`get!`/`setindex!`/`haskey`/`pop!`.
- **`:new`-allocation rule broadened.** The old rule (`mutable || Array || Memory || Box`) missed
  escaping non-isbits *immutables* (e.g. `Some{Any}(x)`) — a real false negative found via a
  569-specialization PureFFT+BlazingPorts corpus measurement (2 false negatives fixed; one
  documented residual false positive on non-escaping stdlib wrappers like `Base.CodeUnits`,
  accepted since over-flagging is the safe direction for an alloc guarantee).
- **`@assert_owned`'s default depth** now reads `StrictMode._FAST_ALLOC_DEPTH[]` live, instead of
  baking in a stale compile-time value.
- **Cleanup**: removed dead code (`golden.jl`'s unused constants, an unused import), renamed a
  duplicate `_scan_ci`, and merged three near-duplicated code paths (shared macro-call plumbing,
  the mode-independent `findings` branches, and the module-specialization sweep loop used by
  `check_compiled`/`static_ownership_suggestions`/`inline_suggestions`) that had started to drift.

## v0.3.5

Additive, non-breaking. GKH ownership — a `const`-owner-per-type idiom for replacing runtime
type/symbol-keyed registry lookups — gets both a precise tool and a broad one, plus a `:fast`
accuracy fix and a dispatch-signature bugfix found while dogfooding the new guarantee ([#7], [#8]).

- **`@assert_owned f(args...)`** — fails if the call reaches a runtime `AbstractDict` lookup
  (`get`/`getindex`/`get!`/`setindex!`/`haskey`/`pop!`) on its hot path: the *owned-scratch* /
  GKH-ownership violation. A structural IR lint (no backend, no timing), like `@assert_noboxing`:
  it follows non-inlined callees (the lookup often lives in a workspace accessor a level down) and
  matches the `jl_eqtable_*` foreigncall shape an `IdDict` lookup on a statically-known key
  const-folds to. Opt-in per call site, like `@assert_inlined` — deliberately **not** part of
  `@strict` or `register_strict!`'s defaults, since a broad sweep would flag (and break the build
  on) the pattern's own sanctioned Dict fallback for a rare-type tail.
- **`static_ownership_suggestions(f, types)` / `static_ownership_suggestions(mod)`** (exported) —
  the advisory, whole-package counterpart: scans for the same type/symbol-keyed lookup pattern and
  emits an `:info` finding (never a failure; `nfailures` ignores it), like `inline_suggestions`.
  Opt in from `audit(...; static_ownership_suggest = true)`. Detection scans **unoptimized** typed
  IR — a `Type{T}`-keyed lookup on a statically-known `T` can fully const-fold away during
  optimization before an optimized-IR scan would ever see it — plus a key-type-aware interprocedural
  check for the "lookup lives in a non-inlined accessor" shape, narrowed to Type/Symbol keys only so
  a value-keyed cache (`Dict{String,_}`) is never flagged.
- **`:fast` mode false negatives fixed (closes [#8]).** `noalloc`/`typestable` missed allocations
  living 2+ non-inlined `:invoke` hops down (e.g. a BLAS/LAPACK-style `driver! -> prep-helper ->
  similar/Array` chain) — the depth-1 callee recursion added in v0.3.3 (F35) didn't go deep enough,
  and a non-inlined callee's own boxing signal was computed but discarded rather than propagated to
  the caller. `StrictMode._FAST_ALLOC_DEPTH[]` is now a tunable `Ref` (default 2, was hardcoded 1;
  same override pattern as `_CACHE_BYTES`), and boxing now propagates through the recursion.
- **Dispatch-signature bugfix (F37).** `register_strict!`, `check_compiled`, `inline_suggestions
  (mod)`, and `@strict_function` all silently skipped every `::Type{T}`-argument method —
  `isconcretetype(Type{Float64})` is `false` in Julia despite `Type{T}` being a fully-specified
  dispatch singleton. All four now use `Base.isdispatchtuple` instead, so `::Type{T}`-argument
  methods (the exact shape `@assert_owned`/`static_ownership_suggestions` recommend writing) are no
  longer invisible to module sweeps and the mark-once registry.

[#7]: https://github.com/el-oso/StrictMode.jl/issues/7
[#8]: https://github.com/el-oso/StrictMode.jl/issues/8

## v0.3.4

Additive, non-breaking. Two dogfooding gaps closed so the guarantee macros can be pointed at real
public API surfaces instead of internal positional drivers ([#4], [#5]).

- **Keyword-argument calls** in every guarantee macro — `@assert_noalloc`, `@assert_typestable`,
  `@assert_noboxing`, `@strict`, `@kernel`, `@assert_effects`, `@assert_vectorized`, … now accept
  `f(args...; kw...)`. The call is routed through `Core.kwcall`, so `Base.return_types`, JET and
  AllocCheck analyze the keyword sorter's real specialization; the backends are unchanged. This lets
  keyword-based public entry points (`trsm!(B, A; side, uplo, …)`) be guaranteed directly rather
  than via their positional internals. (A keyword *kernel*'s SIMD lives in the non-inlined
  `Core.kwcall` sorter, so mark it `@inline` for `@assert_vectorized`/`@kernel` to see through it.)
- **`types = (…)` signature override** on every guarantee macro — pins the inference signature
  verbatim instead of deriving it from `typeof.(args)`. Fixes the false positive on type-argument
  functions (`typeof(Float64) == DataType` widens `Matrix{T}` to `Matrix`): assert them at their
  real specialization with `@assert_typestable f(Float64, …) types=(Type{Float64}, …)`.

Internally, both fall out of one shared choke point (`_call_parts` / `_macro_call` in
`preferences.jl`); the per-macro argument-binding boilerplate was deduplicated.

[#4]: https://github.com/el-oso/StrictMode.jl/issues/4
[#5]: https://github.com/el-oso/StrictMode.jl/issues/5

## v0.3.3

Additive, non-breaking. Four themes: an automatic inlining audit, structural enforcement (make
ignoring StrictMode loud), multi-threading correctness guarantees, and a corpus-measured
accuracy/speed upgrade of `:fast` mode.

### Inlining audit

- **`inline_suggestions(f, types)` / `inline_suggestions(mod)`** (exported) — scan optimized typed
  IR for callees the compiler did **not** inline and emit informational "consider `@inline`"
  findings (never failures; `nfailures` ignores them). `@generated` and in-loop callees are the
  flagged, high-value cases. Opt in from `audit(...; inline_suggest = true)`.

### Structural enforcement

- **`assert_enabled()`** (exported) — returns `checks_enabled()` locally but **errors under CI**
  (any non-empty `ENV["CI"]`) when checks are disabled. With checks off every `@assert_*` expands
  to the bare call and a strictmode test passes *vacuously*; in CI that is now a red build, not a
  green skip. Use it as the first line of your strictmode tests.
- **Coverage gate: `audit(mod; require = :public)`** — one failing `:coverage` finding per
  exported/`public` function of the module that is neither registered (`register_strict!` /
  `@strict_function`) nor exempted (`@strict_exempt` / the `exempt` kwarg). Registration becomes
  the manifest; a new public function cannot ship silently unchecked — opting out requires a
  visible exempt. See "Automating checks" in the docs.
- **Usable agent Stop-hook template** — the `agents.md` Claude Code example no longer cold-starts
  `julia -e` on every stop: the shipped template hashes `src/`, audits only on turns that changed
  source, guards against stop loops, and blocks the stop (exit 2) with the findings.

### `:fast` mode — corpus-measured accuracy and speed (F35)

Measured against `:full` on 552 compiled specializations of two real packages
(`bench/mode_gap.jl`; datasets committed under `bench/results/`). Fast mode previously
under-reported 15 cases; it now matches `:full` on **every** `:typestable` / `:noalloc` /
`:inlined` verdict (3 residual `:noboxing` under-reports on cold helpers, each still failing via
`:noalloc`) with **zero false positives**, at **4.9 ms vs 296 ms median (~60×)**. What changed:

- dynamic `:call`s with an abstract **argument** now flag boxing even when the result type is
  concrete (the internal-dispatch-behind-a-concrete-return blind spot; canonical shape: an
  un-`Val`ed `ntuple` feeding a constructor);
- `Core.memorynew` (how Julia 1.12 allocates `Memory`) counts as an allocation — it is a builtin
  `:call`, previously invisible to the `:new`/`:foreigncall` rules;
- the alloc scan follows direct non-inlined callees (a grow path or string build in a helper is a
  real allocation of the caller), skipping throw-path regions (`ignore_throw` semantics) and
  memoized per signature (identity-keyed — hashing large signature types was itself the main cost);
- fast `:typestable` consults the boxing signal, matching JET's "no runtime dispatch" semantics.

### Multi-threading correctness (value-free IR scans, no backend needed)

- **`concurrency_safe` guarantee** — `@assert_concurrency_safe f(plan, args...)` asserts that `f`
  treats its **plan** argument (the first, by default) as read-only for the whole call: it writes
  no field of the plan and mutates no state reachable *only* through it. When it holds, one plan is
  safe to share across concurrent tasks (each with its own outputs/scratch). The intended use is an
  FFT-style apply: `@assert_concurrency_safe apply_unnormalized!(plan, x, alloc_scratch(plan))`
  (x and the scratch are the mutable outputs; the plan must be read-only).

  It works by forward-propagating a **reference taint** from the plan through the optimized IR —
  through `getfield`/`memoryref`/… that derive a *shared* reference, while a scalar field read like
  `plan.n::Int` is a copy and is ignored — and fails on any store (`setfield!`/`memoryrefset!`/…)
  whose container is plan-reachable. Crucially it **follows calls**: a plan-reachable value passed
  to a non-inlined child method is scanned recursively (bounded by `max_depth`, default 4), so a
  plan that accidentally calls a child's embedded-scratch *convenience path* — mutating
  `plan.children[i].scratch.data` one frame down — is caught even though the store is a frame away.
  A plan-reachable value handed to a known Base mutator (`push!`/`resize!`/…) or to dynamic dispatch
  is flagged conservatively (it prefers a false positive over a confident false pass). It does **no
  alias analysis** and bounds recursion depth, so it is a *complementary* static proof — pair it
  with a runtime concurrency test. Query form: `StrictMode.concurrency_findings(f, types)`.

- **`no_threadid_state` lint** — `@assert_no_threadid_state f(args...)` flags mutable state indexed
  by `Threads.threadid()` (the task-migration hazard: a task can move between OS threads, so
  `buf[threadid()] = …` can race). Best-effort; detects the direct/local `buf[threadid()]` shape.
  Query form: `StrictMode.threadid_state_findings(f, types)`.

- **`pool_balance_report(f, types)`** — a best-effort static smoke test that counts acquire-like
  (`take!`/`acquire`/`lock`) vs release-like (`put!`/`release`/`unlock`) calls and reports gross
  imbalance. Coarse (a static count, not a per-path match) — for the real leak-on-error-path case,
  wrap acquire/release in `try/finally` and assert balance at runtime.

## v0.3.2

Bugfix, non-breaking.

- **`@assert_noalloc` empirical path no longer false-fails on a `gc_num` accounting artifact (F33).**
  `@allocated` measures the `Base.gc_num().allocd` delta, which can be **nonzero with no real heap
  allocation** — an artifact seen on SIMD / `GC.@preserve`-heavy kernels that AllocCheck and
  `--track-allocation` both prove allocation-free (found dogfooding PureFFT's Butterfly256/512 AVX
  kernels). The `:fast` / `static = false` path previously failed whenever `@allocated > 0`, so it could
  reject provably-clean hot paths. It now **escalates to AllocCheck** when the analysis backend is loaded:
  it fails only if AllocCheck *also* finds a real allocation site; if AllocCheck proves the call clean, the
  number is treated as an artifact and the check passes (with a one-shot `@warn`). With no backend it still
  fails, but the message names the artifact possibility and points at `:full`. Real allocations continue to
  fail through the escalation. See `FEEDBACK.md` F33.

## v0.3.1

Additive, non-breaking: a new opt-in guarantee, a new diagnostic, and an optional weak dependency.


- **`trim_compatible` guarantee** — an exposed, *escalating* `juliac --trim=safe` compatibility guarantee
  (`@assert_trim_compatible` / `:trim_compatible`). In `:fast` (or when `TrimCheck` is not loaded) it runs
  the TypeContracts static IR scan; in `:full` with the new optional **`TrimCheck`** weak dependency it runs
  juliac's authoritative `verify_typeinf_trim` verifier over the exact signature; its output is parsed into
  deduplicated, source-mapped findings via `TypeContracts.TrimDiagnostics` (the same formatter `explain_trim`
  uses). Advisory and **opt-in** (not part of `@strict`). The existing `@assert_trim_safe` / `:trimsafe`
  remain as the static-only subset.

- **`divergence_report(f, types)`** — runs the `:fast` heuristic *and* the `:full` proof and, where they
  disagree on a guarantee, returns an **IP-free** [`StrictDivergence`](@ref): an anonymized signature shape
  (user / 3rd-party types → `T1, T2, …`; `Base`/`Core` names kept), the fired-signal **categories**
  (counts/booleans, never source), the inferred-return category, and all package/Julia versions. Send it to
  the maintainers to fix a heuristic gap. `StrictMode.save_divergence(d, path)` writes it to a file.

- New weak dependency + extension: `TrimCheck` → `StrictModeTrimExt` (the `:full` trim backend).
  `StrictMode.trimcheck_available()` reports whether it is loaded.
