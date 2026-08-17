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

## Open — split follow-ups

- [ ] **Register `StrictModeTest`.** It is a subdirectory package; Registrator supports that
  via `subdir=`. Needs a decision on whether it stays a subdir or gets its own repo, and
  whether its version tracks StrictMode's in lockstep (currently both 0.4.0).

- [ ] **Reconcile `SPLIT-PROPOSAL.md` with what shipped.** It is at revision 6 and predates
  the implementation. Known drift: §H.4 specifies shadowing macros, which were dropped for
  auto-escalation; its anti-vacuous argument for shadowing does not hold (shadowing only
  errors when BOTH packages are imported, the harmless case). Under adversarial review.

- [ ] **Neither `Manifest.toml` in a consumer layout is exercised.** `test/standalone` proves
  StrictMode works with no backend, and `test/` proves the escalated path, but nothing tests
  a *consumer* shape: `StrictMode` in `Project.toml`, `StrictModeTest` in `test/Project.toml`,
  with `@strict_function` in `src/` firing at the consumer's own precompile. That is the
  layout the split exists to serve and it is currently only verified by hand.
