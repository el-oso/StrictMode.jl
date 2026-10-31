# StrictMode.jl — contributor context for Claude

## What this is

StrictMode.jl is a Julia package that makes performance guarantees (no allocations, type
stability, vectorization) enforceable at dev/CI time and free in production. The macros expand to
the bare call when checks are off (`checks_enabled`, default **`true`**; a shipped application calls
`disable_checks!()`).

**Two packages. `StrictMode` reports; `StrictModeTest` gates.** `StrictMode` analyzes with a
value-free engine — inferred return types plus a scan of typed IR — and depends on no analysis
backend at all. `StrictModeTest` (a `test/Project.toml` dep) has AllocCheck + JET + TrimCheck as
hard deps and adds `@test_noalloc`/`@test_noboxing`/`@test_typestable`/`@test_trim_compatible` plus
`test_signatures`/`test_compiled`/`test_registered`. **Which engine a call site uses is the macro
you wrote** — decided at expansion by name, with no ambient state and nothing to switch.

## Key architecture

```
StrictMode/src/
  StrictMode.jl       — module root, exports, top-level docstring
  macros.jl           — @strict (composite guarantee), @kernel (SIMD shorthand)
  preferences.jl      — checks_enabled/enable_checks!/disable_checks!/proofs_loaded, _gate (the
                        zero-cost compile-time expansion switch), assert_enabled, _announce_tier
                        (the load-time banner naming which TIER a session is in), direct_dependency
                        (whether an environment this session loads from names StrictMode — the
                        reporting banner's audience test, written to stay trim-clean because
                        __init__ is a juliac root, issue #28)
  static_checks.jl    — @assert_noalloc, @assert_noboxing, @assert_owned, @assert_noescape
                        (register_scoped! types, via the compiler's escape analysis), @assert_noalias
                        (Base.mightalias between the written arguments and the read ones — the only
                        check here that reads VALUES, so :noalias is deliberately NOT in _GUARANTEES:
                        no sweep has values to give it)
  typestability.jl    — @assert_typestable, _typestable_check_expr/_typestable_fast
  inlining.jl         — @assert_inlined, inline_suggestions (module-sweep advisory)
  effects.jl          — _alloc_signals (the value-free IR scan used by noalloc/noboxing/owned),
                        ignore_throw/set_ignore_throw! (both tiers honor it), _DICT_ACCESSORS,
                        register_alloc_barrier!/_is_base_barrier_type/_mi_is_barrier (issue #14
                        one-time-init allocation barriers: OncePerProcess/OncePerThread auto-
                        recognized (NOT OncePerTask — different Base implementation, no detectable
                        :invoke boundary) + user-registered, both feed the `barrier` alloc signal),
                        _unopt_arg_type/_unopt_callee/_call_callee_and_args (UNOPTIMIZED typed-IR
                        statement reading, for the two scans that must look before the optimizer
                        erases their pattern — static_ownership.jl and trusted.jl)
  scheduling.jl       — @assert_vectorized, @assert_effects, @assert_no_scalar_loops,
                        @assert_no_spill, kernel_report/KernelReport, register_report/RegisterReport,
                        spill_report/SpillReport, descend, _CACHE_BYTES
  static_ownership.jl — static_ownership_suggestions (module-sweep static-ownership advisory)
  dispatch.jl         — _instability_cause (which declaration made a body unstable: a non-const
                        global, an abstract field, an abstract container eltype, reflection, or more
                        matching methods than max_methods) and dispatch_report/DispatchReport (a
                        module's dynamic call sites, plus the ones sitting AT max_methods — static
                        today, dynamic as soon as one more method is defined anywhere). A
                        method-enumerated (union-split) call is recognized by its
                        Core.throw_methoderror fallthrough, since the split itself leaves no call
  trusted.jl          — Untrusted{T}/unsafe_trust/trust_boundary!/@assert_trusted (:trusted — the
                        payload of foreign data may only be read inside a registered boundary; the
                        Julia form of the kernel's `__user` annotation). Dispatch enforces the type
                        with no checker at all; the scan covers what the language cannot, reading
                        UNOPTIMIZED typed IR via effects.jl's _unopt_* helpers because a small
                        boundary inlines and its getfield would surface in an innocent caller
  concurrency.jl      — @assert_concurrency_safe, @assert_no_threadid_state, pool_balance_report
  strict_function.jl  — @strict_function (load-time enforcement; `signatures = [...]` verifies
                        concrete instantiations a generic declaration cannot name, since such a
                        declaration infers to `Any`), @strict_stable (per-specialization instead:
                        body moves to a hidden `#f#inner`, the wrapper infers its return type via
                        promote_op so a stable specialization folds the branch away entirely),
                        @strict_exempt (a definition, a name, a `begin … end` block, or an
                        `include` whose definitions are found by diffing the census), @strict_policy
  contracts.jl        — @strict_contract, @verify_strict (pairs a TypeContracts interface with
                        StrictMode performance guarantees)
  registry.jl         — @strict_function registry, register_strict!, watch/unwatch, _demangle
                        (kwsorter name stripping), and the ITEM BUILDERS both tiers share:
                        _registry_items/_compiled_items/_map_findings/_run_and_report. The
                        reporting drivers _findings_all/_findings_compiled are here too;
                        StrictModeTest's test_registered/test_compiled reuse the same item lists.
                        module_methods is the CENSUS (Base.visit(Core.methodtable) filtered by
                        module, so a method on a FOREIGN function counts); _coverage_all_findings
                        is default-deny over it, _coverage_findings the narrower public-function
                        form; _is_parametric_def keeps a `where` definition out of the registry.
                        _STORES/_store_for memoize each module's store so a reader never touches a
                        binding created in its own world (a Julia 1.12 warning, a later error).
                        declarations()/exemptions() union each loaded package's OWN store with this
                        session's; module_policy/_set_module_policy! back @strict_policy, and
                        _auto_check_module checks _module_load_items — the module's METHODS, so an
                        include'd definition is covered where a body rewrite could not see it
  audit.jl            — audit (the reporting entry point; no exit status, never throws, and no
                        rendering: it returns the findings and format_findings renders them).
                        audit_changed diffs a run against the previous one — _LAST_AUDIT in this
                        session, or a Serialization baseline FILE another session can read
  check.jl            — findings/_findings_fast/_compiled_output_finding — the interference-proof
                        core every guarantee funnels through: no macro parsing, no execution.
                        _compiled_output_finding covers the guarantees read from compiled output
                        (owned/inlined/vectorized/no_scalar_loops/no_spill/trimsafe), so
                        StrictModeTest delegates to it rather than keeping a second copy
  findings.jl         — StrictFinding struct (carries `tier`: :report vs :proof, `code`, and
                        `policy`: the macro line that required the guarantee),
                        format_findings,
                        nfailures, _failed, key (a finding's identity across runs), findings_diff
  explain.jl          — @explain, StrictReport (built on the value-free engine)
  codes.jl            — the diagnostic codes: _CODES keyed on (guarantee, cause) — NEVER on the
                        reason text, which is assembled per call site — plus explain(code)/codes().
                        A published code is permanent; a retired kind leaves a gap
  cache.jl            — (method, world, signature, guarantees) → findings cache. Each entry also
                        holds the CodeInstances its verdict was read from (_watch_instances): the
                        key cannot see an edit to a CALLEE, but Julia caps those instances'
                        max_world when one changes, so a stale entry is dropped on lookup
  report.jl           — StrictViolation exception, _fail, _guarantee_gates (which guarantees
                        THROW from StrictMode and which only WARN — observation vs. inference)
  backend.jl          — the llvm-mca seam ONLY (`_be_mca_*`, mca_available). The analysis tier is
                        NOT a seam: nothing here reaches for a backend that may or may not be loaded
  idioms.jl           — @unroll, staticval (fix for heterogeneous-tuple boxing)
  golden.jl           — @golden (gated bit-exact / ULP-tolerant regression harness)
  trimsafe.jl         — @assert_trim_safe, @assert_trim_compatible, explain_trim (juliac --trim gate;
                        issue #13: a heuristic-path PASS logs a one-time _TRIM_HEURISTIC_CAVEAT note
                        that reachability-limit union-splits aren't covered — status/reason on the
                        structured StrictFinding are untouched, macro-path-only visibility)
  memsafe.jl          — @assert_memsafe, memsafe_report/MemsafeReport, _guarded_array/GuardedBuffer
                        (guard-page harness for deterministic OOB read/write detection; the probe
                        always runs in a subprocess via Serialization + Base.run — an in-process
                        probe cannot observe a read overrun. _guarded_args shares one buffer between
                        aliased argument positions; _unguarded_args names what the harness could not
                        cover). The page primitives are per-platform behind `@static if`:
                        mmap/mprotect/munmap on POSIX, VirtualAlloc/VirtualProtect/VirtualFree on
                        Windows. The _PROT_* flags stay the internal vocabulary on BOTH, because
                        guard_prot is read as a bitmask (guard_prot & _PROT_READ decides whether the
                        canary can be read back) and Windows page constants are an enumeration that
                        cannot answer that — they appear only at the ccall boundary. The fault
                        reaches the parent three ways and all count: a signal (POSIX), exit status
                        0xc0000005 (Windows, compared modulo UInt32 since the sign varies), or a
                        catchable ReadOnlyMemoryError when Julia's handler gets there first
  steady.jl           — steady_state_report/SteadyStateReport (dev-time measurement of allocation
                        that STOPS once warmed, for a pool climbing to a high-water mark. Takes
                        VALUES and runs the call, so it sits outside the value-free findings/audit
                        pipeline — same species as memsafe_report/mca_report. The gating form is
                        StrictModeTest.@test_steady_state; this one never raises.
                        THREE verdicts, because @allocated is PROCESS-wide and Julia has no per-task
                        allocation counter (Task tracks only time). A positive figure is followed by
                        _control_bytes, an allocation-free _spin window of the same duration:
                        whatever THAT records was allocated by something else, so the verdict is
                        `inconclusive` rather than a count, and @test_steady_state fails on it. A
                        ZERO needs no control — noise can only add — so `steady` holds however busy
                        the process is. Measured: one neighbor task charges 2120 bytes to a clean
                        call, 3MB over a 2ms window. Do NOT try to separate noise by aggregating
                        repeats (min-of-K, or two batches agreeing): a periodic neighbor gives the
                        SAME figure every batch, measured, so agreement proves nothing)
  gcpause.jl          — gc_pause_report/GcPauseReport (whether a GC ran while the call did, plus the
                        per-call pause distribution). The axis the allocation guarantees cannot
                        cover: the collector stops the world, so an allocation-free kernel is paused
                        by an ALLOCATING NEIGHBOR, and the cause is not in the analyzed code.
                        _gc_pause_samples! must stay allocation-free — a harness that allocates
                        creates the collections it counts. Every Base.GC_Num counter is PROCESS-wide
                        (so is @allocated, measurably), which is why the field is `process_bytes`
                        and not the call's own allocation. Gating form: StrictModeTest.@test_no_gc_pause
  lints.jl            — bang_report (a `!` name and its mutation disagreeing; reuses
                        concurrency_findings' taint scan, asked once per argument — the "writes
                        without a !" direction is FOUND, the "! that writes nothing" direction is a
                        lead, since mutation through an unfollowable callee reads as none) and
                        specialization_report (compiled-specialization count + type-parameter depth
                        against caller-given limits). Both :info with NO gating counterpart: a
                        convention is a convention, and a high specialization count is usually Julia
                        working as intended
  throws.jl           — throw_report: the exception types a body raises ITSELF, read from its own
                        typed IR. Deliberately NOT transitive — `v[1]` raises BoundsError inside
                        getindex and nearly any call can raise OutOfMemoryError, so "everything
                        reachable" converges on "nearly everything" and says nothing. A test pins
                        the exclusion
  unsafefence.jl      — unsafe_report (the Julia form of Rust's #![forbid(unsafe_code)]): every
                        method calling ccall, pointer, or an unsafe_* function, with a PER-CONSTRUCT
                        `allow` list. UNOPTIMIZED IR, and that is load-bearing — an @inline helper
                        around a pointer load inlines, so an optimized scan blames the innocent
                        caller and clears the method that wrote it (measured). A :foreigncall
                        suppresses cconvert/unsafe_convert, which are its own lowering, not two more
                        defects. @inbounds is covered as :inbounds, read from ci.ssaflags via
                        _IR_FLAG_INBOUNDS, since it leaves no statement to match on; a
                        @propagate_inbounds method is clean and the caller that wrote @inbounds
                        carries the finding. Gating form: StrictModeTest.test_no_unsafe
  latency.jl          — latency_report/LatencyReport (load time + first-call time). Both are
                        properties of a COLD process, so every number comes from a child that
                        inherits this session's active project; nothing in typed IR predicts them.
                        The child reports by line and keys times by INDEX, never by the call's text,
                        which is the caller's and may hold a quote or a newline. Gating form:
                        StrictModeTest.test_latency, whose budgets are opt-in because a wall-clock
                        threshold belongs to one host
  test/mca_live.jl    — the live llvm-mca assertions, shared by mca_test.jl's live item and
                        test/mca_live_runner.jl so the two cannot drift. LLVM_full_jll is ~680MiB
                        and is a dep of NO environment here, so mca_available() is false everywhere
                        and that item skips: CI builds a throwaway env that adds the weak dep and
                        runs the runner, which is the only place mca_report actually executes
  mca.jl              — @assert_mca, mca_report/McaReport (issue #16 Tier 2: llvm-mca-backed
                        throughput/IPC estimate, informational only — never fails without an
                        explicit max_rthroughput=/min_ipc= bound). _sanitize_asm_for_mca (drops the
                        `;`-comment Function-Signature line llvm-mca's assembler chokes on),
                        _innermost_loop_span/_wrap_mca_region (region markers around the ymm/zmm-
                        containing loop — NOT bare xmm, which scalar SSE ops also use — to avoid the
                        whole-function false-loop-carried-dependency trap), _resolve_mcpu (llvm-mca's
                        CLI hard-fails on an unrecognized -mcpu, unlike Julia's own codegen path, so
                        this validates against `-mcpu=help` and falls back to "generic")
StrictMode/ext/
  StrictModeCthulhuExt.jl   — descend() fills _CTHULHU_DESCEND
  StrictModeCpuIdExt.jl     — CPU-specific _CACHE_BYTES override (weak dep, `using CpuId`)
  StrictModeReviseExt.jl    — cache invalidation on code change
  StrictModeMcaExt.jl       — llvm-mca CLI glue for mca_report (weak dep, `using LLVM_full_jll`,
                              ~680MiB — never a test/CI default, see test/mca_test.jl's live-path guard)
StrictModeTest/       — the PROOF tier, a SEPARATE package, sibling subfolder, test-environment only
  src/StrictModeTest.jl — module root; AllocCheck/JET/TrimCheck as HARD deps. __init__ REFUSES to
                        load unless StrictMode.checks_enabled() (otherwise every @assert_* is a
                        bare call, nothing registers, and test_registered() sweeps an empty
                        registry and passes), then announces the proof tier.
  src/proofs.jl       — _raw_allocs/_is_boxing/_checked_allocs (AllocCheck), _opt_reports (JET,
                        wrapped in AnalysisError), _trim_validate (TrimCheck), _proof_findings/
                        proof_findings, ignore_barrier/set_ignore_barrier!
                        _trim_validate returns (passed, findings, sites, ORACLE): :patched is the
                        program juliac compiles, verified in one child per gate (_trim_batch!/
                        _TRIM_BATCH, filled by _gate); :stock is this session's Base. _trim_reason
                        names which, because a stock rejection is not a juliac rejection.
                        _trim_child_modules resolves what the child must load — the METHOD's module
                        and each argument type's, not parentmodule(f)
  src/macros.jl       — @test_noalloc/@test_noboxing/@test_typestable/@test_trim_compatible,
                        @test_steady_state/@test_no_gc_pause (the two MEASURED gates — they take values
                        and run the call, and need no analysis backend at all).
                        Deliberately NOT wrapped in _gate: a gate that compiles itself away under
                        a preference is a gate that can vanish silently
  src/drivers.jl      — test_signatures/test_compiled/test_registered/test_coverage (the last one
                        gates on UNdeclared methods, the hole the others cannot see); each collects
                        every failure and raises ONCE, so one unanalyzable method leaves the rest
                        evaluated. test_calls gates on whether a call RESOLVES at all: report_opt
                        answers a performance question and is silent on a MethodError sitting on a
                        cold branch, so report_call (via proofs.jl's _call_reports) is the only
                        thing here that sees it. Only :MethodErrorReport/:UndefVarErrorReport are
                        gated — measured on StrictMode itself, the other kinds are ~98% of the
                        output and not actionable. :calls is NOT in _GUARANTEES (no sweep-side
                        scan), so only/exempt BY NAME is the escape hatch for a guard inference
                        cannot follow. test_specializations gates the GROWTH of a compiled-
                        specialization count, never the count: there is no absolute threshold, which
                        is why specialization_report is :info. The Serialization baseline is keyed on
                        (VERSION, workload) — the version because codegen decides the count, the
                        workload because _specializations reports what compiled in THIS session, so
                        the same call placed later in a suite measures something else. A missing key
                        records and passes, so adding it to a suite never fails on day one; a method
                        the baseline does not name has nothing to regress against
  src/layers.jl       — test_layers over a DECLARED layer graph: a method may only extend a function
                        owned by a layer its own layer declared (Julia has no orphan rule, and the
                        intended direction of dependency is a declaration, not a language fact), and
                        no layer may read a non-public name of another. Only modules IN THE GRAPH are
                        judged — StrictMode's own 66 improper accesses are deliberate Base/Core reads,
                        and judging those would bury the layer findings. The access half calls
                        ExplicitImports; do not re-implement it. Paths come from
                        pathof(moduleroot(layer)), since a submodule has no pathof of its own
  src/divergence.jl   — divergence_report/StrictDivergence/save_divergence (needs BOTH engines,
                        which is why it lives here)
  test/               — its own suite, @testitem/TestItemRunner like StrictMode's: runtests.jl is
                        the runner, fixtures.jl the shared @testmodule, then one file per concern
                        (proofs/macros/drivers/trim/typestable/divergence). Covers the proof
                        primitives StrictMode cannot test, because StrictMode does not depend on
                        those packages at all
StrictMode/test/
  runtests.jl         — TestItemRunner @run_package_tests; `using StrictModeTest` supplies the proofs
  Project.toml        — no [preferences.StrictMode] block: checks_enabled defaults to true, and this
                        env exercises that default
  standalone/         — a StrictMode-ONLY environment (deps: StrictMode + Test). The only place the
                        split's premise can be falsified: every item under test/ runs with the proofs
                        loaded, so none of them can catch a guarantee that re-acquires a hard
                        AllocCheck/JET dependency. Run as its own CI step.
  round5_test.jl      — kernel_report / @assert_vectorized (F10–F15, F38)
  kernel_test.jl      — @kernel macro
  *_test.jl           — one file per guarantee
```

This table is a map, not a promise — when adding/moving a top-level definition, update the entry for
the file you touched rather than trusting this list; it has drifted before (verify with `ls StrictMode/src/`).

## Running tests

`Pkg.test()` from the MAIN environment — not `test/runtests.jl` directly. Running the file directly
leaves bounds checking at `auto`, whereas `Pkg.test()` forces `--check-bounds=yes`, and the two
generate different code: five vectorization-shape tests only fail under forced bounds checks, which
is how they stayed invisible in CI. The compat floor is 1.12 and `+release` tracks the current
release, so name the floor explicitly with `+1.12` rather than through a channel that moves.

**Pass `--check-bounds` explicitly; Pkg does not supply it on 1.13.** Pkg forces
`--check-bounds=yes` through 1.12 and inherits the caller's setting from 1.13 on, so a bare
`Pkg.test()` on 1.13 leaves every `@inbounds` in the tested code live.

**The suite needs TWO passes, and CI runs both.** Bounds-check insertion and coverage
instrumentation reshape generated code, and the items asserting on its SHAPE
(`scalar_fp_loops`, `@assert_no_spill`'s failing paths, `@strict_stable`'s line count) ask the
compiled output directly and SKIP where the flags erased their subject — a skip that counts as
green. Measured: a `@simd` loop does not vectorize under coverage on either version, nor under
forced bounds checks on 1.12. So one pass neutralizes `@inbounds` and the other leaves codegen
alone; only the `:trusted` `@test_broken` and the absent llvm-mca dep stay broken in the second.

```bash
# safety: every @inbounds neutralized. 6 broken on 1.12, 2 on 1.13.
julia --project=StrictMode -e 'import Pkg; Pkg.test(; julia_args = ["--check-bounds=yes"])'
julia +1.12 --project=StrictMode -e 'import Pkg; Pkg.test(; julia_args = ["--check-bounds=yes"])'

# codegen: the compiled-output items actually run. 2 broken on both versions.
julia --project=StrictMode -e 'import Pkg; Pkg.test(; julia_args = ["--check-bounds=auto"])'
julia +1.12 --project=StrictMode -e 'import Pkg; Pkg.test(; julia_args = ["--check-bounds=auto"])'
```

`julia_args` overrides Pkg's own forcing on 1.12, so the second form really does reach `auto`.

The test `Project.toml` depends on `StrictModeTest`, which supplies the AllocCheck/JET/TrimCheck
proofs; checks are on by default, so it carries no preference block. `StrictModeTest` has its own
suite — run it whenever you touch a proof primitive:

```bash
julia --project=StrictModeTest -e 'import Pkg; Pkg.test()'
```

Tests use `@testitem` (TestItemRunner.jl, macros from TestItems.jl
— `@testmodule`, not ReTestItems' `@testsetup`). Iterate on one item by name through the warm daemon:

```bash
JULIAUP_CHANNEL=release jl -e 'using StrictMode, StrictModeTest, TestItemRunner; @run_package_tests filter = ti -> occursin(r"F10", ti.name)'
```

The proof-free premise has its own environment; run it whenever you touch a guarantee's engine:

```bash
julia --project=StrictMode/test/standalone -e 'import Pkg; Pkg.instantiate()'
JULIA_LOAD_PATH="@:@stdlib" julia --project=StrictMode/test/standalone StrictMode/test/standalone/runtests.jl
```

## Key invariants

- **`StrictMode` and `StrictModeTest` ship in lockstep.** StrictModeTest reaches into ~20 StrictMode
  internals (`_alloc_signals`, `_compiled_output_finding`, `_mkfinding`, `_call_parts`, `_gate`, …),
  so their versions move together and StrictModeTest's `[compat]` names the exact StrictMode minor
  it was built against, not the loose `"0.4"`. A signal added to the scan must also be wired into the
  matching proof, or the reporting tier ends up STRICTER than the gating one — which is what happened
  when `unionphi` (F39) landed in `_typestable_fast` and JET could not see it.

- **No Python**. No PythonCall/PyCall, no pip deps.
- **No new main-Project.toml deps** for test-only packages — those go in `test/Project.toml`.
- `_gate(checked, fallback)` in `preferences.jl` is the zero-cost expansion switch — every macro routes through it. The `checks_enabled` preference is a compile-time const baked at precompile; changing it requires a restart.
- `@contract`-style macro headers in the sibling TypeContracts package can't be module-qualified (e.g. `@contract Base.AbstractLock` fails to parse — needs `import Base: AbstractLock` first) — worth knowing if you're pairing `@strict_contract`/`@verify_strict` with a foreign type.
- AllocCheck/JET/TrimCheck are **not dependencies of StrictMode at all** — not even weak ones. They are hard deps of `StrictModeTest`. Never import them from `src/`, and never add them back to `Project.toml`: `test/standalone` exists to fail if you do.
- **Tier selection is the macro name, decided at expansion.** `@assert_noalloc` IS the value-free
  scan; `@test_noalloc` IS the AllocCheck proof. Nothing reads a flag at call time, so no ambient
  state can silently pick the other engine — and a `@test_*` macro can never find its backend
  missing, because the package that defines it is the package that depends on it. Consequence:
  `@strict_function`/`@strict module` run at the annotated module's own precompile, where
  `StrictModeTest` is not loadable, so the suite re-proves those signatures via
  `test_registered()`/`test_signatures` at runtime instead.
- **A declaration lives in the module that made it, not in StrictMode.** `register_strict!(f, types;
  mod)` and `_exempt!(name, mod)` write to a `const __strict_declarations__` / `__strict_exempt__` in
  `Base.moduleroot(mod)`, and every driver reads `declarations()` / `exemptions()`, which union those
  with this session's `STRICT_REGISTRY` / `STRICT_EXEMPT`. Do NOT route the macros back through the
  global Dicts: StrictMode is already loaded from its own pkgimage when a consumer precompiles, so a
  cross-package insert there is discarded on the consumer's next cached load, and the consumer's test
  process then sees an empty registry however much its `src/` declares — which makes a default-deny
  coverage gate call the whole package undeclared. `test/consumer` pins this.
- **`_guarantee_gates` (report.jl) decides throw-vs-warn, per guarantee.** A check that OBSERVES
  compiled output gates (`:typestable`'s return-type layer, `:memsafe`, `:vectorized`, `:no_spill`,
  `:inlined`, `:owned`, `:trusted`). A check that INFERS something it cannot see reports:
  `:noalloc`/`:noboxing` (typed IR cannot see what LLVM elides; 120/120 agreement with AllocCheck on
  the 120-specialization corpus as of 0.4.5, but 8.1% false and 75% recall on earlier releases of the
  same corpus — the gap is structural, issue #17), `:no_scalar_loops` (SLP output forges its
  discriminator), `:trimsafe`/
  `:trim_compatible` (the static scan does not model juliac's reachability limit), and
  `:typestable`'s depth-0 boxing signal and its union-typed-local signal (both `gates = false` at
  their call sites in `typestability.jl`).
  Do NOT make StrictMode's allocation verdicts gate: a heuristic false positive aborting a
  consumer's precompile is issue #18, and it made checks-on unusable in PureBLAS. The proofs in
  `StrictModeTest` gate unconditionally — that is what that package is.
- **A finding the analysis could not evaluate is `:fail`**, carrying the error text (`_unevaluated`
  in check.jl, `_errored_findings` in registry.jl). Never `:pass`: "could not check" and "is fine"
  rendering the same is how a crashed backend reported success for every method in a sweep. Tests
  should assert `StrictMode._failed(f)` rather than `f.status === :fail`, which pins a symbol
  instead of the intent.
- `_demangle(sym)` in `registry.jl` strips `#foo#NN` kwsorter mangling so `only`/`exempt` match keyword-argument functions correctly.
- `ignore_throw() = true` is the default and lives in StrictMode (`effects.jl`) — throw-path allocations don't count, and BOTH tiers honor it, so the scan and AllocCheck answer the same question.
- `kernel_report` and `@assert_vectorized` work from `InteractiveUtils.code_llvm` — no backend needed. `_CACHE_BYTES` is a tunable `Ref` for cache-residency annotation thresholds.

## FEEDBACK.md

Documents dogfooding findings (F1–F38 as of this writing — check the file's own status table for
the current count, it moves faster than this file) from the PureFFT.jl and BlazingPorts.jl/QR
campaigns. Most findings are ✅ closed; a few are 🔴 open by design (e.g. F29/F30 — necessary-but-
not-sufficient axes `kernel_report`/the guarantees don't yet cover: data-dependent load latency,
scalar-gather transpose cost). Update the status table when closing or opening a finding — don't
trust "all ✅" without checking, it has been wrong before.
