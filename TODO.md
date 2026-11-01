# TODO

Small, tracked items. The tier-split design record is `SPLIT-PROPOSAL.md` in this directory.
GitHub issues are the source of truth for anything with a number; the notes here record what the
0.4.0 tier split changed about them, so nobody re-derives it.

## Open — GitHub issues, and what the 0.4.0 split changed

- [ ] **#17 — `:fast` noalloc false-positives on provably 0-allocation kernels.**
  Now the highest-value open bug: after the split, `:fast` is the ONLY engine an ordinary
  consumer gets, so a ~28% false-failure rate (19/68 on PureIPM, every one measuring 0 B)
  is no longer softened by "just use `:full`".
  Mechanism established 2026-08-17, not in the issue text: the heuristic reads **typed IR**,
  where the allocation is still present, and LLVM removes it afterwards — which is exactly
  what AllocCheck sees and the heuristic structurally cannot. Minimal reproducer:
  `mkvec(n) = length(Vector{Float64}(undef, n))` measures **0 B on both 1.12 and 1.13**
  while `_alloc_signals(...).alloc` is `true`.
  Dead end, do not retry: `Base.infer_effects` cannot discriminate the two — the elided case
  reports `effect_free=0` and the genuinely-allocating one `effect_free=1`, backwards.
  Also dead: widening the abstract-container rule to a dict's `valtype` and propagating it
  through `:invoke`. Measured inert for parity (an `IdDict`'s storage is `Memory{Any}`
  whatever its declared valtype, so the array rule already fires) and it flags every
  `IdDict` including the concretely-typed rare-type-tail fallback `static_ownership`
  prescribes — the issue-#7 gate that must not exist. It also cost a measured 7.6× on
  fresh scans of signal-saturated functions.
  *Reported, and now largely fixed at the source.* Two independent changes:
  (a) `_guarantee_gates` (report.jl) puts `:noalloc`/`:noboxing` in the reporting set, so a false
      positive warns instead of aborting a build; the proof that gates is `@test_noalloc`.
  (b) **Escape analysis**, `_all_news_nonescaping` in effects.jl. `Core.Compiler.EscapeAnalysis` on
      the same signature discriminates exactly the shape `infer_effects` could not: the issue's own
      reproducer reports `has_no_escape = true` on its `:new`, every shape that really allocates
      reports `false`. Both the `:new` rule and the `Core.memorynew` rule are gated on it, so
      `mkvec` now comes back clean. Measured over 11 shapes (escaping, runtime-size, 100k-element,
      `IOBuffer`, `Dict`, `push!`-grown, bare `Memory`, and two clean controls): **zero false
      negatives, one residual false positive** (`[n, n+1]`, still flagged, still the safe
      direction). Cost: ~0.69 ms cold per signature, 0.08 ms warm; memoized and cleared with the
      findings cache.
  *CORPUS RE-MEASURED, 2026-08-30 — and the escape-analysis fix is INERT on real code.* 120 compiled
  PureBLAS + PureIPM specializations, AllocCheck as the oracle, A/B by redefining
  `_all_news_nonescaping` to return `false` (the pre-fix behaviour):

  | | findings | false | rate |
  |---|---|---|---|
  | escape analysis OFF | 74 | 6 | 8.1% |
  | escape analysis ON  | 74 | 6 | 8.1% |

  Zero findings removed. The diagnostic says why: **63 of the 120 frames contain a non-isbits
  `:new`, and escape analysis proves the set fully non-escaping in 0 of them.** It fires on small
  self-contained kernels — the issue's own reproducer among them, which is why it stays — and not
  on the interprocedural shapes real library code is made of.

  Two further corrections to the text above, both from the same run:
  - The baseline false-positive rate on this corpus is **8.1%, not ~28%**. The 19/68 figure is from a
    different sweep and should not be quoted as the general rate.
  - The dangerous direction is the other one: the scan **misses 23** signatures AllocCheck flags
    (recall 68/91 = 75%), unchanged by the fix. That is by design after the split — the scan reports,
    `@test_noalloc` proves — but it is the number that matters for anyone tempted to gate on `:fast`.

  The analysis is now computed **on demand**, at the first non-isbits `:new`/`memorynew` that nothing
  else has already flagged. Eagerly it doubled the sweep (45.0s vs 21.7s for 120 signatures); lazily
  it costs 28.0s. Kept rather than reverted because it does fix the reported reproducer, but nobody
  should expect it to move a real consumer's numbers.
  *CONFIRMED DEAD ON 1.13, 2026-08-30.* The caveat below is no longer hypothetical: on the CI matrix's
  `~1.13.0-rc1` job, `_all_news_nonescaping(Tuple{typeof(mkvec), Int})` returns `false` and the issue's
  own reproducer is flagged again. The fallback behaved as designed — it degraded to over-flagging
  rather than quietly passing — and the `@test` that pins the analysis is what surfaced it, which is
  the only reason a silent internal move became visible. That job is `continue-on-error`, so this
  does not gate; it does mean the #17 mitigation is 1.12-only until the internal is located on 1.13.

  *Caveat:* `Core.Compiler.EscapeAnalysis` is a compiler internal with no cross-version stability
  guarantee. Every failure falls back to "assume it escapes" (the previous behaviour), so a Julia
  release that moves it degrades the rate rather than breaking the guarantee — but the fallback is
  silent, so the corpus re-measurement is also how a future regression would be noticed.

  *NEW `:new` RULE, 0.4.4 (2026-09-13).* Escape analysis was the wrong tool: it treats any value
  passed to a callee or a `ccall` as escaping. `_new_allocates` (effects.jl) now judges each
  non-isbits `:new` by its SSA uses. A value stored into an abstractly typed field is boxed. An
  immutable allocates only when it reaches a use that needs a box. A mutable used only by a `ccall`
  and its own field is a stack `Ref`. Any other mutable still goes to escape analysis, and any use
  the rules do not recognize counts as a box. Measured on PureOSQP's `admm_step!` and
  `update_residuals!` across 13 backends: agreement with AllocCheck went from 8 of 26 signatures to
  26 of 26.

  *CORPUS RE-MEASURED, 2026-09-13 (0.4.5).* The same 120 compiled PureBLAS + PureIPM specializations,
  AllocCheck as the oracle, the new rule A/B'd against the old one in one process: both agree with
  AllocCheck on **120 of 120** — 64 findings, 0 false positives, 0 missed — and a cold scan costs the
  same (old 4.5 s, new 4.3 s). The 8.1% / 75%-recall figures above are pre-0.4.3 numbers on this
  corpus and no longer reproduce. The gap they describe is structural — typed IR before LLVM against
  LLVM IR after it — and can return on other code, which is why this stays open.


  *A recurring shape, measured 2026-09-30 in UpdatableFactorizations.jl.* An in-place broadcast
  (`r ./= rho`) compiles to `Base.materialize!`, which keeps an `unalias` copy branch — `memorynew`
  plus a `%new(Matrix{Float64})` — that never runs when source and destination are the same array.
  The scan sees the statements, not the aliasing, so it reports `alloc`. The same shape appeared in
  three places there (`r ./= rho`, `z ./= g`); rewriting them as explicit loops made the enclosing
  keyword body scan `alloc = false`. Worth knowing before chasing an `alloc` finding on a body whose
  only suspect is an in-place broadcast: `@test_noalloc` is the arbiter, and a `.=` over a
  self-aliased array is a false positive by construction rather than a rule that can be tightened.

  The rule shipped one regression, fixed in 0.4.5: optimized IR may name a `:new`'s type with a
  `GlobalRef` (`%new(Base.ComplexF64, …)`), and an unresolved name counted as an allocation, which
  flagged 6 `ComplexF64` LAPACK routines that allocate nothing. `_new_type` resolves the name first.

  The change immediately exposed a false-premise test: `once_barrier_test.jl` asserted a fixture
  "genuinely allocates on every call" that measures **0 bytes** — a #17 false positive living inside
  the suite and asserting itself as correct. The fixture now escapes its allocation, and the
  `@allocated(...) > 0` guard added alongside is what catches that class.

- [x] **#18 — inert preferences / broken consumer precompile.** CLOSED. Part 2 is fixed and
  measured on a real consumer (see the 2026-08-30 note below). Part 1 is sidestepped rather than
  solved, and that was accepted: a `[preferences.StrictMode]` block that *disables* checks in an
  environment where StrictMode is not a direct dependency is still silently ignored. It fails in
  the safe direction — checks stay on — and making that loud was considered and declined.
  Part 2 (enabling checks globally breaks PureBLAS's precompile) had two causes: the proof
  tier demanding AllocCheck/JET during the *consumer's own* precompile, which is now
  impossible since `StrictMode` has no backend at all; and a false positive on `trmv!`, which
  is #17. A #17-shaped kernel can no longer red a precompile either — `@strict_function`'s
  allocation layer warns, per `_guarantee_gates`.
  Part 1 (a `[preferences.StrictMode]` block is inert unless StrictMode is a *direct* dep of
  that environment) is sidestepped rather than solved: `checks_enabled` now defaults to `true`,
  so a test environment needs no block at all and there is nothing to be inert. A block that
  *disables* checks in a non-direct-dep environment is still silently ignored — but that
  direction fails safe (checks stay on), and `StrictModeTest.__init__` errors if checks are off
  where the proofs are expected.
  *MEASURED, 2026-08-30.* A from-scratch precompile of PureBLAS + PureIPM under `checks_enabled =
  true` emits **24 warnings** and completes. That is a readable one-time volume, not a wall, so the
  default is usable. Note the reason it is this low is partly that `_guarantee_gates` demotes the
  allocation layer to a warning; the underlying scan still over-flags at the 8.1% recorded under #17.

- [x] **#19 / #20 — `@assert_trim_compatible` false FAILs.** BOTH CLOSED. Both live in
  `_be_trim_validate`, which moved to `StrictModeTest/src/StrictModeTest.jl` in 0.4.0; the
  issues still say `StrictModeTrimExt`, which no longer exists.
  #20 has a concrete, parse-free fix: `TrimVerificationErrors.errors` holds `warn::Bool =>
  desc` pairs, and juliac's own gate fails only on `warn == false`. Filter or relabel the
  warnings to match.
  #20 is FIXED: `_trim_verdict` splits `TrimVerificationErrors.errors` on its `warn` flag, so a
  raise carrying only warnings is a PASS, matching juliac's own gate.
  #19 is the deeper one, and the obvious fix is MEASURED WRONG. juliac includes
  `juliac-trim-base.jl` / `juliac-trim-stdlib.jl` before trim inference, and applying them is what
  makes the verifier check the program juliac actually compiles — but `juliac-trim-base.jl` stubs
  `Base.CoreLogging.current_logger_for_env`, so applying it IN-PROCESS silences every `@warn` and
  `@info` for the rest of the session. That is the whole of StrictMode's reporting tier going
  quiet: every `@assert_noalloc` would find its violations and say nothing. Observed directly —
  two `@test_logs` assertions in StrictModeTest's suite went empty the moment the patches were
  applied by default.
  FIXED by isolation: `set_juliac_patches!(true)` now runs the patched verification in a child
  process and reads back only the verdict, so the caller keeps its logging. TrimCheck's own
  `validate_function` runs `init_validation` on a Distributed worker for the same reason. The child
  reports whether the patches actually applied, and a verdict reached without them is refused
  rather than returned — juliac ships no patch files on some builds (1.13.0-rc4), and a silent
  fallback there would relabel a stock-Base verdict as a patched one.

  Still OFF by default: the child costs a Julia start and a package load per verification.
  Everything that can go wrong (a closure, a `@testitem` fixture the child cannot load, a spawn
  failure, missing patch files) degrades to unpatched in-process verification with a warning
  carrying the child's own stderr — never to a FAIL.

  CLOSED with one residual, deliberately: on a Julia shipping no juliac patch files there is
  nothing to isolate, so verification stays stock-Base and the false-FAIL class survives there.
  That is 1.13-specific and folds into the 1.13.0 work below rather than holding this issue open.

- [x] **#13, #14, #15, #16 — AUDITED 2026-08-30; all four are addressed.**
  - **#13 — FIXED, and the issue's stated objection is measured wrong.** The issue argues no
    heuristic is possible because a scan flagging small-`Union`-heavy call sites "would
    false-positive on exactly the callees that are fine". The IR says otherwise: a callee small
    enough to inline leaves no call behind at all, so the trivial four-`Val` repro produces no
    signal without needing to be excluded. `_union_split_findings` (trimsafe.jl) reports a call that
    SURVIVES optimization with union-typed arguments whose cardinality product exceeds inference's
    `max_union_splitting`. That is the mechanism, not a tuned threshold, and it explains the third
    data point the PureBLAS fix records — "the real gemm gets away with 2" — exactly: 2^2 = 4 is at
    the limit, 2^3 = 8 is over it.
    Agrees with juliac's verifier on all seven shapes tested, including the isbits-union idiom that
    looked like the false-positive risk: three `Union{Nothing,Int}` arguments at one call site, and
    the same shape built from `findfirst` returns, are BOTH genuinely rejected by the verifier.
    Swept 150 compiled PureBLAS + PureIPM specializations: the rule fired on 0, so no false
    positives — though the corpus contains no instance of the class either (PureBLAS's resolver
    chain removed the one it had), so that leg is weak evidence on its own.
  - **#14** — both proposed options shipped. `OncePerProcess`/`OncePerThread` auto-recognized,
    `register_alloc_barrier!` for hand-rolled equivalents, `StrictModeTest.set_ignore_barrier!`
    controlling whether the proof honors them.
  - **#15** — shipped, and the issue's acceptance sentence is a test: the masked-load shape
    reproduces the OOB read while `@assert_typestable` and `@assert_noalloc` both pass on it.
  - **#16** — both tiers shipped as sequenced. Tier 1 `@assert_no_spill` gates; Tier 2 `@assert_mca`
    is informational unless `max_rthroughput=`/`min_ipc=` is supplied, behind the `LLVM_full_jll`
    weak dep.
  Drafts written and awaiting approval before posting (GitHub is social media — no unapproved text).


## Open — added by the 0.4.0 split itself

- [ ] **The registry leg of "checked twice" does not work.** `@strict_function` registers via a
  `register_strict!` Dict insert executed at the consumer's precompile; that cross-package mutation
  is discarded on cached pkgimage load, so `check_all()` in a consumer's test process sees an empty
  registry and reports green. `check_signatures`/`audit` are unaffected (they enumerate directly).
  SPLIT-PROPOSAL §H.3 identified this mechanism and it was never applied to `registry.jl`.
  *REPRODUCED, 2026-08-30.* `test/consumer/` is a real second package: StrictMode in its own
  Project.toml, `@strict_function` in its `src/`, StrictModeTest only in its `test/`. Measured in
  its test process: `registered_strict()` is **completely empty** — 0 entries, not merely missing
  ConsumerPkg's. So the leg is confirmed dead end to end, not just derived.
  *Done so far:* every registry driver WARNS loudly on an empty registry, and the fixture asserts
  that warning, so the silent green is gone even though the false negative remains.
  *Design considered and DEFERRED (adversarially reviewed, both critics "sound-with-changes"):*
  replace the Dict with never-called marker METHODS (`_strict_declared(::typeof(f), ::Type{Tuple{…}},
  ::Val{guarantees})`), read back via `methods()` and `m.sig` — a method definition is baked into the
  defining module's pkgimage where a Dict insert is not. Verified cheap: reading `m.sig` costs 0.8 ms
  where calling 302 markers to fetch a body payload cost 1.54 s.
  Not taken, because markers are SESSION-GLOBAL AND PERMANENT where the Dict is ephemeral, and two
  reviewers independently demonstrated that this converts the false negative into worse bugs:
  (a) **Cross-package false positive.** `check_all` has no module filter and `audit`'s default target
      is `:registered`. Today a dependency's Dict inserts are discarded on cached load, which is the
      only reason this is harmless. With markers, every dependency precompiled under the consumer's
      `checks_enabled = true` emits markers that the consumer's scan recovers — so package A's CI
      goes red for package B's kernels, analyzed under A's backend, with no way to scope it out.
  (b) **A NEW silent skip.** Making `@strict_exempt` survive precompilation, while `_is_exempt` stays
      keyed on a bare `Set{Symbol}` with no module, turns a today-unreachable cross-package name
      collision into a permanent graph-wide skip. Measured live: `check_compiled(MyPkg)` drops from
      2 findings to 0 when an unrelated module exempts the name `:setup`.
  Doing this properly therefore requires module-scoping BOTH the marker scan and the exempt set —
  a change to a core structure used in four places, not the drop-in the design presents.

- [ ] **Register `StrictModeTest`.** Subdirectory package; Registrator supports `subdir=`. Needs a
  decision on subdir-vs-own-repo and whether its version tracks StrictMode's (both 0.4.0 now).
  Not urgent: nothing consumes 0.4 yet. It becomes load-bearing the moment one does, since every
  gating entry point lives there.

- [ ] **A global Stop hook runs `audit` in every consumer repo, and 0.4 breaks all five of them.**
  `~/.claude/hooks/strictmode-stop.sh` (registered in `~/.claude/settings.json`) runs a
  project's `strictmode_audit.jl` at the end of every agent turn and BLOCKS the stop on a
  non-zero exit. It is a no-op for this repo (no audit script at any of its four conventional
  paths), which is why it never fires here. Every consumer script uses API 0.4 deleted:
    - `StrictMode.backend_available()` — BlazingPorts, PureFFT, PureIPM, PureSparse
    - `StrictMode.check(f, types; mode = :full)` — PureOSQP
    - `exit(nfailures(audit(PureIPM; format = :json, mode = :fast)))` — PureIPM
  Each throws `UndefVarError`/`MethodError` on load, so the hook reports "audit FAILED" with
  an unrelated error and blocks every turn in that repo. Loud, not silent — but it stops work.
  **URGENCY: this is NOT gated on registration.** `BlazingPorts.jl` sources StrictMode from
  `rev = "master"`, so merging this branch to master breaks it on the next resolve.
  **But the migration IS gated on it, which makes the two claims a sequencing constraint rather
  than a contradiction.** Each migrated script needs `StrictModeTest` in a `Project.toml`, and
  that is not resolvable from any of these repos until StrictModeTest is registered (or each repo
  takes a `rev`/`subdir` pin). A local `Pkg.develop` makes it work on this machine and commits
  nothing usable. So: do not merge this branch to master before StrictModeTest is resolvable —
  merging first is what breaks BlazingPorts, and there is no migration that can land ahead of it.
  All five scripts confirmed present at the hook's conventional paths, 2026-08-30:
  BlazingPorts `bench/` (110 lines), PureFFT `bench/` (71), PureIPM `benchmark/audit/` (64),
  PureSparse `benchmark/audit/` (135), PureOSQP `bench/` (191).
  `PureFFT.jl` pins `rev = "v0.3.3"`; the other three come from the registry and are pinned
  to 0.3.10 until 0.4 is registered.
  **Migration trap, PureSparse specifically:** its script's ONLY verdict mechanism is
  `@assert_noalloc static = false` throwing — its two `error(…)` calls are preconditions, and
  it ends by printing "PASS". Under 0.4 it breaks loudly at `backend_available()`, which is
  fine. But the naive fix — renaming that to `proofs_loaded()` — makes it SILENTLY VACUOUS:
  all twelve assertions warn instead of throwing, the script prints PASS, exits 0, and the
  hook stamps it green. It must move to `@test_noalloc` / `test_signatures`, not be renamed.

  *Migration per script:* `backend_available()` → `proofs_loaded()`; `check(…; mode = :full)`
  → `StrictModeTest.test_signatures`; `exit(nfailures(audit(…)))` → `test_compiled(MyPkg)`,
  since `audit` deliberately no longer gates or sets an exit status.
  Note the hook's own anti-vacuity guard (it refuses to stamp a run whose output says
  `checks are disabled`) still matches the new checks-off CI banner, so that half is fine.

- [ ] **No consumer has been migrated to the 0.4 surface.** PureBLAS alone has 27 `@assert_noalloc`
  and 85 `@assert_trim_compatible`; under 0.4 every one of them reports where it used to gate, and
  `check_signatures`/`check_all`/`audit(...; exit_on_fail = true)` no longer exist. The load-time
  banner is the mechanism that makes the change audible (release notes are not — this branch is
  seven demonstrations of that), but nothing has been run against a real consumer to check that the
  banner actually lands and that the migration is mechanical.

## Open — deferred from the whole-branch adversarial review

- [ ] **`scalar_fp_loops`'s "hand-vectorized" discriminator is unsound (issue #22 follow-up).**
  `a4fe1ca` distinguishes a hand-written scalar tail from LLVM's own `@simd` epilogue by asking
  whether the function ALSO contains raw `<N x …>` ops without the loop-vectorizer's
  `vector.ph`/`middle.block`/`scalar.ph` scaffolding. Demonstrated wrong: LLVM's **SLP vectorizer
  and unroller** emit `<N x …>` ops with none of those labels, so an ordinary
  `acc += z[i] * (a + 2.0im)` loop over `Vector{ComplexF64}` plus a separate `@simd` loop reads as
  "hand-vectorized" and its epilogue gets flagged — the exact thing the commit says must never
  fire. Complex arithmetic + `@simd` is a bread-and-butter shape for this package's own dogfood
  targets (FFT).
  Not a regression (the shape false-positived before via the integer-phi branch), but the commit's
  soundness argument and its docstring's "e.g. explicit SIMD.jl code" are both wrong.
  *CONFIRMED by direct measurement, 2026-08-30, and TWO candidate fixes are dead.* The predicted
  shape reproduces: a function with `acc += z[i] * (a + 2.0im)` over `Vector{ComplexF64}` plus a
  separate `@simd` loop returns `true`. Its four loop regions are the unroller's main body and
  epilogue for the complex loop (vector ops, no scaffold in the region — so they read as
  "hand-vectorized"), the `@simd` loop's `vector.body`, and that loop's `scalar.ph`-rooted
  remainder, which is what gets flagged.
  - **Dead: a vector-typed loop-carried phi (`phi <N x …>`) outside the scaffold.** The premise was
    that only a loop transformation can create one. Measured wrong — the complex loop's SLP/unrolled
    regions carry `phi <2 x double>` with no scaffold, identically to hand-written SIMD.jl code.
  - **Dead: judging the scaffold whole-function instead of per region.** Structurally the better
    reading (`vector.ph` is the preheader and `middle.block` the exit, so neither is inside the
    back-edge region the check tests), and it does fix the false positive. But it regresses issue
    #22's own false-negative reproducer: LLVM vectorizes `body_plus_scalar_tail!`'s hand-written
    scalar tail, so scaffold appears somewhere in that function too, and the whole-function rule then
    reads it as "no hand vectorization" and skips the tail. Trading the false positive for a false
    negative on the reported case is not a fix.
  A note for whoever picks this up: the two reproducers may not both be satisfiable as stated.
  `body_plus_scalar_tail!` wants `true` because its *source* has a scalar tail, but LLVM vectorizes
  that tail, and the commit's own principle — the vectorizer's bounded remainder carries no
  information — argues the compiled output is fine. This check reads compiled output, so the two
  test expectations may be in tension rather than the discriminator merely being weak.
  *Mitigated meanwhile:* `_guarantee_gates` puts `:no_scalar_loops` in the reporting set, so a false
  positive warns instead of aborting a build.

## Open — from the 0.4 adversarial review (129 agents, 39 findings, all 3-vote verified)

Fixed in the same pass, listed here only so nobody re-derives them: `_fail` named macros that do
not exist (`@no_scalar_loops`, `@test_trimsafe`); `test_signatures`/`test_compiled` returned green
on an empty scope with no signal; `concurrency_findings`/`threadid_state_findings` returned `[]` —
a PASS on a *gating* guarantee — when `code_typed` failed; `_registered_findings_in` swallowed
per-signature analysis errors, so the `@strict module` load gate silently skipped methods;
`_cache_key` omitted `_FAST_ALLOC_DEPTH[]`; the load banner claimed no `@assert_*` gates;
`test/unroll_test.jl` and `test/typestable_test.jl` had lost their power to fail;
`test/standalone`'s isolation assertion was decorative (verified: it passes without
`JULIA_LOAD_PATH`, so dropping the CI env var would leave the split-premise gate green).

## Open — Julia 1.13.0

- [ ] **Julia 1.13.0 support.** Three things are known to differ, each already handled defensively
  but none actually working on 1.13:
  (a) **juliac ships no trim patch files.** They are under `share/julia/juliac` on 1.12 and
      1.13.0-rc3 and absent on rc4, so `set_juliac_patches!(true)` has nothing to apply and trim
      verification stays stock-Base — the false-FAIL class from #19 is still present there.
      `_trim_validate_subprocess` refuses to return that verdict as a patched one, so the failure
      is loud rather than mislabelled, but the class is not fixed. Find where juliac moved them,
      or reproduce what they do.
  (b) **The escape-analysis mitigation for #17 is dead.** `_all_news_nonescaping` returns `false`
      on 1.13 because `Core.Compiler.EscapeAnalysis` moved; the fallback is "assume it escapes",
      so the issue's own reproducer is flagged again. Locate the internal on 1.13.
  (c) **`typeinf_ext_toplevel` gained a fourth argument** (`external_linkage::Bool`) in 1.13.0-rc4.
      Already handled by `_typeinf_toplevel`'s `hasmethod` dispatch rather than a `VERSION` bound,
      since the argument arrived mid-release-candidate.

  The 1.13 CI job is `continue-on-error`, which is why none of these gate. That flag should come
  off as part of this work, or the job is decoration.

## Planned — v0.5

- [ ] **Share one typed-IR read across a sweep.** `audit(mod; sweep = true)` reads `code_typed` once
  per specialization for the allocation/type-stability scan, and the dispatch pass reads it again.
  Measured on PureBLAS (10,974 specializations): the dispatch pass costs 43.5 s, of which
  `code_typed` alone is 43.2 s — the analysis on top is ~0.2 s. So the whole 17.8% sweep overhead is
  the duplicate read, and plumbing one `CodeInfo` per `(f, tt)` through
  `_findings_compiled`/`_alloc_signals`/`_dispatch_sites` removes it. Touches the core scan path,
  which is why it is not a patch release.

- [ ] **Expose `audit` as a tool on the Julia MCP server.** `audit(...; format = :json)` is already
  machine-readable, so what a tool adds is the warm session: an agent pays Julia's full compile tax on
  every cold invocation today. Options weighed: a tool in the existing `julia_*` server (cheapest,
  reuses its worker), a standalone `StrictModeMCP.jl` stdio server (own lifecycle, own release), or
  documenting the cold one-liner (free, keeps the tax). Prefer the first.

- [ ] **Widen `@strict`'s default set, and let a package declare it.** BREAKING (see (a)).
  0.4.x ships the non-breaking half: `:owned` runs inside `@strict` as a REPORT (`gates = false`
  at the call site in `_strict_expr`), so the dict-lookup class is visible on every `@strict` site
  without changing whether anything throws. `@assert_owned` still gates when named directly.

  The 0.5 change is to promote it and make the set declarable:
  (a) `:owned` GATES from `@strict`. Breaking: any `@strict` site reaching a runtime `AbstractDict`
      accessor starts throwing where it passed. Note the rule flags ANY dict accessor, key type
      unchecked, deliberately (`static_ownership.jl` — `@assert_owned` is about any runtime-keyed
      owned scratch). A legitimate value-keyed cache under `@strict` would fail, which is the
      whole reason 0.4.x reports instead. Gate only with evidence on the false-positive rate,
      the way `:noalloc` earned its reporting status in #17.
  (b) `:trim_compatible` joins the set, behind a declared preference — it is pure noise for a
      package that never runs juliac, and it adds a `_trim_report` per call site (unmeasured).
  (c) `set_default_guarantees!(...)` as a Preference beside `checks_enabled`, so "mandatory, then
      opt out when not necessary or possible" is a per-package declaration rather than one
      hardcoded set. `(:typestable, :noalloc)` is currently hardcoded in four places —
      `check.jl` (`findings`), `registry.jl` (`register_strict!`, `_compiled_items`,
      `_findings_compiled`).
  (d) `exclude = (...)` on `@strict`, the per-call escape, mirroring `@strict_exempt`'s role for
      `@strict module`.

  Not in the set: `:noboxing` (its rule is a strict subset of `:noalloc`'s — reports the same
  violations twice, detects nothing extra) and `:trusted` (a safety invariant, so it belongs in
  the module sweep as deny-by-default, not in a per-call macro).

  Widening `@strict` broadens what you LEARN while editing; it does not make anything ensured.
  The scan is unsound by measurement (75% recall on `:noalloc`, #17). Assurance comes from
  widening `register_strict!`'s default, since that is what `test_registered()` re-proves in CI
  through StrictModeTest.

- [ ] **`:trusted` — deny-by-default in the module sweep.** Additive; nothing below removes API.
  0.4.x ships the mechanism and a per-call diagnostic: `Untrusted{T}`, `unsafe_trust`,
  `trust_boundary!`, `@assert_trusted`. Dispatch already enforces the type with no checker at all
  (an `Untrusted{Vector{UInt8}}` matches no method written for `Vector{UInt8}`, in a shipped build
  too, since the type is never gated away).

  What is missing is that the check is opt-in, which is the failure the pattern exists to prevent —
  the kernel's `__user` annotations are only checked when someone runs `make C=1`, and a safety
  invariant nobody runs is not an invariant. The v0.5 pieces:
  (a) No new macro. `trust_boundary!(f)` stays the way a boundary is declared: a plain function,
      the same shape as the exported `register_alloc_barrier!(f)`. The load-order window it opens
      (a sweep running between the definition and the registration call) is closed by running the
      sweep at the END of the module, not by wrapping every boundary in a macro.
  (b) Sweep every method of a `@strict module` at precompile, refusing to load on a payload read
      outside a boundary. `_auto_check_module` already walks the module; `@strict_exempt` already
      provides the opt-out.
  (c) Scan LOWERED method ASTs (`Base.uncompressed_ast`), not `code_typed`. Verified: this finds
      `unsafe_trust` in a method that was never called, has zero compiled specializations, and
      carries no type annotations — closing both the per-specialization coverage gap and the
      `Any`-erasure gap. Precise for `unsafe_trust` (its only method takes `Untrusted`, so a
      syntactic call IS a crossing); over-approximate for `getfield`/`getproperty` without types,
      which is why the typed scan stays as the second layer.

  Costs nothing for a package that never uses `Untrusted`: no `unsafe_trust` calls, so the sweep
  finds nothing. That is what makes it safe to make always-on, unlike `:trim_compatible`.

  Not closable, ever: `getfield` is a builtin and reads any field of any object, so the payload
  cannot be made unforgeable — Julia has no privacy primitive. The achievable goal is Rust's
  practical one, that the escape hatch is rare, named, greppable and deniable, not that it is
  impossible.

- [ ] **Remove `@assert_trim_safe` / `:trimsafe`.** BREAKING. Deprecated in 0.4.x — it warns once
  per session and its docstring points at `@assert_trim_compatible`; this item is the removal.
  The package already treated it as superseded — `check.jl`'s `_trimsafe_finding` calls it "the
  static-only subset of `:trim_compatible`, kept for compatibility", and its own docstring said
  prefer the other. Two macros for one question is the kind of surface that makes 26 exported
  macros feel like 26 separate things to learn rather than one family with a naming rule.

  Counting rule for anything proposed here: a new guarantee costs ONE macro, `@assert_<name>`,
  because `_macro_names` derives that spelling and `findings_test.jl` asserts it exists. Anything
  beyond that — a second spelling, a declaration form, a variant — needs to justify itself against
  this list, not against its own usefulness in isolation. `:trusted` deliberately adds no second
  macro: `trust_boundary!` is a function.

## Open — the gaps the Rust comparison identified (0.5.6)

`docs/src/guarantees.md`'s "Compared with Rust" section ends in an **Identified gaps** list. These
are those gaps as work items. The framing they come from: safety, flexibility and speed together,
with memory safety never at stake — so what is missing is never safety, it is a property that holds
for *every* caller rather than the ones a sweep reached.

- [ ] **A property that holds for every caller, not every compiled signature.** This is the shape
  of both gaps below and is worth naming once. `Send`/`Sync` are decided for all code before it
  runs; every StrictMode check answers for the signatures it was pointed at, or for the ones that
  have compiled. Julia offers no construct that would close this in general — `@assert_noalias` is a
  run-time assertion precisely because nothing in the language can decide overlap for a future
  caller. So the realistic target is not "prove it for all callers" but "make the uncovered set
  visible", which is what `test_coverage`'s default-deny does for declarations and nothing yet does
  for a guarantee's *argument space*.

- [ ] **Compile-time data-race freedom.** `@assert_concurrency_safe` and `@assert_no_threadid_state`
  are IR scans and **field-insensitive**: a task writing a disjoint slice of a captured output
  reports, because a partition is a property of values and the scan has none. Recorded in
  `concurrency.jl` as deliberate. What would move this forward, in increasing cost: (a) sweep
  `:concurrency_safe` as well (see below), (b) a declaration primitive for "this task owns this
  slice", settled against real shapes rather than invented ones — PureAtomistic has three, and that
  is the reason this is not designed yet, (c) a `Send`/`Sync`-shaped type-level marker, which is a
  language-design question rather than a package one.

- [ ] **Deterministic release of resources that are not memory.** `Drop` runs at scope exit on every
  path; Julia's collector decides when, and for a GPU buffer the CPU collector cannot see the
  pressure at all. `resource_leak_report` finds a handle that outlives its owner — returned, stored
  outside a scoped owner, or captured by a task — and deliberately stops short of proving release,
  because that needs post-dominance over the exception CFG and a `close` in a helper defeats it.
  Not a reason to leave it alone forever: the narrower question *"is there a path from this
  acquisition to no release"* is answerable for a body with no helper calls, and that subset covers
  the common `open`/`close` pair. Worth scoping before building.

- [ ] **Sweep `:concurrency_safe`.** It is a value-free scan that is NOT in `_GUARANTEES`, so it is
  one of the five guarantees still needing a hand-written annotation. `:no_threadid_state` joined the
  sweep in 0.5.6 and the pattern is established: clear the signature from compiler effects where
  possible, fall through to the taint scan otherwise. The four that genuinely cannot be swept are
  `:noalias` and `:memsafe` (they need argument values), `:mca` (a 680 MiB optional dependency) and
  `:effects` (no default set — only the caller can name which effects it wants). So this is the last
  one available, and it would take hand-annotation from 5 of 17 to 4 of 17.

- [ ] **`conversion_report` should name the offending literal.** It reports that a method converts
  `Float32` to `Float64` and cannot say *which* constant did it. `TypedSyntax` maps inferred types
  onto source positions, which is exactly the missing piece, and it needs **no new dependency**:
  `Cthulhu` is already a StrictMode weak dep and vendors it. Measured on the current check: 0
  findings over StrictMode's 618 methods, 150 over `Base.Math`'s 535 (120 widened, 46 retyped, 7
  narrowed) — the `Base.Math` findings are correct code, which is why naming the literal matters more
  than tightening the rule.

- [ ] **`conversion_report`'s deliberate-wider-accumulator false positive.** A `Float64` accumulator
  over `Float32` data for numerical stability is correct code and is reported. Pinned by a test
  (`wide_acc`) so a change in it is visible, and the reason the check is `:info` with no gating
  counterpart. A fix would need to distinguish "wider because the author chose stability" from
  "wider because a literal leaked", which is intent and not in the IR. Possible partial signal: an
  accumulator initialized from a *literal* of the wider type, versus a value converted from the
  data. Unverified.

- [ ] **`_UnanalyzableSignature` is private, so a caller cannot name it in a `catch`.** `pool_balance_report`
  raises it rather than counting nothing, which is right, but a consumer writing a sweep of their own
  has no way to catch exactly that. Additive fix: export it, or give it a public supertype.

### Dead ends from the 0.5.6 effects survey — measured, do not retry

All nine `Core.Compiler.Effects` fields were checked against StrictMode's existing concerns.
`effect_holds` now accepts all nine, so these are available to `@assert_effects`; what follows is
why four of them do **not** answer the questions they appear to.

- **`:noub` cannot flag `@inbounds`.** It is a PROOF of no undefined behavior, so `false` means
  unproven, not present. Measured over 7 fixtures: it agrees on four (`withib`/`noib`,
  `caller`/`safecaller` — including the case where the `@inbounds` sits in an `@inline` helper and the
  caller's own `ssaflags` scan is blind) and gives **three false positives** (`readsglobal`, `dyn`,
  `taskstate` — all `noub = false` with no `@inbounds` anywhere). A non-`const` global read and a
  dynamic call are not undefined behavior. So `unsafe_report` keeps reading `ci.ssaflags`, which
  answers *who wrote it*; `noub = true` remains usable as a clear, not as a finding.
- **`:inaccessiblememonly` and `is_inaccessiblemem_or_argmemonly` cannot separate reading an argument
  from writing it.** Measured: `readsarg` and `writesarg!` both report `true` for the latter, and
  `pure` reports `false` for the former because it touches no memory at all. That read/write
  distinction is the only thing `:noalias` and the plan-read-only half of `:concurrency_safe` care
  about, so neither field helps them.
- **`:consistent`, `is_foldable` and `is_removable_if_unused` are `true` only for a method that
  touches no memory.** Measured `true` for `pure` alone; `readsarg` — a plain read of two array
  elements — is already `false`. Useless on kernels, which is every case of interest.
- **`:nortcall` is weaker than what already exists.** It discriminates dynamic dispatch
  (`dyn` false, `stat` true) but whole-method only, where `dispatch_report` gives per-call-site
  detail. Possible pairing with `:trim_compatible`, since juliac rejects unresolved calls; not
  pursued.

## Open — from the PureAtomistic/PureMLIP adoption of 0.5.6

Reported after adopting 0.5.6 against a MACE model. Two of the four findings were bugs and are
fixed in 0.5.7 (both tiers now answer `:no_threadid_state`, `:noescape` and `:trusted` from one
implementation). These two remain.

- [ ] **`conversion_report` attributes a Base callee's conversions to the caller.** Measured:
  `f(x::T, n::Int) = x^n + one(T)` at `(Float32, Int)` reports TWO findings —
  `Float32 → Float64 (widened)` and `Int64 → Int32 (narrowed)` — and **neither is the caller's**.
  Base's generic `^(::Float32, ::Integer)` widens internally, inlines, and its 16 conversion
  instructions land in the caller's optimized IR with operand types the caller's own arguments
  name, which is exactly the filter `_conversions` uses. A literal exponent (`x^3`) is clean,
  because `literal_pow` becomes repeated multiplication, so this only bites the generic path.
  Consumers currently have to allowlist the calling function by name, which also hides any real
  leak in it.

  *Two fixes measured and DEAD, do not retry:*
  (a) **`code_typed` debug info.** `ci.debuginfo.edges` is **0 entries** for an optimized
      `CodeInfo`, and `Base.IRShow.append_scopes!` reports every one of Base's 16 conversions as
      coming from the caller's own file. The provenance is already collapsed.
  (b) **Innermost inlining frame.** `Base.code_ircode` DOES keep the edges (`edges = 2`, stacks
      like `provenance.jl+pow.jl+intfuncs.jl+number.jl+boot.jl`), so the data exists — but it does
      not separate the cases: the genuine leak in `0.529 * x` also has `float.jl` innermost,
      because its `fpext` materializes inside `Base.:*` after inlining. Innermost-frame-is-Base is
      true for every conversion, real or not.

  *The direction that remains:* trigger on **a wider-typed literal constant in the method's own
  statements**, not on the conversion instruction alone. That is what the docstring already names
  as the fix ("suffix the float literals"), and `0.529` is a `Float64` constant in the caller's IR
  while `x^n` introduces none. It changes what the check keys on, so it is not a patch-level tweak.

- [ ] **`alias_guard_report`'s signal-to-noise is too low to gate on.** It flagged 28 mutating
  kernels in one package — effectively every `!` method with two or more array arguments, since
  none names `mightalias`/`unalias`/`dataids`/`===`. Most take a caller-owned workspace plus
  read-only inputs of different shapes and element types, so they cannot alias at all. It is
  `:info` with no gating counterpart, so nothing is broken; it is just not usable as a gate.
  *Refinements suggested from the field, in increasing cost:*
  (a) skip argument pairs whose element types or dimensions differ — cheap, and `Base.mightalias`
      already answers `false` for those, so the scan is stricter than the run-time check it stands
      in for;
  (b) skip arguments that are fields of a `register_scoped!` type, since a workspace handed in by
      the caller is owned rather than aliased;
  (c) accept a per-method declaration ("these arguments never alias") that the gating tier then
      proves, which is the same shape as `@strict_function`'s `signatures =`.
  (a) looks worth doing on its own and needs no new surface.

## Open — from the PureBLAS adoption report (against 0.5.4)

Reported against 0.5.4. The headline ask — a gating form for specialization count — **already
exists** and the reporter had it: `StrictModeTest.test_specializations(mod; baseline, workload)`
landed in 0.5.3 and is documented in `docs/src/proof_tier.md`, both as a table row and a docstring.
It was missed because the gating surface was enumerated as `@test_*` MACROS and this one is a
function. Worth noting as a discoverability result rather than a capability gap: the one real
measured cost in that report (a `@generated` ladder going from ~576 to 1536 specializations, caught
only when a package image grew 383 MiB) is exactly what the growth gate catches.

- [ ] **A gating form for an ABSOLUTE specialization budget.** `test_specializations` gates GROWTH
  against a stored baseline, deliberately — there is no universal threshold, which is why
  `specialization_report` is `:info`. But `specialization_report(mod; max_specializations = N)`
  already takes a project-chosen limit and emits findings against it, and nothing can fail on them:
  `nfailures` is `count(_failed, fs)` and `_failed` is `status === :fail`, so an `:info` finding
  never fails a suite (confirmed). So the missing piece is narrow: a driver that takes the same
  explicit budget and raises. The argument for it over the growth gate is that a budget is a number
  the project has written down and agreed to, where a baseline is whatever happened to be true when
  it was recorded. The argument against is one more entry on a gating surface that is already large
  — see the surface-area note under the 0.5.6 gaps.

- [ ] **A sorted summary view for a large report.** `specialization_report` on a big package returns
  tens of findings, and an agent reading a tool result gets the two-argument
  `show(io, ::Vector{StrictFinding})`, which is one line — measured 3935 characters and **zero**
  newlines for 25 findings. The `MIME"text/plain"` method and `format_findings` are both multi-line
  (76 newlines for the same vector), so the data and a readable rendering already exist; what is
  missing is a view sorted by the number that matters, descending, with the limit beside it. Purely
  presentation. The separator bug behind the complaint (`fooTuple{…}`, name running into signature)
  is fixed.

- [ ] **`migration_report` scans only `.jl`, and a stale name often lives in a `.md`.**
  The rename IS covered: `_REMOVED_API` in migration.jl carries
  `"@assert_trim_safe" => "@assert_trim_compatible"`, and a fixture puts it at
  `src/Old.jl:2` with the replacement named. What it does not do is read documentation — a
  `CLAUDE.md` or README still saying `@assert_trim_safe` is invisible to it, which is where the
  reported instance actually was. Scanning `.md` for the `_REMOVED_API` keys alone (not the
  gating-macro pairs, which are legitimately discussed in prose) would close that, and the table
  needs no new entries.

- [ ] **An assertion guarded on the predicate it asserts.** Reported from a sibling session:
  `if _SME_F32; @test f32_detected_wherever_f64_is; end`. A mistyped sysctl key makes `_SME_F32`
  false, the block is skipped, and the suite passes vacuously on exactly the bug the test exists to
  catch — found by breaking the gate deliberately, where the evidence was the assertion COUNT
  (10 of 13 ran, not a failure). This is the vacuous-green shape `proofs.jl` already names, in a
  mechanical and detectable variant: an `@test`/`@assert_*` whose only enclosing condition is the
  predicate it is asserting about.
  *Scope question, undecided:* every check here reads typed IR or compiled output of a COMPILED
  METHOD. This pattern lives in the source text of a test file, which is a different analysis and a
  different tool class — closer to what `TypedSyntaxNode` or a JuliaSyntax pass would do. A cheaper
  partial answer, in the existing idiom, is to report the assertion COUNT the way the reporter used
  it: a suite whose executed-assertion count drops is the signal, and that needs no source analysis
  at all. Decide which before building either.

## Open — from the 0.5.7 code review

- [ ] **A store through an object LOADED from a threadid-indexed slot is invisible, and this
  guarantee GATES.** The threadid scan taints the `threadid()` result and the `memoryref` built
  from it, so `FLAT[Threads.threadid()] = 1` is found. It does not taint a value loaded back OUT
  of that slot, so a store into that value is not. Measured on 1.13.3:

  | body | findings |
  |---|---|
  | `FLAT[Threads.threadid()] = 1` (flat array) | 1, certain |
  | `@atomic FLAT[Threads.threadid()] += 1` (`AtomicMemory`) | 1, certain |
  | `PL[Threads.threadid()].value = 1` (array of mutable structs) | **0** |
  | `@atomic AC[Threads.threadid()].value += 1` | **0** |

  *CLOSED in 0.5.7.* The mark now carries through a `_PROJECT_OPS` read whose result can hold a
  reference, so a store into an object loaded out of a threadid slot is found; a scalar copied out
  is not. Measured: 8 hazard shapes report with `certain = true`, 7 read-only shapes stay clean,
  and 0 positives over the 39 Base/stdlib MethodInstances whose IR mentions `threadid`. One
  correct-code shape reports and is documented rather than special-cased: a lock striped by thread.
  Two limits remain and are pinned — a threadid stashed into another array, and a write inside a
  callee the optimizer left out of line.

  Note the third row: it is NOT about atomics. A per-thread array of mutable cells — an ordinary
  way to write exactly the hazard this check exists for — passes silently, and
  `_guarantee_gates(:no_threadid_state)` is `true`, so it passes a GATE. The code review
  attributed this to the `:invoke_modify` statement head; that was one of two causes and fixing it
  did not fix these rows.

  *The shape of the fix:* a third taint set beside `tid` and `tidref` for values loaded out of a
  threadid-derived reference (`memoryrefget`/`getfield` on a `tidref`), so a store whose CONTAINER
  is in that set records. It is a taint-propagation change to a gating scan, so it wants its own
  review and its own false-positive measurement over a real package before landing — a value loaded
  from a per-thread slot and then written is the hazard, but a value loaded and only READ must stay
  clean.

- [ ] **`findings(f, types; guarantees = (:no_threadid_state,))` returns `:pass` for a signature
  with NO method.** `effects()` on the MethodError path satisfies `notaskstate`, so the fast clear
  fires and the scan never runs. "Could not check" renders as a pass, on a gating guarantee, which
  is the invariant CLAUDE.md states must never break (`_unevaluated` exists for exactly this).
  Surfaced by the first adversarial pass, pre-existing. The fix is to confirm a method exists
  before trusting the effects clear.

- [ ] **`audit` does not expand policy-set names.** `audit(Mod; guarantees = :all)` throws
  `MethodError: iterate(::Symbol)` from `_split_exempt`, and `guarantees = (:all,)` produces one
  `:fail "unknown guarantee :all"` per item. Only `register_strict!`, `@strict_policy` and
  `@strict_function` route through `_check_guarantees`. Pre-existing; the asymmetry is surprising
  given both take a `guarantees` keyword.

- [ ] **Nested and alternate markdown fences in `migration_report`.** The fence tracker counts any
  line starting with three backticks, so a three-backtick block inside a four-backtick block closes
  the outer one early, and `~~~` fences are not recognized at all. Both are false negatives only,
  and the scan is informational and uncounted, so this is cosmetic until someone reports a miss.
  Recording the backtick-count fix: remember the opening run length and close only on a run at
  least that long.

## Done

- [x] **§8–§11 adversarially reviewed.** Done: 129 agents across eight lenses, every finding
  put to three refuters. Eight live vacuous greens came out of it and are fixed (see the
  commit and the section above). Two caveats on the review itself, so its result is not
  over-trusted: 39 of 39 findings survived verification, which for refuters told to default to
  `refuted = true` means the verify stage was not discriminating — the load-bearing claims were
  re-checked by hand before being acted on. And the single worst finding (`concurrency.jl`
  passing a GATING guarantee on a signature it could not analyze) came from the completeness
  critic, not from any of the eight lenses: no lens had been pointed at that file.

- [x] **`_suggestion` was missing ONE entry, not five.** Fixed. `:trim_compatible` is in
  `_GUARANTEES` and is constructed as a `StrictFinding` in two places, so it genuinely shipped
  with an empty `suggestion`. The other four the item named — `:concurrency_safe`,
  `:no_threadid_state`, `:memsafe`, `:mca` — have NO path to a `StrictFinding` at all: they are
  macro-only and terminate at `_fail`, which builds a `StrictViolation` (a `details::String`,
  no `suggestion` field). They are also absent from `_GUARANTEES`, so `findings`/`audit` cannot
  request them. Adding branches for them would have been dead code. If agents should get
  machine-readable hints for memsafe/mca/concurrency, the real gap is that those guarantees
  have no findings-pipeline representation — a much larger change than a `_suggestion` branch.
  The test enumerates `_GUARANTEES` from the code, and pins the anti-vacuity direction too
  (a non-guarantee symbol must still return `""`).

- [x] **`barrier`'s exclusion from the recursion short-circuit is one-sided, and documented.**
  Reachability re-established after the split: `barrier` has exactly two readers —
  `_checked_allocs` (StrictModeTest/src/proofs.jl), which still demands a clean signal set, and
  an informational label in `@explain`. The stop can only fire once alloc+boxing+dictlookup are
  all set, and those propagate monotonically upward, so a missed `barrier` implies a saturated
  top-level result neither reader acts on. The miss is conservative in the only direction that
  matters: it can WITHHOLD the AllocCheck exemption, never grant one. Documented rather than
  changed — `|| !barrier` buys no verdict and pays extra `code_typed_by_type` levels on exactly
  the saturated functions the stop exists for, and it would enlarge the surface of the one
  thing here that can go vacuously green. Pinned by a test that fails if the condition changes.

- [x] **`register_report`'s regression test drives the real parser.** Fixed. The parse was
  extracted to `_zmm_counts(::AbstractString)` in src/scheduling.jl (`register_report` had no
  string seam), and the test runs it over fixed AT&T and Intel assembly fixtures, asserting the
  whole `(used, total, spills)` tuple. Restoring the issue-#21 regression — `r"%zmm(\d+)\b"` —
  fails the Intel fixture. The live path is kept but made falsifiable: it branches on a plain
  `occursin("zmm", ...)` substring check independent of the regex under test, so it is
  non-vacuous on an AVX-512 host and non-flaky elsewhere.

- [x] **`@assert_memsafe` reported clean on three shapes it never checked.** Fixed. A store
  whose value equals the canary poison was missed on every run (deterministic, not a
  probabilistic collision) — the fill is now position-dependent, which also closes
  self-laundering, where a kernel copies its own canary bytes to a shifted offset. `f(A, A)`
  built two independent buffers, hiding aliasing-dependent overruns and breaking kernels that
  require the aliasing; positions holding the same array now share one buffer. Stores into
  `align` slack were invisible and reported offsets understated by the slack; the canary now
  covers the slack. `isolate=false` is gone: an in-process probe can only use the canary, and
  a load past the end disturbs no canary, so its clean verdict was indistinguishable from no
  overrun at all in exactly the motivating case. Arguments the harness cannot guard are named
  in `MemsafeReport.unguarded` rather than silently skipped.

- [x] **#21 — `register_report` always returned 0 registers.** Fixed in `df74181`. The regex
  required the AT&T `%zmm` sigil; `code_native` emits Intel syntax (bare `zmm0`) on this host, and
  which you get varies by platform and Julia version. `\bzmm(\d+)\b` matches both. Note
  `@assert_no_spill` thirty lines below already documented this exact trap — it reads LLVM's
  Spill/Reload comments precisely because they survive either syntax — and the advisory report had
  never caught up.

- [x] **#22 — `scalar_fp_loops` false negative AND false positive.** Fixed in `a4fe1ca`. The false
  negative: the check required an FP `phi` accumulator, but a load-compute-store scalar tail carries
  only its *index* through a phi. Removing that requirement alone reintroduces the false positive,
  because LLVM's own vectorizer remainder loop is structurally identical to a hand-written tail. The
  distinguishing signal is not local to the loop: it is whether the function ALSO contains a
  hand-vectorized loop (raw `<N x …>` ops without LLVM's `vector.ph`/`middle.block`/`scalar.ph`
  scaffolding). Verified against the optimized IR for both reproducers, all three directions.

- [x] **#25 — opaque `AssertionError` from a backend failure.** Guarded in `26294ec` via a typed
  `AnalysisError` naming the call, signature, likely cause and original error. **Leave the issue
  OPEN:** the filed reproducer did not reproduce on this stack — `Core.Compiler` absorbs a
  `@generated` generator's exception into an inference failure (return type widens to `Any`) rather
  than propagating it. What was fixed is a real, separate gap found by reading: `_assert_opt` was the
  only one of the three `_be_opt_result` call sites with no error handling at all.

- [x] **#23 — suite cannot run on Julia 1.13.** Already fixed on this branch by the ReTestItems →
  TestItemRunner migration (`274b678`); it is the same `Test.TESTSET_PRINT_ENABLE` ScopedValue break.

- [x] **Reconcile `SPLIT-PROPOSAL.md` with what shipped** — revision 7. §H.4 and §5 rewritten to
  describe auto-escalation rather than the shadowing macros that were never built, and a new §7
  records all ten divergences with the reason for each. The document is now a decision record, not
  a proposal.



- [ ] **MEASURED: the split's assumption about WHERE `@assert_*` lives is wrong, and it changes the
  size of the 0.4 disarm.** SPLIT-PROPOSAL §8–§11 reasons throughout as though `@assert_*` is a
  `src/` annotation — checked at the annotated module's own precompile, where the proof is
  unreachable by construction, so warning is the only sane behaviour. Surveyed across the eight
  consumer packages on this machine, the guarantees 0.4 moved to reporting break down as:

  | location | disarmed call sites |
  |---|---|
  | `test/` | **149** |
  | `benchmark/` | 55 |
  | `src/` | 21 |

  Two thirds sit in test suites, where gating is the entire point — and 5 of 6 of those test
  environments run `analysis = "full"` (or the 0.3 `:full` default) with 1–3 of
  AllocCheck/JET/TrimCheck/StrictModeTest as deps. So TODAY those `@assert_noalloc` calls ARE
  AllocCheck's all-paths proof and they throw; those `@assert_trim_compatible` calls ARE juliac's
  verifier and they throw. Under 0.4 all of them become the value-free scan and warn.

  Ecosystem totals: 229 call sites stop gating outright (`@assert_noalloc` 122,
  `@assert_trim_compatible` 91, `@assert_trim_safe` 8, `@assert_noboxing` 5,
  `@assert_no_scalar_loops` 3) and 85 more lose their noalloc component (`@kernel` 70, `@strict` 15).
  The single largest block is PureBLAS's 90 `@assert_trim_compatible`, which today run juliac's own
  verifier. (PureIPM is the one exception — its test env is already `analysis = "fast"` with no
  backend deps, which is consistent with #17 having been measured there.)

  §8's Cost section already named the hazard — "a rename would have been caught by the compiler,
  this will not be" — and accepted it on the assumption that the affected surface was small. It is
  not: it is ~314 sites, ~70% of all guarantee usage.

  *Options, needs a decision:*
  (a) migrate — mechanical `@assert_X` → `@test_X` in `test/` across six repos;
  (b) revisit the shadowing design rejected in §H.4 (StrictModeTest re-exports `@assert_*` as the
      proving macros) — this survey is new evidence that was not available when it was rejected;
  (c) make the disarm compiler-enforced: when `StrictModeTest` is loaded, the five reporting
      `@assert_*` macros ERROR naming their `@test_*` replacement, instead of quietly scanning.
      Buys back exactly the compiler enforcement §8 wished for, keeps macro-name-is-engine, and
      answers §10's open question 4 far more strongly than the load banner does.
