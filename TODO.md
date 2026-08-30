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

  The change immediately exposed a false-premise test: `once_barrier_test.jl` asserted a fixture
  "genuinely allocates on every call" that measures **0 bytes** — a #17 false positive living inside
  the suite and asserting itself as correct. The fixture now escapes its allocation, and the
  `@allocated(...) > 0` guard added alongside is what catches that class.

- [ ] **#18 — inert preferences / broken consumer precompile.** Both parts are addressed;
  what remains is confirming it on a real consumer.
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

- [ ] **#19 / #20 — `@assert_trim_compatible` false FAILs.** Both live in
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
  Shipped as `set_juliac_patches!`, defaulting OFF, for a process that does nothing but trim
  verification. TrimCheck's own `validate_function` runs `init_validation` on a Distributed worker
  for exactly this reason; the real fix is the same isolation, which needs the verification moved
  to a subprocess (the shape `@assert_memsafe` already uses).

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
