# Splitting StrictMode's two personas

**Status:** SHIPPED as of revision 7 — this is now a record of a decision, not a proposal. `tier-split-v0.4`, 17 commits, `Pkg.test()` green on 1.12.7 and 1.13.0-rc3. §H.4 and §5 below have been rewritten to match what was actually built; §7 lists every place the design changed during implementation and why. **Driver:** load-time enforcement never fired while coding, so checking only happened at test time.
switch has proven finicky. **Scope:** how to separate "help me while I code" from "gate my test
suite" without a global compile-time switch.

> Revision 3 adds Alternative H (split on the tier, delete Preferences entirely), now recommended;
> E and F are superseded by it. Revision 2 changes: the consumer inventory was wrong (5 packages, not 1); the §1 audit claimed a
> completeness it did not have; and the revision-1 recommendation (make the tier a lexical macro
> argument) was **withdrawn** — it would have silently downgraded every existing consumer gate. See
> §6 for the full list of corrections.

---

## 1. Audit — what is actually coupled to Preferences

Three constants are baked at precompile in `src/preferences.jl`:

| const | line | readers | resolves at |
|---|---|---|---|
| `CHECKS_ENABLED` | 15 | `_gate` (20 sites), `_auto_check_module` (`registry.jl:148`), `assert_enabled` (`preferences.jl:37`), `StrictModeAnalysisExt`'s precompile workload, `StrictModeReviseExt` | macro-expansion time |
| `FAIL_MODE` | 59 | `_fail` (`report.jl:30`); `_auto_check_module` (`registry.jl:149`, at consumer *module load*); default for `check`'s `fail=` (`check.jl:241`) | mixed — see below |
| `ANALYSIS_MODE` | 97 | `_noalloc_mode` (`static_checks.jl:29`), `_typestable_check_expr` (`typestability.jl:46`) | macro-expansion time |

Plus the *live* preference read `analysis_mode()` (line 85), used by `_trim_compatible_check`
(`trimsafe.jl:86`) at call time and as the `mode=` default in `check`/`findings`/`audit`/`check_all`/
`check_compiled`/`check_signatures`.

### 1.1 The core defect: one concept, four resolution times

"Which analysis tier?" is answered four incompatible ways depending on entry point:

1. **Macro-expansion time, baked const** — `@assert_noalloc`, `@assert_typestable`, `@strict`,
   `@kernel`.
2. **Call time, live preference** — `@assert_trim_compatible`.
3. **Call time, explicit keyword** — `check`, `findings`, `audit`, registry drivers.
4. **Hardcoded `:full`, ignoring both** — `@strict_function` (`strict_function.jl:53` calls
   `_require_backend()` unconditionally) and `@explain`. Documented at `preferences.jl:77-78`.

The package ships a warning for (1) and (3) disagreeing (`preferences.jl:87`) — the design admitting
the problem rather than fixing it. Note (4) matters for any proposal: `@strict_function` is the
headline precompile-gate feature and is *already* immune to every mode mechanism.

### 1.2 The analysis core is close to gate-free, but not pure

`_gate` appears at 20 sites — all reached only at macro-expansion time, though two are in plain
helpers (`_strict_expr` `macros.jl:152`, `_kernel_expr` `macros.jl:197`) and `_strict_expr` is
reused by `@verify_strict` (`contracts.jl:78`). `_fail` is called only from macro-side runners.
`check.jl`, `findings.jl`, `audit.jl`, `cache.jl`, `effects.jl` and `divergence.jl` reference
neither `CHECKS_ENABLED` nor `_gate`.

**But `findings` is not pure.** Its results additionally depend on ambient mutable state the first
revision of this audit missed: `_IGNORE_THROW` (`backend.jl:85`), `_IGNORE_BARRIER`
(`backend.jl:111`), the `_ALLOC_BARRIERS` registry, and whether the weak analysis extension is
loaded at all (`:full` throws via `_require_backend`). The honest statement is: **the analysis core
is explicitly parameterised over the tier, and implicitly parameterised over process-global
analysis policy.** Only the first of those is a Preferences problem.

*(Non-issue, checked: `_cache_key` (`cache.jl:20`) includes `_IGNORE_THROW[]` but not
`_IGNORE_BARRIER[]`. This is not reachable as a staleness bug — both `set_ignore_barrier!`
(`backend.jl:135`) and `register_alloc_barrier!` (`effects.jl:156`) call `clear_cache!()`. Worth a
comment, not a fix.)*

## 2. Symptoms in the real consumers

**StrictMode has five consumers, not one.** Runtime dependency: **PureBLAS**, **PureIPM**,
**PureSparse**, **LowObservables** (no detectable `src/` use — likely stale). Test-only:
**BlazingPorts**, **PureFFT**. Every migration cost below is therefore multiplied.

**(a) Two shipping packages defend against their dependency's global mode — with identical code.**
`PureBLAS/src/verify.jl:34` and `PureIPM/src/verify.jl:22` both open their precompile-time
verification block with:

```julia
if StrictMode.analysis_mode() === :fast || StrictMode.backend_available()
```

Mechanism (traced, not assumed): the test env bakes `analysis = "full"` →
`_noalloc_mode(nothing)` returns `:static` → `_assert_noalloc` calls `_require_backend()` during the
*consumer's own precompile*, where the weak extension cannot be loaded → precompile error. The guard
is a workaround for the tier leaking across a package boundary it should never cross. **That this
workaround was independently reinvented in two packages is the strongest single piece of evidence
in this document.**

**(b) StrictMode is a runtime dependency of shipping numerical libraries.** In `[deps]` for
PureBLAS, PureIPM, PureSparse — because `src/contracts.jl` uses `@strict_contract` and
`src/verify.jl` uses `@verify_strict`. Downstream users load StrictMode, and *their*
`LocalPreferences.toml` decides whether those packages' precompiles do verification work.

**(c) The vacuous-pass hazard is a standing tax.** `assert_enabled()` exists solely because a
checks-off run is byte-identical to a checks-pass run. Six repetitions of the
`if !StrictMode.checks_enabled() … @test_skip … end` block in `PureBLAS/test/strictmode_tests.jl`
alone, and the user's global `strictmode-stop.sh` hook has to refuse to stamp a vacuous audit green.
This is boilerplate created entirely by the gating mechanism.

### 2.1 What is *not* a symptom (corrected)

Revision 1 counted PureBLAS's ~19 `[preferences.PureBLAS]` pins in `test/Project.toml` as a cost of
the mode switch. **That was misattributed.** Their own comments state the mechanism: an
`@static if isnothing(pref)` branch keeps a `Base.OncePerProcess` tuner reachable, and AllocCheck's
*all-paths* proof counts its one-time init. That is a property of `:full` analysis semantics (which
issue #14's barrier machinery exists to relieve), not of how the tier was selected. Any alternative
that still runs `:full` keeps every pin. It is orthogonal and is dropped from the case.

### 2.2 Three consumer facts, verified

These were checked against the consumer trees, not assumed, and they change what a split costs.

1. **`@strict_function` has zero consumers.** It appears only in StrictMode's own
   `test/strict_function_test.jl`. The "module won't load if it violates" experience — cited twice
   in revision 2 as a blocker for removing in-`src/` annotation — is unadopted, and is the only
   reason `strict_function.jl` touches the analysis backend.
2. **In-`src/` annotations are already dev-only in disguise.** `PureBLAS/Project.toml` has no
   `[preferences.StrictMode]` block and there is no `LocalPreferences.toml`, so `CHECKS_ENABLED` is
   `false` for every downstream user and all 30 `src/` annotations across the three consumers are
   already stripped to bare calls. The production-strip machinery protects code that never runs in
   production.
3. **Consumers hand-duplicate their *assertions*, but they do use `audit`.** ~~Their test suites call **no** registry~~
   driver — zero uses of `check_all`, `check_compiled`, `check_signatures`, `audit` or
   `register_strict!`. Instead they restate ~145 assertion macros in `test/` mirroring what `src/`
   declares (PureBLAS alone: 84 `@assert_trim_compatible`, 25 `@assert_typestable`, 25
   `@assert_noalloc`, 6 `@verify_strict`).

> **Correction (revision 5).** Fact 3 above was stated as verified and is **false as written**. The
> grep behind it covered `test/` only. Four consumers ship `strictmode_audit.jl` scripts that call
> `audit(...)` — `PureIPM/benchmark/audit/`, `PureSparse/benchmark/audit/`, `BlazingPorts/bench/`,
> `PureFFT/bench/` — and `~/.claude/hooks/strictmode-stop.sh` searches exactly those paths and runs
> them on every stop. They are the primary gate in this workspace's workflow, not an obscure corner.
> What *is* true: no consumer calls `check_all`, `check_compiled`, `check_signatures` or
> `register_strict!` — i.e. the **`Dict` registry** is dormant, but `audit` is not. The "activates
> dormant machinery" framing in the H refinement was built on the false half and is withdrawn.

### 2.3 A third persona the document had not identified

`audit` scripts are neither the dev persona nor the test-gate persona. They run from `bench/` or
`benchmark/audit/`, are invoked by a Stop hook rather than by a human or by `Pkg.test()`, open with
`checks_enabled() || error(...)` and `backend_available() || error(...)` guards, and
`PureIPM`'s uses `@assert_noalloc static = false` in a plain script — a call-site macro in neither
`src/` nor `test/`. Any doctrine that partitions the world into "src declares, test asserts" has no
home for them.

## 3. The conceptual split

| | **Dev persona** | **Gate persona** |
|---|---|---|
| invocation | function call from REPL/daemon | annotation, or assertion in test code |
| tier | `:fast` heuristic | `:full` proof |
| on failure | returns findings | throws / red build |
| process | long-lived, Revise-tracked | fresh `Pkg.test()` subprocess |

**The decisive correction from review:** the tier is a property of the **context a check runs in**,
not of the **source text that declares it**. The same annotated line legitimately wants `:fast`
in a warm session and `:full` in CI. Any design that welds the tier to source text — including
revision 1's recommendation — breaks that and is wrong.

Two further constraints, both from review:

- **A manifest cannot replace all annotations.** `@golden`, `@assert_memsafe`, `@assert_mca` and
  empirical `static = false` checks need real argument values and warmed workspaces; PureBLAS's
  verify block is ~40 lines of carefully seeded probe state, not `(f, types)` pairs.
- **The personas may already be separated by process.** The dev path already has a
  preference-free entry point (`findings`/`audit`/`check` with the runtime `mode=` kwarg), and the
  existing `jl` daemon + `strictmode-stop.sh` workflow already runs dev warm-in-process and gates
  in a `Pkg.test` subprocess. This must be priced as a real alternative, not skipped.

---

## 4. Alternatives

### Alternative A — Two packages: `StrictCheck` (analysis) + `StrictMode` (annotations)

`StrictCheck` gets the analysis core and never throws; `StrictMode` keeps `preferences.jl`, the
macros, and the registry, and depends on it.

- **Pro** — a real, enforced boundary; the analysis library becomes usable without the macro layer.
- **Con** — **the file split is not clean.** `scheduling.jl`, `concurrency.jl`, `inlining.jl`,
  `memsafe.jl`, `mca.jl` and `trimsafe.jl` each contain *both* report functions and macros
  (`_gate` at `scheduling.jl:77,109,476,728`; `concurrency.jl:380,502`; `inlining.jl:71`;
  `memsafe.jl:393`; `mca.jl:350`). Seven files need bisecting, not moving.
- **Con** — breaking release for five consumers; two packages to register and keep compat-bounded.
- **Con** — does not by itself fix in-`src/` annotations, which is where §2(a) lives.

### Alternative B — One package, two lexical namespaces (`StrictMode.Dev` / `StrictMode.Gate`)

- **Pro** — tier visible at the call site; no environment can change what a line means.
- **Con** — welds the tier to source text, which §3 establishes is wrong.
- **Con** — **unresolved dilemma:** does `Gate.@assert_*` respect `checks_enabled`? If yes, a dev
  env with checks off silently skips and the boilerplate returns. If no, a `Gate.` annotation in
  shipped `src/` runs full analysis in production — reopening the exact hole the strip exists to
  close. B has no answer.
- **Con** — doubles the macro surface (20 → 40).

### Alternative C — Delete in-`src/` annotations; declarative manifest in `test/`

Doctrine: no StrictMode call ever appears in shipped `src/`; guarantees are declared via
`check_signatures` (`registry.jl:117`) from `test/`. Deletes most of `preferences.jl` and all 20
`_gate` wrappers.

- **Pro** — the §2 bug class becomes unrepresentable; largest deletion; no runtime dep downstream.
- **Con** — **cannot express the value-dependent guarantees** (see §3). Coverage would silently
  shrink for exactly the checks that need warmed state.
- **Con** — loses `@strict_function`'s "module won't load if it violates" experience, deliberately
  adopted by three consumers.
- **Con** — deleting `checks_enabled`/`assert_enabled` breaks the global `strictmode-stop.sh` hook
  and the committed `[preferences.StrictMode]` blocks in five test environments.

### Alternative D — ~~Lexical `mode=`/`fail=` at every call site~~ (WITHDRAWN)

Revision 1 recommended deleting `ANALYSIS_MODE`/`FAIL_MODE` and making the tier an explicit argument
on every macro. **Withdrawn on three counts:**

1. It welds a contextual property to source text (§3).
2. A literal `mode = :fast` default would **silently downgrade every existing gate**: consumer test
   envs bake `analysis = "full"` today, so every bare `@assert_noalloc`/`@assert_typestable` in five
   test suites drops from AllocCheck proof to heuristic unless individually edited — and a missed
   edit is byte-identical to a genuine full pass. That reproduces §2(c)'s vacuous-pass hazard at
   per-line granularity.
3. It keeps `CHECKS_ENABLED`, which carries the larger half of the reported pain.

### Alternative E — Per-consumer policy, resolved at macro-expansion time (REVIVED)

Revision 1 dismissed this because "a module's `__init__` runs after its macros have expanded." That
reasoning does not hold: Julia evaluates top level sequentially, every guarantee macro already
receives `__module__`, and a module-level `const` (or a `Preferences.@load_preference` in the
*consumer's own* package, which Preferences then tracks for *that* package's invalidation) defined
above the annotations has already been evaluated when later macros expand.

```julia
module PureBLAS
const STRICTMODE_POLICY = :fast          # or @load_preference, tracked against PureBLAS's UUID
...
@verify_strict SIMDBackend begin ... end  # macro reads isdefined(__module__, :STRICTMODE_POLICY)
end
```

- **Pro** — fixes §2(a) and §2(b) directly and minimally: a package's own `src/` annotations are
  governed by *that package's* declaration, never by the ambient environment. Both `verify.jl`
  guards delete, with one line added per consumer and **zero call-site churn**.
- **Pro** — preserves zero production cost (still expansion-time).
- **Con** — still expansion-time, so it cannot serve the same annotation at two tiers; needs E to be
  paired with something for the dev/gate tier split.
- **Con** — the untracked `Preferences.load_preference` function form would not invalidate the
  consumer's cache; the consumer must use the tracked `@load_preference` or a plain const.

### Alternative F — Tier becomes a runtime scoped value; only on/off stays a Preference (NEW)

The observation revision 1 missed: **baking the tier at expansion time buys nothing.** The checked
branch already runs `Base.return_types`, AllocCheck or JET; an extra runtime branch selecting the
tier is free relative to that, and in a disabled build the whole branch is stripped by `_gate`
anyway. So the tier never needed to be a compile-time constant.

Make it a `ScopedValue` (`Base.ScopedValues` exports `ScopedValue`/`with`/`@with`; verified present in the installed Julia 1.12 base, so no new dependency):

```julia
StrictMode.with_tier(:full) do
    include("test/strictmode_tests.jl")     # gate persona
end
findings(kernel!, types; mode = :fast)       # dev persona, unchanged
```

`ANALYSIS_MODE` and the `analysis` preference are deleted; `analysis_mode()` becomes a read of the
scoped value with a `:fast` default. `_noalloc_mode`/`_typestable_check_expr` emit *both* paths and
branch at call time. `CHECKS_ENABLED` survives unchanged as the production strip — the one job a
compile-time preference is genuinely right for.

- **Pro** — the tier becomes contextual, which §3 shows is what it actually is. Same source, both
  personas, **no restart** — which is the specific thing the warm-daemon workflow needs.
- **Pro** — deletes the (1)-vs-(3) disagreement warning (`preferences.jl:87`) by making it
  unrepresentable, and collapses resolution paths (1), (2), (3) into one.
- **Pro** — no call-site churn, no doubled macro surface, no package split, no silent downgrade:
  CI wraps the suite in `with_tier(:full)` once.
- **Con** — does **not** fix §2(a)/(b) on its own: an ambient scoped value still leaks into a
  consumer's precompile. Needs E alongside it.
- **Con** — resolution path (4) survives: `@strict_function`/`@explain` stay hardcoded `:full`.
  Either bring them under the scoped value or document the exception loudly.
- **Con** — slightly larger expansion (both branches emitted) in enabled builds only.

### Alternative G — Do nothing structural; fix the workflow and the docs

The dev persona already has a complete preference-free path (`findings`/`audit`/`check` with runtime
`mode=`), and the existing `jl` daemon + `strictmode-stop.sh` split already separates the personas
*by process*. Under this option: document that in-`src/` annotations are an advanced feature, move
consumers' `verify.jl` performance halves to `test/`, and change nothing in StrictMode.

- **Pro** — zero risk, zero migration, and it may be sufficient: the reported finickiness has not
  been inventoried into specific incidents beyond §2(a).
- **Con** — leaves §2(a)'s duplicated guard and §2(c)'s boilerplate in place, and leaves four
  resolution paths for one concept.

---

### Alternative H — Two packages split on the TIER; no Preferences at all (RECOMMENDED)

Re-cut A's package boundary along `:fast` / `:full` instead of analysis / macros, and delete
`Preferences` from the design entirely. **The tier becomes the dependency graph.**

- **`StrictMode`** (light, may be a runtime dep) — the `:fast` engine, the six mode-independent
  guarantees, every report function (`kernel_report`, `spill_report`, `register_report`,
  `memsafe_report`, `pool_balance_report`), `@strict_contract`, `@golden`, `@unroll`/`staticval`,
  and `findings`/`check`/`audit` in fast mode. Deps: `TypeContracts`, `InteractiveUtils`.
  **No `Preferences`, no `_gate`, no `checks_enabled`, no analysis weakdeps.**
- **`StrictModeTest`** (test-only, always) — hard-depends `AllocCheck` + `JET` (+ `TrimCheck`,
  `LLVM_full_jll` optional). Supplies the `_be_*` methods, `@explain`, `@strict_function`, and the
  full-tier `@assert_*` forms. Lives in `test/Project.toml` and nowhere else.
- **Doctrine:** call-site assertion macros live in `test/`. Shipped `src/` declares
  (`@strict_contract`, `register_strict!`) and never analyses.

Why the boundary is clean here where A's was not: only **4 of 10** guarantees are mode-dependent
(`:typestable`, `:noalloc`, `:noboxing`, `:trim_compatible`); the rest route through
`_mode_independent_finding` (`check.jl:48`) and are identical in both modes. The entire seam is six
call sites — `_require_backend()` at `check.jl:20`, `typestability.jl:36`, `static_checks.jl:35`,
`static_checks.jl:151`, `strict_function.jl:53`, and `_require_mca()` at `mca.jl:229`. So
`scheduling.jl`, `concurrency.jl`, `inlining.jl`, `static_ownership.jl`, `memsafe.jl`, `idioms.jl`
and `golden.jl` move wholesale to the light package with no bisecting.

**Three consumer facts that make this cheaper than it looks** (verified, §2.2 below):
`@strict_function` has zero consumers; in-`src/` annotations are already stripped for every
downstream user; and the consumers already hand-duplicate their guarantees between `src/` and
`test/`.

- **Pro** — the tier is unforgeable. You cannot be in `:full` without having loaded the package that
  defines `:full`. §2(a)'s guard becomes unrepresentable: nothing can implicitly demand a backend
  during a consumer's precompile.
- **Pro** — §2(b) resolved for the heavy half: `AllocCheck`/`JET` never reach a downstream user.
- **Pro** — **kills the vacuous-pass hazard outright**, which no other option does. The light
  package always checks (nothing silently skipped) and `mode = :full` without `StrictModeTest`
  errors loudly (nothing silently downgraded). `assert_enabled()` and the six `@test_skip` blocks
  delete.
- **Pro** — subsumes E and F by making both unnecessary: no preference means no leakage (E's
  problem), and no tier switch means nothing to scope (F's problem).
- **Con** — **`src/` loses call-site macros.** A macro expands during the *consumer's* precompile,
  where only the light package exists, so a `src/` annotation is permanently `:fast`. Combined with
  "no Preferences", always-on analysis makes keeping them untenable anyway: PureBLAS's
  `src/verify.jl` warms eight L3 kernels over 64×64 matrices and then runs 60+ `@strict` calls —
  not something to run in every downstream precompile.
- **Con** — **largest migration of any option.** 14 `@verify_strict`, 11 `@strict` and 5 `@assert_*`
  across three consumer `src/` trees move to `test/`, carrying ~40 lines of warmed probe state each;
  five test environments drop their `[preferences.StrictMode]` blocks; two packages to register and
  keep compat-bounded.
- **Con** — the `_be_*` seam does not vanish, it only stops being *implicitly* demanded.
  `findings(...; mode = :full)` without `StrictModeTest` must still error. That is the win, not a
  gap — but the seam's code stays.
- **Con** — `@strict_contract` remaining in `src/` keeps the light package as a runtime dep of three
  libraries. Only the heavy half becomes test-only.
- **Open** — `@assert_noboxing` is currently `:full`-only by design (`static_checks.jl:151` calls
  `_require_backend()` unconditionally, and its docstring says it ignores `:fast`) even though
  `_findings_fast` has a working `:noboxing` branch. The split forces this inconsistency to be
  resolved either way.

**Refinement — activate the registry instead of duplicating.** The blunt form of H tells consumers
to restate their `src/` guarantees as assertions in `test/`, which is what they already do by hand —
but that leaves `src/`-declared guarantees covered only by the `:fast` heuristic, whose known
under-reports would then ship unchallenged. Better: `src/` *declares* with zero analysis
(`register_strict!`, already at `registry.jl:14`), and `StrictModeTest`'s `check_all()`
(`registry.jl:95`) proves everything registered from `test/`. That gives full-tier coverage of
`src/`-declared guarantees with zero `src/` cost and no duplication. Both functions already exist
and **no consumer currently calls either** — this activates dormant machinery rather than building
any.

### H.1 — Two constraints on the registry, and the conflict between them

Requirement: **the registry must be `--trim`-compatible, and a no-op when Revise is not loaded.**
Both are live, not hypothetical — PureBLAS ships a juliac build (`juliac/build.jl`, `entry.jl`,
`ctest.c`).

**The registry as it stands is trim-hostile.** `STRICT_REGISTRY` (`registry.jl:5`) is a
`Dict{Any, @NamedTuple{guarantees::Any}}` — an `Any`-keyed mutable global — populated by
`register_strict!` calls executed as load-time side effects. `--trim` retains load-time roots and
cannot resolve `Any`-typed container traffic; this is exactly the shape the package's own
`:trim_compatible` guarantee flags.

**The two constraints collide head-on with fix 2 as first stated.** Verified: **no consumer test
environment loads Revise** — PureBLAS, PureIPM, PureSparse, BlazingPorts and PureFFT all lack it;
only StrictMode's own test env has it. So "registration is a no-op without Revise" would make
`check_all()` see an empty registry in all five consumer test suites — a green run proving nothing.
That is the vacuous-pass hazard H was specifically meant to abolish, reintroduced through the back
door.

**Resolution: make declaration a method definition, not a dictionary insert.**

```julia
# emitted in src/ by the declaration macro — compile-time, no load-time side effect
_strict_declared(::typeof(axpy!), ::Type{Tuple{Vector{Float64}, Float64, Vector{Float64}}}) =
    (:typestable, :noalloc)
```

This satisfies both constraints without sacrificing fix 2:

- **Trim-compatible** — a method definition is compile-time, not a load-time root. Nothing mutable,
  no `Any` container, no `__init__`. If `_strict_declared` is never called from a ccallable root,
  `--trim` has nothing to retain. *(Needs verification against a real `juliac --trim=safe` build
  before this is relied on — assert nothing here; `@assert_trim_compatible` plus TrimCheck is the
  instrument.)*
- **Zero load cost** — there is no runtime registration to no-op, so the "no-op without Revise"
  requirement is satisfied by construction rather than by a guard.
- **Still discoverable from `test/`** — `StrictModeTest` enumerates `methods(_strict_declared)` and
  reads each `m.sig`. Reflection is trim-hostile only if *called* from shipped code; this is called
  only from `test/`, never from `src/`.

**`STRICT_REGISTRY` then becomes exactly what the Revise constraint describes:** a mutable
dev-session cache for the live watch loop, populated by scanning the marker methods, absent
otherwise. Its current seven consumers (`audit.jl:69`, `registry.jl:101,128,323`,
`registered_strict`) read from the scan instead.

**Residual risk to price:** this replaces a one-line `Dict` insert with a generated method per
declared signature. A library declaring hundreds of signatures adds hundreds of methods to one
generic function — cheap to define, but it enlarges that function's method table and every
`methods()` scan. Worth measuring on PureBLAS's ~30 declarations before committing; harmless at that
scale, unknown at 500.

### H.2 — Two blockers against "no Preferences at all", and the narrowing that survives them

**Blocker 1 — PureSparse uses `checks_enabled` as a runtime-validation switch, not a tier switch.**
`PureSparse/src/strict.jl` contains **zero StrictMode macros**. It uses StrictMode as a
pre/postcondition framework in shipped code: `StrictMode.checks_enabled() || return nothing` as the
const-folding gate on `check_refactor_shape`/`check_refactor_nnz`/`check_finite`,
`StrictMode.fail_mode()` to pick warn-vs-error, and `StrictMode.StrictViolation` as the exception
type (12 references, wired into all three `*!` refactor entry points). This is runtime input
validation whose zero-cost-off state is exactly the const-folding property "delete Preferences"
removes. It **cannot** move to `test/`. §5's original item 5 would have forced PureSparse to grow
its own `Preferences` dependency re-implementing what was deleted — "Preferences leaves the design"
achieved by exporting it to a consumer.

**Blocker 2 — four `audit` scripts and the Stop hook depend on `checks_enabled`.** See §2.2's
correction and §2.3. Every one of those scripts opens with a `checks_enabled()` guard, and the hook
refuses to stamp a vacuous audit green by reading exactly that signal.

**The narrowing that survives both: delete only the `analysis` preference.**

H's real insight is that *the tier* should be the dependency graph. That insight does not require
deleting the *on/off* axis, which is a different concept serving different consumers:

| axis | mechanism under narrowed H | why |
|---|---|---|
| tier (`:fast` / `:full`) | **the package split** — `StrictMode` vs `StrictModeTest` | unforgeable; kills §1.1 and §2(a) |
| on/off (production strip) | **stays a `Preference`** (`checks_enabled`) | a compile-time strip is what Preferences are actually for; PureSparse and four audit scripts depend on it |
| failure mode | **stays** (`fail_mode`) | PureSparse's validation layer selects warn-vs-error through it |

With that narrowing, both blockers dissolve, `_gate` survives (so §M4's always-on `@assert_memsafe`
subprocess-per-call and `@assert_mca` foot-guns never appear), and `StrictModeReviseExt` keeps its
predicate.

**Still required either way — the macro partition.** H's headline "kills the vacuous-pass hazard"
is unproven until this is decided. If the light package exports fast-tier `@assert_noalloc` /
`@assert_typestable` / `@strict`, then a test file with `using StrictMode` and a forgotten
`using StrictModeTest` runs every assertion at the heuristic and passes green — Alternative D's
silent downgrade, re-selected by an import line instead of a preference. **The mode-dependent
macros must live only in `StrictModeTest`**, so a missing import is an `UndefVarError`. That leaves
the two packages exporting overlapping surfaces (light owns `@strict_contract` and the
mode-independent `@assert_vectorized`/`@assert_no_spill`; test owns `@verify_strict`,
`@assert_noalloc`, `@assert_typestable`, `@assert_noboxing`, `@explain`), so test files need both
plus a re-export facade or qualification policy. Unspecified in revision 4; must be pinned down.

**Also unresolved, carried forward:**

- `divergence.jl:97` calls `_be_is_boxing` unguarded — a `MethodError`, not a clean error, without
  the backend. It can only live test-side; no move list mentions it.
- `mca.jl` is in no move list, and parking `LLVM_full_jll` in `StrictModeTest` forces a dev session
  wanting an informational `mca_report` to load AllocCheck + JET. Keeping it a weakdep of the light
  package contradicts light's "no analysis weakdeps" line.
- The light package's real dep list includes `Serialization` (memsafe `isolate = true`) and
  `PrecompileTools`, not just `TypeContracts` + `InteractiveUtils`.
- Cross-package private-API reuse (`StrictModeTest` needs `_callinfo`/`_call_parts`/`_macro_call`/
  `_assert_noalloc`) means `= x.y.z` pinning and paired releases, not ordinary compat bounds.

### H.3 — A stronger argument against the `Dict` registry than §H.1 gives

§H.1 rejects `register_strict!`-at-`src/`-top-level on trim grounds. There is a more decisive
reason: a consumer's `src/` calling `register_strict!` mutates **StrictMode's** global during the
consumer's precompile, and cross-package state mutations are **discarded when the pkgimage is
cached**. The registry would be empty on cached load regardless of trim or Revise — only an
`__init__` (a load-time root, itself trim-hostile) would repopulate it. The `Dict` was never viable
for `src/`-side declaration; trim is the second reason, not the first.

**And the simpler mechanism was already in the document.** `check_signatures` (`registry.jl:117`,
cited under Alternative C) already expresses "prove this list of `(f, types)` at full tier" from
`test/`, with nothing in shipped code — trivially trim-compatible and Revise-independent. Marker
methods buy exactly one thing over it: declaration sits next to definition, so it drifts less. The
price is a new macro, a `methods()` + `m.sig` unpacking layer, method-table growth, and a trim
property that cannot be verified without building. Marker methods are also still just `(f, types)`
pairs, so C's value-dependent-guarantee objection applies to them *identically* — PureIPM's
warmed-workspace and `static = false` guarantees go to `test/` either way.

`m.sig` recovery, examined: works for singleton functions; **breaks for non-singleton callables**
(closures/functors have no `typeof(f).instance` — a capability regression versus the `Dict`, though
no current consumer declares one); `where` clauses make `m.sig` a `UnionAll` needing
`Base.unwrap_unionall` and yield non-`isdispatchtuple` signatures that the enumeration must filter
exactly as `register_strict!` already does (`registry.jl:21`); kwargs are at parity (neither form
registers them). Duplicate declarations become precompile method-overwrite warnings instead of
silent overwrites — cosmetic.

### H.4 — Decision: `:fast` is the only tier in `StrictMode`; `:full` lives in `StrictModeTest`

Owner decision, and the shape that shipped. The tier stops being a setting and becomes the
dependency graph. **The mechanism is not what this section originally specified — see §7.**

**Tier selection is AUTO-ESCALATION, decided at call time.** `StrictModeTest` defines no macros and
exports nothing (`names(StrictModeTest) == [:StrictModeTest]`). It fills StrictMode's `_be_*` seam
and flips `backend_available()` in `__init__`; each guarantee reads that flag when it *runs*, so one
already-compiled call site executes the heuristic in a package's own environment and the proof under
test, with nothing recompiled. The correct spelling in a test file is `using StrictMode,
StrictModeTest` — both, and importing both is legal and expected.

| item | before | after |
| --- | --- | --- |
| `ANALYSIS_MODE`, `analysis_mode()`, `set_analysis_mode!`, the disagreement `@warn` | preference + live getter + reconciliation | deleted (zero references remain in src, tests or docs) |
| AllocCheck, JET, TrimCheck | `[weakdeps]` behind two extensions | `[deps]` of `StrictModeTest`; `ext/StrictModeAnalysisExt.jl` and `ext/StrictModeTrimExt.jl` deleted |
| the `_be_*` seam | indirection through a weak extension | **retained** in `src/backend.jl`; StrictModeTest fills the stubs unconditionally |
| `_require_backend()` / `backend_available()` | 7 call sites | **retained** — `backend_available()` IS the escalation mechanism now |
| `_require_backend`'s failure | bare `error()` | typed `BackendUnavailable`, so sweeps can distinguish "this whole run cannot be analyzed" from "this one method could not be" |
| `@explain`, `divergence_report` | in StrictMode | **stayed** in StrictMode; they throw `BackendUnavailable` without the backend |
| `LLVM_full_jll` / `@assert_mca` | weakdep of StrictMode | **stayed** a weakdep of StrictMode (see §7 item 6) |
| `Cthulhu`, `Revise`, `CpuId` | weak in StrictMode | unchanged — session tools, not tier backends |

**Load-time checks can never escalate.** `@strict_function` and `@strict module` run at the
annotated module's own precompile, where `StrictModeTest` is a test-environment dependency and
therefore not loadable by construction. That is by design — it is the whole point of the driver, a
dev-loop guard that needs no AllocCheck in the main environment — and the suite re-checks the same
signatures at `:full` from test code via `check_signatures`/`audit`, which run at runtime.

**A heuristic verdict must not decide a build.** The `:fast` engine reads typed IR and cannot see
allocations LLVM later elides (~28% false on a real consumer, issue #17). Its `:noalloc`/`:noboxing`
findings therefore carry `status = :suspect`: rendered `?`, counted by `nsuspect`, and — the part
that matters — `@strict_function` WARNS rather than aborting a consumer's precompile. `:suspect`
still counts toward `nfailures`, so sweeps continue to gate; a non-failing `:suspect` was prototyped
and rejected, because a sweep reporting green while sitting on a real allocation regression is the
vacuous-green shape this whole exercise exists to remove.

## 5. What shipped

Alternative H, split on the tier. Delivered on `tier-split-v0.4`.

1. **The `analysis` axis is gone** — `ANALYSIS_MODE`, `analysis_mode()`, `set_analysis_mode!` and
   the stale-image `@warn`. Zero references remain anywhere. §1.1's four-resolution-times defect
   went with it.
2. **`StrictModeTest` holds AllocCheck/JET/TrimCheck as hard `[deps]`** and fills the `_be_*` stubs
   directly. Both backend extensions are deleted; StrictMode has no analysis backend at all, not
   even a weak one.
3. **`@strict_function` no longer requires a backend**, which was the stated driver. It verifies at
   the consumer's own precompile on the heuristic, warning rather than throwing.
4. **Tier selection is auto-escalation, not shadowing macros** — see §7 item 1 for why the design
   changed.
5. **`checks_enabled` and `fail_mode` remain Preferences.** A compile-time production strip is the
   one job a `Preference` is genuinely right for.
6. **`assert_enabled()` gained the loudness the split gave up.** Merging intent and capability
   removed the mismatch `_require_backend` used to shout about, except where a package is *listed*
   as a dependency and never `using`ed — then everything silently runs on the heuristic while the
   environment advertises the proof. It now errors there, reading the active project file (not
   `Base.identify_package`, which searches the whole LOAD_PATH).
7. **Three environments, each proving something the others cannot.** `test/` proves the escalated
   path; `StrictModeTest/test/` proves the seam implementations, which StrictMode cannot test
   because there the `_be_*` functions are undefined stubs; `test/standalone/` proves StrictMode
   works with no backend at all, run under an isolated `JULIA_LOAD_PATH` so the check is of the
   repo rather than the developer's global depot.

### Still open

- **Issue #17.** The split makes `:fast` the only engine ordinary consumers get, and it is weaker
  than AllocCheck in every direction measured. `:suspect` contains the damage; it does not fix it.
- **The registry leg of "checked twice" is unimplemented.** §H.4 claims a declaration is checked at
  the heuristic in `src/` and again at `:full` from `test/`. The second half works via
  `check_signatures`/`audit`, but NOT via `check_all`: `@strict_function` registers through a
  `register_strict!` Dict insert executed at the consumer's precompile, and that cross-package
  mutation is discarded on cached pkgimage load — §H.3's own mechanism. Neither §H.1's marker
  methods nor §H.3's demotion of `STRICT_REGISTRY` was built.
- **No test exercises the actual consumer layout** — `StrictMode` in `Project.toml`,
  `StrictModeTest` in `test/Project.toml`, `@strict_function` in `src/` firing at the consumer's own
  precompile. That is the arrangement the split exists to serve, and it is verified only by hand.
- **`StrictModeTest` is unregistered**, and whether it stays a subdirectory package is undecided.

## 6. Corrections applied in revisions 2–3

| # | Revision 1 claimed | Actually |
|---|---|---|
| 1 | "the one real consumer (PureBLAS)" | five consumers; PureIPM carries the identical `verify.jl` guard |
| 2 | `FAIL_MODE` read by `_fail` "and nothing else" | also `registry.jl:149` (module-load time) and `check.jl:241` |
| 3 | "three resolution times" | four — `@strict_function`/`@explain` hardcode `:full` |
| 4 | "`_gate` in exactly 19 places, all macro bodies" | 20 sites; two in helpers, one reused by `@verify_strict` |
| 5 | analysis core "already pure" | explicitly parameterised over tier, implicitly over `_IGNORE_THROW`/`_IGNORE_BARRIER`/barrier registry/backend presence |
| 6 | PureBLAS's ~19 preference pins are a symptom | misattributed — a property of AllocCheck all-paths semantics; orthogonal, dropped |
| 7 | recommend D (lexical `mode=`) | withdrawn — welds a contextual property to source text and silently downgrades five test suites |
| 8 | E dismissed as impossible | dismissal unsound; E revived and now part of the recommendation |
| 9 | (not considered) | F (scoped value) and G (process separation / do nothing) added |

*One review finding was itself refuted:* the claim that omitting `_IGNORE_BARRIER[]` from
`_cache_key` is a latent staleness bug. Both mutators call `clear_cache!()`, so it is unreachable
through the public API. Recorded in §1.2 as a comment-worthy asymmetry, not a defect.

### Revision 3

| # | Change |
|---|---|
| 10 | Added Alternative **H** — split the packages on the `:fast`/`:full` tier and remove `Preferences` from the design entirely. Now the recommendation. |
| 11 | **E and F superseded.** Both were mechanisms for making a preference behave correctly; H deletes the preference, so neither has a job. |
| 12 | **A superseded by H** — same package-split cost, but cut along the tier (4 of 10 guarantees, 6 seam call sites) instead of analysis-vs-macros (7 files needing bisection). |
| 13 | C's fatal objection does not apply to H: moving *macros* to `test/` keeps warmed probe state available, unlike reducing them to a `(f, types)` manifest. |
| 14 | Added §2.2 — three verified consumer facts (`@strict_function` unused; `src/` annotations already stripped downstream; consumers already duplicate by hand) that make the split cheaper than revision 2 assumed. |

### Revision 4

| # | Change |
|---|---|
| 15 | Renamed `StrictModeFull` → **`StrictModeTest`**. |
| 16 | Added §H.1 — the registry must be `--trim`-compatible and a no-op without Revise. Verified conflict: **no consumer test env loads Revise**, so a Revise-gated registry would make `check_all()` vacuous in all five. |
| 17 | Fix 2 restated: declaration becomes a **marker method definition**, not a `Dict` insert — compile-time, trim-droppable, zero load cost, still enumerable from `test/`. `STRICT_REGISTRY` demotes to a Revise-only dev cache. |
| 18 | Flagged for verification: that `--trim=safe` actually drops an uncalled `_strict_declared` generic (asserted nowhere; TrimCheck is the instrument), and the method-table cost at scale. |

### Revision 5

| # | Change |
|---|---|
| 19 | **§2.2 fact 3 was false and is corrected.** Four consumers call `audit()` from `bench/`/`benchmark/audit/`, run by the Stop hook. The grep behind the claim covered `test/` only. The "dormant machinery" framing is withdrawn. |
| 20 | Added §2.3 — the `audit`-script persona, which neither "src declares" nor "test asserts" accommodates. |
| 21 | Added §H.2 — two blockers against "no Preferences at all": PureSparse's shipped runtime-validation layer (zero macros, uses `checks_enabled`/`fail_mode`/`StrictViolation`), and the four audit scripts. **H narrowed: only the `analysis` preference goes.** |
| 22 | §H.2 also pins the required macro partition: mode-dependent macros must live only in `StrictModeTest`, or H's anti-vacuous claim fails exactly as D did. |
| 23 | Added §H.3 — the decisive argument against the `Dict` registry is pkgimage caching, not trim; and `check_signatures` already does the job marker methods were invented for. `m.sig` limits documented. |
| 24 | Consumer counts corrected: 46 `src/` annotations across three consumers (30 is PureBLAS alone), 8 `@assert_*` not 5. Seam is 6 `_require_*` sites plus 3 direct `_be_*` calls. |
| 25 | **F restored as the cheaper path** and explicitly flagged: by §5's own test, narrowed H is not yet justified while the incident inventory is unwritten. |

### Revision 6

| # | Change |
|---|---|
| 26 | **Owner decision recorded (§H.4):** `:fast` is the only tier in `StrictMode`; `:full` is mandatory in `StrictModeTest`. AllocCheck/JET/TrimCheck become hard deps of the test package; the `_be_*` extension seam and all 7 `_require_backend()`/`backend_available()` sites are deleted. |
| 27 | **Revision 5's required macro partition (item 22) is reversed.** Tier-dependent macros live in *both* packages with `StrictModeTest` shadowing — `@strict_function` must exist at the fast tier in `StrictMode` or the driver is unfixed. |
| 28 | **The anti-vacuous property is now verified, not argued.** Two modules exporting one macro name produce an `UndefVarError` at macro expansion, not a silent resolution. This is what D lacked. |
| 29 | **§H.2 Blocker 1 waived by the owner** — PureSparse is early-phase and acceptable to break. Blocker 2 downgrades from blocker to migration cost: vacuity becomes unreachable, so the anti-vacuous guards in four audit scripts and the Stop hook become unnecessary rather than broken. |
| 30 | **The driver is restated and is not the one revisions 1–5 worked from.** Not "the mode switch is finicky" in the abstract: load-time enforcement never fires while coding, because `strict_function.jl:53` calls `_require_backend()` unconditionally and so demands AllocCheck+JET in the consumer's *main* env. Verified that the fast tier can carry it — `effects.jl` and `_findings_fast` contain zero `_be_*` references. |
| 31 | **F is no longer the cheaper path for the actual driver.** A scoped-value tier does not remove `_require_backend()` from `@strict_function`'s load-time path. The genuinely cheap probe is that one line plus a cost measurement, which §5 now recommends sequencing before the split. |

## 7. Where the implementation diverged from this document (revision 7)

Found by adversarial review of the branch against the document. Each row is a place the shipped code
does something this document said it would not, with the reason. The document has been rewritten
above; this table is the record of *why*, so the reasoning is not lost.

| # | Document said | Shipped | Why |
|---|---|---|---|
| 1 | **Shadowing macros**: `StrictModeTest` defines its own `@assert_noalloc` etc., so `using StrictMode, StrictModeTest` is an `UndefVarError`. | **Auto-escalation**: no macros in StrictModeTest; each guarantee reads `backend_available()` at call time. Importing both is legal and expected. | The anti-vacuous argument for shadowing does not hold. It errors only when BOTH packages are imported — the *harmless* case. The dangerous case is StrictModeTest present in the environment but a test file importing only StrictMode, and shadowing keeps the heuristic there silently, exactly as auto-escalation would. Auto-escalation additionally upgrades every call site in every file once the package loads anywhere in the process, and needs no duplicate macro surface. |
| 2 | `StrictModeTest` re-exports StrictMode's surface; write `using StrictModeTest` alone. | It exports nothing. `using StrictModeTest` alone gives you no API. | Follows from (1). Its own module docstring claimed otherwise for several commits and has been corrected. |
| 3 | `_require_backend()`/`backend_available()` — all deleted. | Retained; `backend_available()` **is** the escalation mechanism. | Follows from (1). |
| 4 | The `_be_*` seam collapses into direct calls. | The seam survives unchanged; StrictModeTest fills the stubs as the extension did, just unconditionally. | Deleting it would have meant relocating the `:full` bodies out of six files. No benefit: the seam is what lets `test/standalone` prove StrictMode has no backend path. |
| 5 | `@explain` moves to StrictModeTest. | Stayed in StrictMode; throws `BackendUnavailable` without a backend. | It is a diagnostic a developer reaches for mid-session, not a test gate. Moving it would have put a dev tool behind a test-only dependency. |
| 6 | `LLVM_full_jll` should be a weakdep **of StrictModeTest**. | Weakdep of **StrictMode**. | The document contradicted itself: §H.2's own open item argued that parking mca in StrictModeTest forces AllocCheck+JET on anyone wanting an informational throughput report. `@assert_mca` is advisory and never fails without an explicit bound; it is a session tool, like Cthulhu. |
| 7 | "Vacuity stops being reachable"; consumers can delete their `backend_available() \|\| error(...)` guards. | **False when written, and fixed since.** `_map_findings` swallowed the missing-backend error per item, so `audit(...; mode=:full)` with no backend returned 0 findings, 0 failures, exit 0 — while the same sweep reported 53 findings at `:fast`. | Fixed by the typed `BackendUnavailable` plus a rethrow. Until that landed the consumer guards were load-bearing, and the document was actively advising their removal. |
| 8 | `verify.jl:34`'s guard can go because "both halves are tautologies". | The guard can go, but not for that reason. | `backend_available()` is *not* a tautology — it is false during a consumer's own precompile. The guard is removable because the asserts now fall back to the heuristic, not because the condition is constant. |
| 9 | One declaration is "checked twice at two tiers". | Half true. | See §5 "Still open": the `check_all` leg cannot work, because `@strict_function`'s `register_strict!` runs at the consumer's precompile and that mutation is discarded on cached pkgimage load — §H.3's own argument, never applied to `registry.jl`. |
| 10 | Delete all 7 `_require_backend()` sites. | Only `strict_function.jl`'s changed (into the heuristic fallback, which is what fixed the driver). The rest remain and new ones were added. | Follows from (1) and (3). |

Accurate as written, for the record: the `analysis` axis being fully deleted; AllocCheck/JET/TrimCheck
becoming hard deps of StrictModeTest with both extensions removed; `checks_enabled`/`fail_mode`
remaining Preferences; Cthulhu/Revise/CpuId staying weak in StrictMode.

**Added during implementation, not in any revision of this document:** the `:suspect` status and
`nsuspect` (issue #17 containment), the typed `BackendUnavailable` (item 7), `assert_enabled()`'s
declared-but-unloaded check (§5 item 6), the migration from ReTestItems to TestItemRunner (its
runner assigns `Test.TESTSET_PRINT_ENABLE[]`, which became a `ScopedValue` in Julia 1.13 and killed
the entire suite before a single item ran), and three Julia 1.13 fixes — two of them silent false
negatives in `@assert_inlined` and `@assert_no_threadid_state`.

## 8. Revision 8 — a companion macro in StrictModeTest, not a mode switch

Owner decision, superseding §H.4 (shadowing macros) and §7 item 1 (auto-escalation). Both earlier
mechanisms answered "which engine does this call site use?" with machinery. This answers it with the
macro you wrote, and the machinery goes away.

**Names in `StrictMode` are unchanged.** `@assert_noalloc`, `@assert_typestable`, `@strict` and the
rest keep their spellings and their meaning: the fast, value-free tier. `StrictModeTest` adds
COMPANION macros under distinct names:

| macro | package | engine | authority |
| --- | --- | --- | --- |
| `@assert_noalloc f(x)` | `StrictMode` | typed-IR heuristic | fast tier |
| `@test_noalloc f(x)` | `StrictModeTest` | AllocCheck | authoritative |
| `@test_all_noallocs()` | `StrictModeTest` | AllocCheck | sweeps the registry |

There is no analysis mode to switch, and no ambient state deciding anything: `StrictMode.@assert_noalloc`
IS the `:fast` check and `StrictModeTest.@test_noalloc` IS the `:full` check.

### Throw or warn is per GUARANTEE, not per package

A guarantee whose fast check is **exact** still throws. One that **guesses** warns, because a check
with a measured ~28% false-positive rate must not be able to abort a build (issues #17/#18).

- `:typestable` — return-type concreteness via `Base.return_types` is exact. **Throws.**
- `:noalloc` / `:noboxing` — the typed-IR scan cannot see what LLVM elides. **Warns.**
- `:memsafe` — a guard page is an observation, not an inference. **Throws.**
- Everything else: decide per guarantee on the same test, and record the reason next to it.

The companion `@test_*` macros always throw; they are the authority.

### What this deletes

- **Auto-escalation** — `backend_available()` as a control-flow mechanism, and the whole class of
  "the tier depends on ambient process state".
- **The `_be_*` seam** and its stubs. `StrictModeTest` depends on AllocCheck/JET/TrimCheck directly.
- **`BackendUnavailable`**, `_require_backend`, `_is_fatal_sweep_error`. A backend can no longer be
  *absent* at a call site that needs it — the macro that needs it lives in the package that has it.
  Two of this branch's seven vacuous-green bugs came from that failure class.
- **`:suspect`**, `nsuspect`, `_mkfinding`'s `flagged_status`, `_run_and_report`'s `fail_on_suspect`.
  The status encoded how much to trust a verdict; the macro and the guarantee now carry that
  statically, so a per-finding field is redundant.
- **`:skip`.** An authoritative checker that cannot answer throws `AnalysisError` rather than
  emitting a finding that reads as "not a failure".
- **`fail_mode`, the PREFERENCE.** The per-guarantee rule replaces it: the guarantee decides whether
  it throws or warns, not a global setting. `checks_enabled` becomes the only preference in the
  package — one compile-time switch, off in production, and nothing else. Note this is the
  PREFERENCE only: the `fail = :error/:warn/:none` KEYWORD on `check`/`audit`/`check_all` is a
  per-call reporting choice (collect findings vs. raise) and is orthogonal, so it stays.

Status surface reduces to `:pass` / `:fail` / `:info`. `AnalysisError` is retained: a backend that
*crashes* is still possible and must never render as a pass.

### The constraint this design accepts

`@assert_noalloc` registers **when the call runs**, not when it is declared. Deliberate — a
declaration-time registration is a cross-package mutation discarded on cached pkgimage load, which is
exactly why `check_all` is vacuous in a consumer today (§5 "Still open"). Two consequences:

1. `@test_all_noallocs` re-checks only what the test suite actually **executed**. Coverage follows
   execution — defensible (you prove what you run) but it is not "check everything I declared", and
   must be documented as such.
2. It cannot expand to static `@test_noalloc` calls: at its expansion time nothing has run and the
   registry is empty. It expands to a runtime loop.

Registration must be once-per-signature (not per invocation — that would put a `Dict` insert in a hot
path) and must fire on **pass as well as fail**, or the authoritative tier only re-checks what the
heuristic already flagged, which is backwards.

### Cost

0.4.0 is a breaking release and consumers upgrade. Since the `StrictMode` spellings are unchanged,
the migration is the preference removal (`analysis_mode()`, the `analysis` preference,
`enable_checks!(analysis=)` — 2 call sites across PureBLAS and PureIPM) plus the semantic change that
guess-based guarantees now warn where they used to throw. The latter is silent — a rename would have
been caught by the compiler, this will not be — so it belongs in the release notes, not just a
deprecation warning.

This still invalidates the auto-escalation and `:suspect` work in 920dba8..ff1c1d6.

## 9. Memsafe redesign (independent of §8)

`@assert_memsafe` has no tier involvement — it is value-based, needs no backend, and lives wholly in
`StrictMode`. Its problem is that a guard-page fault is fatal and uncatchable, and a WRITE fault's
backtrace is destroyed, so classification cannot come from the fault. Adversarially designed; three
false passes were confirmed empirically, two of which had been dismissed as theoretical.

**Confirmed by measurement, not argued:**

- **The poison collision is deterministic, not probabilistic.** A store of 8 × `_poison_for(1)`
  (`0xb4`) one element past the end returns a CLEAN canary; a control store of `99.0` at the same
  spot is caught. Any buffer whose fill value equals its poison is missed on every run.
- **Aliasing is broken in both directions.** `f(A, A)` receives two distinct guarded buffers, so a
  kernel asserting `pointer(a) == pointer(b)` errors under the probe. Today's harness both misses
  aliasing-dependent overruns and invents divergent behaviour for kernels that require aliasing.
- **Self-laundering**, previously unidentified: copying a buffer's OWN canary bytes to a shifted
  offset is invisible, because a constant poison is identical at every position.

**The design:**

1. **Delete `isolate=false`.** Its only failure direction is green-when-red — a clean in-process
   canary is indistinguishable from "a read overran and disturbed nothing", in exactly the motivating
   bug class. Its two justifications both die: the saved cost is one ~0.54 s spawn on a deliberate
   gate call, and the closure argument is dead because `Serialization` round-trips a capturing
   closure into a fresh child (verified), so the subprocess path can cover closures directly.
   Keep `:isolate` in `_macro_call`'s allowed tuple purely to REJECT it with a removal message —
   dropping it silently re-positionals the option into `_callinfo` and misparses.
2. **Position-dependent poison**: fill canary byte `k` with `base ⊻ k` rather than a constant. Kills
   the deterministic collision AND self-laundering by arithmetic, at zero cost — a constant-byte
   store mismatches ≥ 7 of 8 bytes of a `Float64`.
3. **Extend the canary over `align` slack**, so stores into slack are detected and reported offsets
   are exact instead of understating by the slack.
4. **Dedupe aliased arguments by identity** (`IdDict`), so `f(A, A)` receives the same guarded buffer
   twice and hit messages name every position sharing it.
5. **Make unguardable arguments loud**: `@assert_memsafe` throws on a `view`/`Adjoint`/non-`Array`
   `AbstractArray`; `memsafe_report` records them in a new `unguarded` field and `show` prints them,
   so a partial-coverage clean report cannot render identically to a full-coverage one.

The one-child architecture (canary classifies → flush → guard probe detects) is unchanged and no path
gains a spawn.

**Knowingly retained false pass:** reads landing in `align` slack are mapped, readable bytes that
disturb no canary. Opt-in — only reachable with a non-default `align` — and the warning must say so
in those terms.

**Pre-existing hazard now named:** the child `include`s the source file `which` points at, so if that
file was edited since `f` was defined in the parent session, the probe checks different code than the
real call runs. Wrong in either direction, including a false pass. Relevant to a Revise-heavy loop;
no cheap fix, since a named function cannot be serialized by value.
