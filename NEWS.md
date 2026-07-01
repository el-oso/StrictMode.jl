# StrictMode.jl release notes

## v0.3.4

Additive, non-breaking: multi-threading correctness guarantees (value-free IR scans — no
AllocCheck/JET backend needed).

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
