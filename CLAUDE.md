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

## Reference languages for policy

When a guarantee needs a policy choice (what counts as an escape, a read, a derived pointer, a safe
hand-off to C), take precedent from a mature system rather than inventing one:

- **Memory, escape and C interop: Go first.** Like Julia, Go is garbage-collected, has no ownership
  types, lets the compiler decide stack vs. heap by escape analysis, and talks to C through raw
  pointers (`cgo`, `unsafe.Pointer`). Its rules are written for the problem StrictMode has. Examples:
  a derived pointer must stay inside the original allocated object; returning what a parameter
  points to is an escape ("leaking param content"); an external function is assumed to keep its
  pointer arguments unless marked otherwise.
- **Concurrency and unsafe fencing: Rust.** `Send`/`Sync` prove race freedom statically, where Go
  only detects races at run time; `unsafe` blocks and `#![forbid(unsafe_code)]` are the model for
  `unsafe_report`; rustc's diagnostics are the model for messages that explain the fix.
- **Where the two disagree, Julia's own semantics decide.** These are references, not authorities:
  a guarantee is opt-in, and safety is never traded away to match another language.

## Key architecture

```
StrictMode/src/
  StrictMode.jl       — module root, exports, top-level docstring
  macros.jl           — @strict (composite guarantee), @kernel (SIMD shorthand). _guarded_check runs a
                        check once per (site, signature); its cold branch passes the checked function
                        through Base.inferencebarrier (_opaque_function), because a function that is a
                        constant at the call site is constant-propagated through the whole scan and
                        inferred again per site, @nospecialize or not (37 ms per @assert_noboxing site
                        against 6 ms). findings() does the same on entry. Do NOT hand a runner the bare
                        p.checkfn; the flag and promote_op still need the function itself
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
  effects.jl          — _alloc_signals (the value-free IR scan used by noalloc/noboxing/owned). A
                        BOXING STORE sets `boxing` in every mode (_boxing_store, F50): an isbits value
                        written to a slot that holds a reference, by a :new, setfield!, memoryrefset!,
                        setglobal! or an `Any` argument of a :foreigncall. _boxed_on_store is the same
                        isbits rule as StrictModeTest's _is_boxing, read from the store's side; it
                        clears a literal or Const (boxed at compile time), Bool/UInt8/Int8 (boxes that
                        are never allocated, measured), and a value a PiNode or typeassert narrowed
                        from a reference. _stmt_in_scheduler mirrors the proof's _scheduler_site for
                        a statement INLINED from task/lock/condition code, read from the body's
                        debug-info edges. Change one tier's rule and the other's with it. Dispatch
                        is a dynamic :call with a non-concrete result or a boxy argument, plus a
                        surviving Core._apply_iterate (a splat over a Vector: concrete result, callee
                        still looked up at run time). _plain_load names the builtins whose non-concrete
                        result is a reference handed back, not a box: typeassert, Core.current_scope,
                        and a run-time-field getfield on a struct whose fields are ALL held by
                        reference (an inline field does box: 16 B measured). `depth`
                        counts levels of BASE only — the package's own helpers are followed to the end,
                        bounded by _SCAN_BODY_BUDGET, and a scan that read less than the whole tree is
                        `truncated`, which findings report as :fail SM0207, never :pass. A callee result
                        is memoized only when its subtree met no cut (_cut_counter): a result computed
                        below a cut is the walk's, not the body's, and made verdicts order-dependent.
                        INFERENCE runs under _ScanInterpreter with a code cache of its own
                        (_SCAN_CODE_CACHE): the compiler's native cache is serialized into a consumer's
                        package image, so reading bodies through it put native code for every body the
                        scan read into every consumer's image (8.5 MB -> 69 MB, +3.2 GB peak at 300
                        methods). Nothing it infers may be reachable from global state either: the
                        interpreter turns off IR compression (which roots an inlined callee's
                        CodeInstance in the caller method's `roots`) and both backedge writers
                        (finish!'s validation world, codeinst_as_edge), so the cache answers in ONE
                        world only — without backedges nothing would invalidate it.
                        EACH BODY IS INFERRED ONCE, and only the checked package's own: a lookup that
                        misses the scan's cache falls back to the compiler's (_scan_cache_lookup), which
                        holds Base and every loaded package in any world; _typed_body infers a body it
                        lacks in CACHED mode (_infer_body), so the return-type question that follows is a
                        lookup (entered through Base.invoke_interp_compiler, NEVER a direct _CC call: a
                        direct call puts all of inference in the static call graph of every @strict
                        guard, and AllocCheck then took 5 minutes to prove one guarded signature); and
                        the compiler hands the optimized body of every specialization it caches to
                        codegen_cache (_keep_sources -> _scan_source), which is where a callee's
                        body is read from instead of a second inference. Do NOT read a body the compiler
                        holds COMPRESSED: it is what was compiled when the record was made, and differs
                        from a fresh inference of the same signature (measured on 7 of 316 bodies), so
                        a verdict would change once a call has run. _signal_origin's per-body scan is
                        memoized (_ORIGIN_MEMO): every warning walks the graph below its call.
                        Every inference here goes through _code_typed/_return_types/
                        _infer_effects; do not call Base.return_types or Base.code_typed directly.
                        Do not destructure tuples whose type names a consumer's function (`for (f, t) in
                        items`): the indexed_iterate specialization lands in the consumer's image; use
                        getfield. _signal_origin shows which statement and callee a signal comes from.
                        NOTHING the scan calls may specialize on the checked target (a `Type` or function
                        value handed to a method without @nospecialize compiles one method per target,
                        and a consumer's image keeps it): use _sigtype/_code_typed/_return_types, never
                        Base.signature_type/Base.return_types with `Tuple{types...}`; and every scan entry
                        runs inside _window_open/_window_close, which takes back the specializations
                        recorded meanwhile (Base.newly_inferred) while a package is generated: 5752 -> 680
                        specializations on 100 checked targets (8.6 MB -> 1.2 MB of image). The window is
                        OFF while StrictMode's own workload runs (_KEEP_SCAN_SPECIALIZATIONS): the
                        compiler methods specialized on _ScanInterpreter must be in StrictMode's image, or
                        every scanning process compiles them (typeinf_local alone: 0.8 s).
                        ONE EXCEPTION to the private interpreter: a Base.@ccallable method checked while
                        its package is generated is inferred by the compiler's OWN interpreter
                        (_infer_for_image). The image compiles such a method whether or not anything
                        calls it, so the compiler infers its whole tree when the image is written;
                        inferring it privately first is that work twice (68 s -> 55 s on 40 entries
                        over 1440 helpers, image unchanged). Those records are the image's, so they are
                        put back when a window closes (_IMAGE_RECORDS, _WINDOW_DEPTH). Do NOT widen this
                        to methods the image would not compile anyway: that is the image growth the
                        private interpreter exists to prevent.
                        A :noalloc failure whose every allocation is in Base's task/lock/condition code is
                        its own kind, code SM0017 "blocks in the task scheduler" (_scheduler_origin; the
                        proof tier recognizes the same sites in StrictModeTest/src/proofs.jl
                        `_scheduler_site`). "Every" needs its own walk (_nonscheduler_origin): the verdict
                        stops at the first allocation and reads Base only to _FAST_ALLOC_DEPTH, so a wait
                        met first says nothing about an allocation three Base calls down. That walk
                        follows Base to the end outside the scheduler's code, and a walk that cannot
                        finish leaves the finding an ordinary SM0002.
                        _in_scheduler: Base task/lock code contributes no boxing — AllocCheck reports
                        a dynamic dispatch in `trypoptask` for some callers and not others, so it is
                        not a usable signal. _ccall_ref_only accepts the `jl_value_ptr` pointer of an
                        explicit unsafe_convert while it stays confined to ccalls),
                        ignore_throw/set_ignore_throw! (both tiers honor it), _DICT_ACCESSORS,
                        register_alloc_barrier!/_is_base_barrier_type/_mi_is_barrier (issue #14
                        one-time-init allocation barriers: OncePerProcess/OncePerThread auto-
                        recognized (NOT OncePerTask — different Base implementation, no detectable
                        :invoke boundary) + user-registered, both feed the `barrier` alloc signal),
                        _unopt_arg_type/_unopt_callee/_call_callee_and_args (UNOPTIMIZED typed-IR
                        statement reading, for the two scans that must look before the optimizer
                        erases their pattern — static_ownership.jl and trusted.jl). effects/
                        effect_holds wrap Base.infer_effects, and effect_holds covers all NINE
                        Effects fields, so a field Julia adds cannot stay unaskable through
                        @assert_effects (a test compares the predicate set against fieldnames).
                        Every one is a PROOF: false means the compiler could not establish the
                        property, NOT that it fails — :noub is false for a non-const global read
                        and for a dynamic call, neither of which is undefined behavior (measured),
                        so a caller may act on true and must treat false as unknown
  scheduling.jl       — @assert_vectorized, @assert_effects, @assert_no_scalar_loops,
                        @assert_no_spill, kernel_report/KernelReport, register_report/RegisterReport,
                        spill_report/SpillReport, descend, _CACHE_BYTES. :vectorized, KernelReport.vectorized
                        and scalar_fp_loops share ONE predicate, _vector_work: a statement naming a
                        vector type that is not a load, an extractelement, a phi, or an in-order
                        reduction (@llvm.vector.reduce.fadd/fmul without reassoc/fast). AArch64 turns
                        a strict accumulation into vector loads feeding that reduction, which runs
                        one scalar add per lane, so "a `<N x …>` type appears" passed a scalar loop
                        there. A loop holding an in-order reduction is NOT vectorized even when it
                        also holds vector multiplies (_loop_vectorized): x86 leaves that source loop
                        scalar, and the two targets must agree on it. _ir_vectorized drops those
                        loops and asks what is left, so a body with a separate vector loop still
                        passes :vectorized and fails :no_scalar_loops, as on x86. The reductions are
                        counted in KernelReport.ordered_reduce_ops. _kernel_report and
                        _scalar_fp_loops take IR TEXT, so a test classifies IR captured on another
                        target; the vector-type patterns accept `<vscale x N x …>` (SVE/SME)
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
  concurrency.jl      — @assert_concurrency_safe, @assert_no_threadid_state, pool_balance_report.
                        :no_threadid_state is IN _GUARANTEES, so a sweep covers it with no
                        annotation; check.jl clears a signature outright when the compiler proves
                        A sweep has nowhere to name WHICH argument is shared, so it reads argument
                        1: a `!` method therefore gets :info (its name declares that write) and an
                        isbits first argument reports nothing (a copy cannot be written through,
                        and seeding it taints every index derived from it, which made a store into
                        the method own fresh buffer read as a shared write). Both measured in the
                        field: 92 of 134 and 755 of 762 sweep failures were `!` methods.
                        :notaskstate and runs the taint scan only otherwise. It GATES, because a
                        reported site is a store read from typed IR, not an unprovable inference —
                        its limit is recall, a threadid store in an unfollowable callee.
                        The taint scan crosses TWO boundaries the statement loop would otherwise
                        drop: Expr(:new) passes taint to the struct built from a tainted value (an
                        TWO taint levels, because "is the plan" and "holds a reference to the plan"
                        are different facts: a fresh `Factor(sym, …)` points AT the plan and the
                        plan does not point back, so writing its own fields is not writing the
                        plan. `:new` records WHICH field positions received a plan value, so
                        reading that field back is direct and a freshly-built sibling is not — exact
                        rather than a type guess. The container and its field map cross the :invoke
                        boundary, since the writes usually happen in a callee, and a task closure is
                        a container so jl_new_task follows it at that level. One level either made
                        the fresh wrapper BE the plan (four passing assertions in a consumer broke
                        for three releases) or lost a store through it into the plan arrays.
                        INLINABLE wrapper is caught anyway, since inlining routes the store back
                        through the argument — only a @noinline one needs this), and a
                        :foreigncall to jl_new_task follows the task's closure body via
                        code_typed_by_type with the CLOSURE ITSELF tainted, since a capture reads
                        as getfield(self, …) and _PROJECT_OPS carries it on. Field-insensitive, so
                        a task writing a disjoint slice of a captured output still reports — a
                        partition is a property of values. Anything unresolvable is RECORDED, never
                        skipped. pool_balance_report RAISES _UnanalyzableSignature when it cannot
                        read a signature, because a count of nothing balances
  strict_function.jl  — @strict_function (load-time enforcement; `signatures = [...]` verifies
                        concrete instantiations a generic declaration cannot name, since such a
                        declaration infers to `Any`), @strict_stable (per-specialization instead:
                        body moves to a hidden `#f#inner`, the wrapper infers its return type via
                        promote_op so a stable specialization folds the branch away entirely),
                        @strict_exempt (a definition, a name, a `begin … end` block, or an
                        `include` whose definitions are found by diffing the census), @strict_policy
  contracts.jl        — @strict_contract, @verify_strict (pairs a TypeContracts interface with
                        StrictMode performance guarantees. A @verify_strict line is an
                        example call or a SIGNATURE line, `f(::T1, ::T2; k::K)`: _signature_parts
                        yields the same binds/checkfn/types _call_parts does, so both go down one
                        funnel. A keyword signature is the Core.kwcall one with the NamedTuple in
                        the order Base.kwarg_decl gives for the method `which` picks — a
                        NamedTuple type is order-sensitive, and declaration order is the one
                        spelling every listing agrees on. An omitted keyword is simply absent:
                        the sorter tests isdefined and substitutes the default)
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
                        _compiled_output_finding is the SINGLE seam both tiers answer from, for
                        every guarantee no backend can improve on: owned/inlined/vectorized/
                        no_scalar_loops/no_spill/trimsafe (read from compiled output) plus
                        trusted/noescape/no_threadid_state (read from IR or the compiler own
                        escape and effects analyses). StrictModeTest delegates here rather than
                        keeping a second copy, and _findings_fast calls it FIRST, so adding a
                        guarantee here serves both tiers at once. A guarantee in _GUARANTEES that
                        this does not cover and proofs.jl does not branch on throws
                        `unknown guarantee` from a message that lists it as expected — a
                        StrictModeTest testitem enumerates _GUARANTEES to pin that shut
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
  precompile.jl       — a PrecompileTools workload that runs the scan, the module census and the module
                        check on a toy submodule, so a consumer's own precompile (where @strict_policy
                        runs them) does not compile the scan: 4.4 s -> 2.35 s on an 80-method module,
                        0.8 s with checks off. It also runs what a @verify_strict block runs per call
                        (_check_stable_once, _strict_scan) on a call that passes, one that allocates and
                        one that blocks, plus :trim_compatible and :vectorized/:no_spill, so the warnings
                        and the walk that words them are compiled too. Add a path here when a consumer's
                        precompile is found compiling it (julia --trace-compile shows what). It silences
                        its own output by replacing the global logger, NOT with_logger: Base's logger
                        scope specialized on a closure of the workload is a CodeInstance in the
                        workload method's roots, in every process that loads StrictMode
  idioms.jl           — @unroll, staticval (fix for heterogeneous-tuple boxing)
  golden.jl           — @golden (gated bit-exact / ULP-tolerant regression harness)
  trimsafe.jl         — @assert_trim_safe, @assert_trim_compatible, explain_trim (juliac --trim gate;
                        _base_trim_report applies TypeContracts' two statement rules to the body the
                        scan already read (_typed_body) instead of calling TypeContracts.trim_report,
                        which infers the signature twice under the NATIVE interpreter and with it the
                        whole callee tree a second time, into the consumer's image. It reaches three
                        TypeContracts internals (_scan_trim_stmt!, _is_trim_unsafe_callee,
                        _trim_truncate) and falls back to trim_report without them; a test compares the
                        two reports, so a rule added to TypeContracts fails it.
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
                        SAME figure every batch, measured, so agreement proves nothing).
                        allocated_bytes/AllocatedBytes lives here too and shares _control_bytes.
                        _alloc_window is @generated and reads Base.gc_bytes() around a call
                        written out argument by argument, with the callee as f::F and the
                        arguments in a tuple with a type parameter. Do NOT replace it with
                        `@allocated f(args...)`: that lowers to Base.allocated(f, args...), a
                        pass-through Julia does not specialize for a function-valued argument, so
                        sum(abs2, x) reads 16 B there against 0 B here. A type passed as a value
                        rides in _TypeArg{T} for the same reason (a tuple holds it as DataType),
                        and the result is kept alive past the second read, since an unused result
                        lets the compiler delete the allocation. It keeps the MAXIMUM over its
                        windows, like steady_state_report: a minimum reads amortized growth
                        (push!, one call in three) as zero
  spinwait.jl         — spin_wait_report/SpinWaitReport/SpinWaitFinding: how the MIGRATABLE tasks a
                        call spawns wait. A finding needs both a waiting operation read in a loop
                        (yield; the jl_gc_safepoint / jl_cpu_pause foreigncalls; atomic_fence, an
                        intrinsic on 1.13 and an llvmcall of `fence` on 1.12) and NO blocking
                        operation anywhere the task reaches — judged over the whole reach, not per
                        loop, because the correct shape nests its spin inside the loop that
                        blocks. A loop with neither is not reported: it may block in a foreign
                        call. _sw_reach follows :invoke into callees outside Base (a worker loop is
                        usually a named function) and into a Base callee only when it carries a
                        user function (a comprehension's Generator); Base is otherwise judged by
                        name and argument types and NOT entered, because yield itself parks through
                        wait. `lock` is not a blocking operation (a SpinLock spins) and take! on an
                        IO is not either. A task is created BOUND (Task(f), @async); only
                        Threads.@spawn's `sticky = false` write, matched on the task's own SSA
                        value, makes it migratable — bound tasks are counted, not judged, and the
                        tasks they spawn are still read. Unread tasks and unfollowed calls are
                        fields of the report and suppress the green line
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
                        working as intended. alias_guard_report is the third: a `!` method taking
                        two or more possibly-overlapping array arguments whose body never NAMES
                        overlap (mightalias/unalias/dataids, or `===` BETWEEN TWO ARGUMENTS — bare
                        `===` matches the `=== nothing` of every for-loop's iteration protocol and
                        marked every looping method as guarded, measured). Value-free, so it sweeps
                        where :noalias cannot; :info because a guard inside an unfollowed callee
                        reads as absent. An `Any` argument does NOT count as a possible array:
                        typeintersect(Any, AbstractArray) is non-empty, so an unannotated argument
                        made every `!` method with two of them a finding — 5 of 6 on StrictMode
                        itself. An abstract ARRAY type still counts. Judged on m.sig, so an
                        uncalled method is still covered.
                        conversion_report is the fourth: a method converting its OWN numeric data to
                        another type, in three named directions (widened/narrowed/retyped). Read
                        from the conversion INTRINSIC (fpext/sext_int/zext_int/fptrunc/trunc_int/
                        sitofp/uitofp/fptosi/fptoui), never from the types the locals carry and
                        never from the return type. A type set cannot tell a converted value from an
                        unrelated one, and integers make that fatal: a clean Float32 loop carries
                        Int64 and UInt64 counters, so comparing type sets reports every loop in a
                        package (measured). The return type is a mask besides — ::T, T(x) and a
                        store into Array{T} all convert at the boundary and report a flawless T. A
                        conversion counts as the method's own only when its operand type is one the
                        arguments name; Bool is excluded as data, since it is an Integer that widens
                        to be counted. :info, because a deliberately wider accumulator is correct
                        code and is reported (measured: 0 findings over StrictMode's 618 methods,
                        150 over Base.Math's 535, where the widening is the library's whole job)
  resources.jl        — resource_leak_report: where a register_scoped! type, or a value projected
                        out of one, outlives its owner — RETURNED, STORED into a container that is
                        not itself scoped, or CAPTURED BY A TASK (same jl_new_task crossing the
                        concurrency scan uses). Deliberately NOT release-on-all-paths: that needs
                        post-dominance over the exception CFG and a `close` in a helper defeats it.
                        The complement of @assert_noescape, which proves confinement for a handle
                        CREATED in the frame and says nothing about one arriving as an argument.
                        :info, and judged on COMPILED signatures, so warm the kernels first
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
                        threshold belongs to one host. _run_child/_child_values are the shared
                        child-process plumbing (script in, marker lines out); threaded.jl uses them
  threaded.jl         — threaded_speedup_report/ThreadedSpeedupReport and
                        threadcount_invariant_report/ThreadcountInvariantReport: what a call does at
                        another THREAD COUNT. Julia fixes the count at process start, so each data
                        point is a child with its own `-t`, and the call and its setup are strings
                        of code. Speedup times `-t 1` against `-t auto`, both under
                        `taskset -c 0:cpus-1` (unconfined, and reported so, where taskset is
                        missing). Invariance has each child WRITE the result's bytes to a file and
                        compares them here — bits, not printed values and not a tolerance — and
                        takes a `witness` string, because whether a package's threaded path ran is
                        only observable from inside the package and a call that never threads is
                        identical at every count. Gating forms: StrictModeTest.test_threaded_speedup
                        (max_slowdown = 1.5 on by default, a ratio taken on one host; the
                        efficiency bound is opt-in) and test_threadcount_invariant (refuses to run
                        without a witness)
  reach.jl            — reach_report/ReachReport/ReachedFunction, route_parity/RouteParity,
                        @assert_reaches: which functions a call reaches, from OPTIMIZED IR. The
                        defect this finds is a default argument of an inlined call, so only
                        constant propagation exposes it — unoptimized IR shows neither the pruned
                        branch nor anything behind the first hop. Inlined callees leave no call
                        statement and are read from the inlining EDGES of the body's debug info
                        (code_typed_by_type(…; debuginfo = :source); the default strips them),
                        which name a callee only while a statement of it survives. Identity is
                        (module, demangled name), so a keyword method, its `#f#N` body and the
                        positional method are one function. Reuses spinwait.jl's follow policy and
                        task-closure reading. A run-time dispatch is followed when it matches at
                        most _REACH_MAX_METHODS methods; a Base function on Base types is not
                        counted as unread. `stop` cuts a hub (a pool dispatcher reaches every job).
                        unread/dynamic are counted, RouteParity's status is :agree only for two
                        complete non-empty graphs (:incomplete otherwise — an empty graph must not
                        agree with anything), and @assert_reaches throws only when the graph was
                        read in full, warning otherwise. :reaches takes a target, so it is NOT in
                        _GUARANTEES. Gating forms: StrictModeTest.@test_reaches / test_route_parity
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
                        wrapped in AnalysisError). _is_boxing drops a DynamicDispatch that is a C
                        VARARGS call (_c_varargs_call): AllocCheck lists a `ccall` with a required-
                        argument count as a dispatch to an unknown target, and Base.trypoptask holds
                        one (a jl_safe_printf) that every wait reaches, as _string_n does for
                        jl_alloc_string. Judged by the nearest frame with a specialization: its typed
                        body must hold a varargs :foreigncall and no dispatch of its own.
                        _raw_allocs is AllocCheck's sites PLUS _native_dispatches (F49): AllocCheck
                        compiles through GPUCompiler with compilesig_invokes = false, so every
                        callee is the specialization for the inferred types, while Julia invokes the
                        method's compilation signature (a passed-along `Function` stays `Function`)
                        and leaves a call dynamic when that signature is not compileable. The walk
                        reads natively optimized bodies and reports each non-builtin :call as a
                        DynamicDispatch. _is_boxing reads a heap allocation of an isbits type as a
                        box; do NOT narrow it to `Any` slots: an abstract-eltype slot boxes the same
                        way and the site carries no destination.
                        _kept/_Stamp keep two reads for the session: the sites of a signature
                        (_SITES_MEMO) and what the walk
                        reads from one body (_WALK_MEMO, by MethodInstance, shared by every
                        signature that reaches it). A kept read holds in its own world, and in a
                        later one while the compiler's CodeInstance for the specialization is valid;
                        clear_cache! ends both through _GENERATION. Do NOT read a body from
                        the compiler's cache instead of typeinf_code: it holds source for 115 of
                        1945 walked LinearAlgebra bodies and 17 of those differ from a fresh read.
                        _opt_reports (JET,
                        wrapped in AnalysisError), _trim_validate (TrimCheck), _proof_findings/
                        proof_findings, ignore_barrier/set_ignore_barrier!
                        _trim_validate returns (passed, findings, sites, ORACLE): :patched is the
                        program juliac compiles, verified in one child per gate (_trim_batch!/
                        _TRIM_BATCH, filled by _gate); :stock is this session's Base. _trim_reason
                        names which, because a stock rejection is not a juliac rejection.
                        _trim_child_modules resolves what the child must load — the METHOD's module
                        and each argument type's, not parentmodule(f)
  src/macros.jl       — @test_noalloc/@test_noboxing/@test_typestable/@test_trim_compatible,
                        @test_steady_state/@test_no_gc_pause/@test_allocated_zero (the MEASURED
                        gates — they take values and run the call, and need no analysis backend at
                        all). @test_allocated_zero binds the callee and each argument through
                        _call_parts and hands the VALUES to StrictMode.allocated_bytes; any positive
                        figure FAILS, and the control window only decides whether the message calls
                        it unattributable, since "could not measure" and "is clean" must not render
                        alike. The call runs warmups + windows + 1 times. @test_reaches fails on an
                        absent target whether or not the graph was read in full.
                        Deliberately NOT wrapped in _gate: a gate that compiles itself away under
                        a preference is a gate that can vanish silently
  src/drivers.jl      — test_signatures/test_compiled/test_registered/test_coverage (the last one
                        gates on UNdeclared methods, the hole the others cannot see), plus
                        alloc_entry_report/AllocEntryReport/AllocEntry: every ENTRY POINT of one
                        function with the allocation proof's verdict for each. A proof of
                        f(args...) covers the positional method; the Core.kwcall method a keyword
                        caller reaches is separate compiled code whose NamedTuple parameter is
                        declared abstract, so it is ALWAYS :unproven and is listed rather than
                        omitted — omitting it is what makes a suite read as covered. The kwcall
                        lookup uses Core.Typeof(f): typeof of a type is DataType, which matches
                        every type's keyword constructor. Each driver collects
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
                        ExplicitImports; do not re-implement it, and pass
                        allow_internal_accesses = false — ExplicitImports defaults it to TRUE, which
                        drops every access between modules sharing a Base.moduleroot, so with the
                        default rule 2 fires only between separate PACKAGES and sibling submodules go
                        unjudged (the main use of a layer graph: two packages already have Pkg-level
                        separation). Safe because the graph is still the filter — a row is kept only
                        when the accessed module is a declared layer AND a different one. Paths come
                        from pathof(moduleroot(layer)), since a submodule has no pathof of its own
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
alone.

The suite contains no `@test_broken` and no `@test_skip`, so every pass reports passes only: a
broken or errored count in any of the four is a regression. A skipped shape item shows up as a
lower TOTAL instead — the 1.12 bounds-checked pass runs a couple fewer assertions than the other
three, which agree with each other.

```bash
# safety: every @inbounds neutralized.
julia --project=StrictMode -e 'import Pkg; Pkg.test(; julia_args = ["--check-bounds=yes"])'
julia +1.12 --project=StrictMode -e 'import Pkg; Pkg.test(; julia_args = ["--check-bounds=yes"])'

# codegen: the compiled-output items actually run.
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
- **Certainty decides throw-vs-warn, and it can be per FINDING, not only per guarantee.** StrictMode
  throws only where it is 100% sure and warns where its verdict is a heuristic; StrictModeTest throws
  by definition, because AllocCheck/JET/TrimCheck are full machinery rather than a scan. `_fail`
  takes a `gates` keyword for exactly this, so one guarantee can do both: `_ConcViol` carries
  `certain`, set at the three record sites where the scan READ a write (a store, or a named
  `_BASE_MUTATORS` callee) and left `false` at the six "flagged conservatively" sites, and
  `_assert_concurrency_safe` raises only when `any(v -> v.certain, vs)`. `typestability.jl` and
  `trusted.jl` do the same for their own uncertain signals. The DEFAULT on a new record is
  `certain = false`, so an unclassified one warns.

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

Documents dogfooding findings (F1–F50 as of this writing — check the file's own status table for
the current count, it moves faster than this file) from the PureFFT.jl and BlazingPorts.jl/QR
campaigns. Most findings are ✅ closed; a few are 🔴 open by design (e.g. F29/F30 — necessary-but-
not-sufficient axes `kernel_report`/the guarantees don't yet cover: data-dependent load latency,
scalar-gather transpose cost). Update the status table when closing or opening a finding — don't
trust "all ✅" without checking, it has been wrong before.
