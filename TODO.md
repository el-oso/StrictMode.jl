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
  *Mitigated, not fixed:* the issue's own second suggestion is implemented — `_guarantee_gates`
  (report.jl) puts `:noalloc`/`:noboxing` in the reporting set, so a false positive warns instead
  of aborting a build, and the proof that gates is `StrictModeTest`'s `@test_noalloc`. The
  false-positive rate itself is unchanged, so `audit` output on a real consumer is still ~28% noise.

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
  *Still to verify on a real consumer:* that `checks_enabled = true` by default does not make
  PureBLAS/PureIPM unusable through sheer warning volume (#17's ~28%).

- [ ] **#19 / #20 — `@assert_trim_compatible` false FAILs.** Both live in
  `_be_trim_validate`, which moved to `StrictModeTest/src/StrictModeTest.jl` in 0.4.0; the
  issues still say `StrictModeTrimExt`, which no longer exists.
  #20 has a concrete, parse-free fix: `TrimVerificationErrors.errors` holds `warn::Bool =>
  desc` pairs, and juliac's own gate fails only on `warn == false`. Filter or relabel the
  warnings to match.
  #19 is the deeper one — the verifier is invoked without juliac's Base patches, so it
  checks a different program than juliac compiles. Surfaced on 1.13, which is now a CI
  matrix entry, so this will keep showing up.

- [ ] **#13, #14, #15, #16** — verify whether these are actually closed by the code that now
  exists (`trimsafe.jl`'s heuristic caveat, `register_alloc_barrier!`, `memsafe.jl`,
  `no_spill`/`mca.jl`) and close them if so. Not audited.


## Open — added by the 0.4.0 split itself

- [ ] **The registry leg of "checked twice" does not work.** `@strict_function` registers via a
  `register_strict!` Dict insert executed at the consumer's precompile; that cross-package mutation
  is discarded on cached pkgimage load, so `check_all()` in a consumer's test process sees an empty
  registry and reports green. `check_signatures`/`audit` are unaffected (they enumerate directly).
  SPLIT-PROPOSAL §H.3 identified this mechanism and it was never applied to `registry.jl`.
  *Done so far:* `check_all` now WARNS loudly on an empty registry and its docstring documents the
  same-process-only limitation, so the silent green is gone even though the false negative remains.
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

- [ ] **No test exercises the real consumer layout.** `test/standalone` proves StrictMode works with
  no backend and `test/` proves the escalated path, but nothing tests `StrictMode` in
  `Project.toml` + `StrictModeTest` in `test/Project.toml` + `@strict_function` in `src/` firing at
  the consumer's own precompile. That is the arrangement the split exists to serve.

- [ ] **Register `StrictModeTest`.** Subdirectory package; Registrator supports `subdir=`. Needs a
  decision on subdir-vs-own-repo and whether its version tracks StrictMode's (both 0.4.0 now).
  **Blocking for 0.4.0**: without it, a consumer upgrading to StrictMode 0.4 has no way to reach
  the proofs at all, since every gating entry point moved there.

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
  *Mitigated, not fixed:* `_guarantee_gates` puts `:no_scalar_loops` in the reporting set, so a false
  positive warns instead of aborting a build. The discriminator is still unsound — the fix is to find
  one SLP output cannot forge.

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

- [ ] **Negative fixtures do not assert they are still bad.** No test in either suite checks that an
  intentionally-allocating fixture still allocates before asserting the check flags it. Make one
  optimizable and every assertion around it stays green. This has already recurred once
  (`test/unroll_test.jl`). *Fix:* `@test @allocated(fixture(args...)) > 0` beside each such fixture
  in `test/once_barrier_test.jl`, `test/unroll_test.jl`, `StrictModeTest/test/divergence_test.jl`.

- [ ] **`_guarantee_gates`'s partition is untested.** `src/report.jl` holds a hand-typed tuple;
  appending one symbol converts a gate to a warning package-wide and no test observes it. Nothing
  asserts throw-vs-warn at the macro boundary. *Fix:* the new `test/findings_test.jl` item that
  enumerates `_GUARANTEES` for `_suggestion` is the template.

- [ ] **`assert_enabled()` has one caller in the tree** (`StrictModeTest/src/drivers.jl`). A
  StrictMode-only consumer running under `CI=1` with `checks_enabled = false` is fully green and
  nothing invokes the guard that exists to make that loud.

- [ ] **`@golden` passes while comparing nothing when the golden file is absent** (`src/golden.jl`).
  Record-and-pass is correct on first run, but a CI checkout without `test/golden/` (gitignored, or
  a `dir=` tmpdir) records every time and never compares. The only signal is an `@info`. `@golden`
  is also the one guarantee macro not routed through `_gate`.

- [ ] **`audit`'s advisory loops still swallow** (`src/audit.jl`): the `inline_suggest` /
  `static_ownership_suggest` `catch` drops the item without an `_errored_findings` record — a second
  copy of the swallow `_map_findings` was fixed for. Advisory-only (`:info`), so lower severity.

- [ ] **`_call_parts` evaluates the function-position expression twice** (`src/macros.jl`). `fe` is
  spliced into both the executed call and the analyzed `checkfn`, so `@assert_noalloc ws.kernel(x)`
  or `@test_noalloc make_f()(x)` runs the getfield/factory twice and can analyze a *different*
  callable than it ran. Pre-existing, not introduced by the split.

- [ ] **`types = (…)` drops keyword args from the proved signature** (`src/macros.jl`): the override
  takes the `checkfn = fe` branch, bypassing the `Core.kwcall` path, while the executed call still
  passes the keywords. The proof then covers a signature the call does not have.

- [ ] **Docs pages not updated for 0.4.** `tutorial.md`, `cookbook.md`, `index.md` and `concepts.md`
  were never touched by the split. Between them they call the deleted `check`, import AllocCheck/JET
  directly, say checks are "off by default", describe `@explain` as gathering JET + AllocCheck,
  promise `@strict_function` fails module load on allocation, and describe `@assert_trim_compatible`
  as escalating with TrimCheck. `README.md` links twice to `docs/rust_gaps`, a page absent from
  `docs/src/` and from `make.jl`. `src/StrictMode.jl`'s own top-level docstring still describes the
  deleted `:fast`/`:full` tiers.

- [ ] **Cross-package registry pollution is still unaddressed** (SPLIT-PROPOSAL §10 item 3). The
  registry key is `(f, types)` with no module, so `test_registered()` re-proves whatever a
  dependency's executed `@assert_*` calls inserted, under the consumer's gate.

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


- [ ] **No release notes for the 0.4 break.** SPLIT-PROPOSAL §8 flags the migration cost as
  *silent*: the `StrictMode` spellings are unchanged, so a consumer's `@assert_noalloc` compiles and
  runs exactly as before and merely stops gating. A rename would have been caught by the compiler;
  this will not be. The load banner is the in-process mechanism, but there is no CHANGELOG, no
  release note, and no migration table (`check` → `findings`/`test_signatures`, `check_all` →
  `test_registered`, `check_compiled` → `test_compiled`, `audit(...; exit_on_fail)` → `test_*`,
  `:suspect`/`nsuspect` → gone, `mode=`/`fail_mode` → gone, `divergence_report` → StrictModeTest).
  Registering 0.4.0 without one ships a silent behaviour change to every consumer.
