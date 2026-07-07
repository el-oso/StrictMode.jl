# StrictMode.jl release notes

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
