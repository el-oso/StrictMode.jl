# TODO

Small, tracked items. The tier-split design record is `SPLIT-PROPOSAL.md` in this directory.
GitHub issues are the source of truth for anything with a number; the notes here record what the
0.4.0 tier split changed about them, so nobody re-derives it.

## Open — code

- [ ] **`_suggestion` is missing entries for five guarantees.** `src/findings.jl:29`
  covers `:noboxing`, `:owned`, `:typestable`, `:noalloc`, `:inlined`, `:vectorized`,
  `:no_scalar_loops`, `:no_spill`, `:trimsafe` and returns `""` otherwise. So
  `:trim_compatible`, `:concurrency_safe`, `:no_threadid_state`, `:memsafe` and `:mca`
  findings ship with an empty `suggestion` field. That field is the documented
  machine-readable fix hint agents act on (see the `audit` docstring and the julia skill's
  "act on that field directly"), so an empty string is a silent hole in the agent path,
  not a cosmetic gap.
  *Fix:* add the five branches. Note `:coverage`, `:inline_suggestion` and
  `:static_ownership` deliberately build their suggestion inline at the construction site
  and never route through `_suggestion` — leave those alone.

- [ ] **`barrier` is excluded from the recursion short-circuit.** `src/effects.jl:350`
  guards the callee walk with `depth > 0 && (!alloc || !boxing || !dictlookup)`. Once all
  three of those are set, recursion stops — so a barrier reached only *below* an
  already-saturated signal set is never recorded, and `_alloc_signals(...).barrier` comes
  back `false`. Consequence is confined to `_checked_allocs` (`src/backend.jl:158`), whose
  exemption already requires `!sig.alloc && !sig.boxing`; in that state the short-circuit
  cannot have fired, so **no behaviour change is currently reachable**. It is a latent
  trap for any future consumer of `barrier` that does not also demand a clean signal set.
  *Fix:* add `|| !barrier` to the condition, or document the invariant at the field.
  Note `abscontainer` is omitted from the same condition for the same reason; an attempt to
  add it is what surfaced the `IdDict` over-flag recorded under #17 below.

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
  The issue's own second suggestion — report these as a distinct lower-confidence category
  rather than a failure — is the one still standing.

- [ ] **#18 — inert preferences / broken consumer precompile.** Half fixed by the split.
  Part 2 (enabling checks globally breaks PureBLAS's precompile) had two causes: the
  `:full` tier demanding AllocCheck/JET during the *consumer's own* precompile, which is
  now impossible since `StrictMode` has no backend at all; and a `:fast` false positive on
  `trmv!`, which is #17 and still open. So the environment no longer breaks, but a consumer
  with a #17-shaped kernel still gets a red precompile under `fail_mode = "error"`.
  Part 1 (a `[preferences.StrictMode]` block is inert unless StrictMode is a *direct* dep of
  that environment) is unchanged and still undocumented. Confirmed live on 2026-08-17:
  `StrictModeTest`'s own suite was silently vacuous for exactly this reason until it got a
  `test/Project.toml`. The recommended layout now puts StrictMode in `test/Project.toml`
  directly, which makes the block bind — but nothing warns when it does not.

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

- [ ] **`:suspect` is a new public status.** It appears in the JSON findings. Anything matching
  `status == "fail"` now silently skips fast-tier allocation findings. Documented in
  `docs/src/agents.md`; the four consumer `strictmode_audit.jl` scripts are OUT OF SCOPE for this
  repo but will need the same audit.

- [ ] **Register `StrictModeTest`.** Subdirectory package; Registrator supports `subdir=`. Needs a
  decision on subdir-vs-own-repo and whether its version tracks StrictMode's (both 0.4.0 now).

## Open — deferred from the whole-branch adversarial review

- [ ] **`scalar_fp_loops`'s "hand-vectorized" discriminator is unsound (issue #22 follow-up).**
  `a4fe1ca` distinguishes a hand-written scalar tail from LLVM's own `@simd` epilogue by asking
  whether the function ALSO contains raw `<N x …>` ops without the loop-vectorizer's
  `vector.ph`/`middle.block`/`scalar.ph` scaffolding. Demonstrated wrong: LLVM's **SLP vectorizer
  and unroller** emit `<N x …>` ops with none of those labels, so an ordinary
  `acc += z[i] * (a + 2.0im)` loop over `Vector{ComplexF64}` plus a separate `@simd` loop reads as
  "hand-vectorized" and its epilogue gets flagged — the exact thing the commit says must never
  fire. Complex arithmetic + `@simd` is a bread-and-butter shape for this package's own dogfood
  targets (FFT), and `:no_scalar_loops` fails at `:fail`, not `:suspect`.
  Not a regression (the shape false-positived before via the integer-phi branch), but the commit's
  soundness argument and its docstring's "e.g. explicit SIMD.jl code" are both wrong.
  *Fix:* find a discriminator SLP output cannot forge, or downgrade this guarantee to `:suspect`.

- [ ] **`register_report`'s regression test is self-referential.** `test/round5_test.jl` re-implements
  the register regex locally (`regs(s) = ...`) instead of driving `register_report`, and its
  live-path assertion is `r.vec_regs_used >= 0`, which is vacuously true. A future regression of the
  real regex would not be caught — the test tests a copy of the code, not the code.

- [ ] **Aliased arguments diverge between probe and real call in `@assert_memsafe`.** `f(A, A)`
  builds two INDEPENDENT guarded copies, so aliasing-dependent behaviour (in-place fast paths, or
  index values read from the aliased buffer) differs between the probe and the real call, and the
  verdict can be wrong in either direction. Undocumented; needs at least a scope sentence in
  `memsafe_report`'s docstring alongside the existing Linux/macOS and `Array`-only caveats.

## Done

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
