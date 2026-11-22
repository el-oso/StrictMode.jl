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
                        __init__ is a juliac root, issue #28), unknown_preferences (keys set for
                        StrictMode that it does not read, from a byte scan of the preference
                        files — no TOML parser, same trim reason — covering inline tables too; a
                        file that exists and cannot be read is named ONCE via _eprint, tracked
                        in _UNREADABLE_PREFERENCES, never counted as setting nothing)
  static_checks.jl    — @assert_noalloc, @assert_noboxing, @assert_owned, @assert_noescape
                        (register_scoped! types, via the compiler's escape analysis), @assert_noalias
                        (_overlap between the written arguments and the read ones — the only
                        check here that reads VALUES, so :noalias is deliberately NOT in _GUARANTEES:
                        no sweep has values to give it. Two arrays that declare their dataids are
                        answered by Base.mightalias alone, allocation-free, which is what keeps
                        disjoint views of one parent apart. An array type with NO dataids method
                        (_declares_ids: the fallback answers with the wrapper own objectid) and a
                        non-array struct (a closure too: _reads_memory) are read through their
                        fields by _collect_memory!, which
                        allocates and gathers the DECLARED ARRAYS found there plus the raw
                        pointers. The arrays are asked of Base.mightalias pairwise, so disjoint
                        views inside two wrappers do not overlap; comparing their dataids would
                        find the shared parent and raise. An array built on a pointer (its one
                        Ptr{eltype} field, else its only Ptr field: _data_pointer_field) is placed
                        by _layout — pointer, size and Base.strides, which the TYPE must define;
                        Base strided arrays and range-indexed views of either answer the same
                        way — because mightalias is false for every isbits array and a view names
                        its parent START as its data. _Region describes a vector, a strided
                        vector and a contiguous-column matrix EXACTLY (runs; _regions_meet tests
                        them run by run, so interleaved submatrices pass) and anything
                        else by span. Nothing else of such an array is read (handle, owner
                        vector). With no Base.strides its data pointer is a START: placed only
                        within the allocation it points into, so it is :undecided against any
                        region or other start. A view whose indices are not ranges is placed in
                        its root (_root_place). A raw pointer anywhere else has no known extent:
                        one equal to another pointer or pointing at memory the other argument
                        reaches is :undecided. :undecided warns "may share memory",
                        never gates. A Number in the default `!` position beside an array argument is rejected like a
                        Float64 (a BigFloat scale factor holds memory but is not what is written). Arrays held as elements (`[y, z]`, a Dict)
                        are not followed. An overlap between two arrays GATES; one found only in a field
                        of a non-array argument warns (gates = gates && arrays in _noalias_fail).
                        A written position that holds no memory (_holds_memory: the scalar in
                        axpy!(a, x, y), the function in map!(f, dest, src); a plain-data value
                        with a Ptr in it and a BigInt DO hold memory) raises an ArgumentError
                        — the `!` default would otherwise compare nothing and pass)
  typestability.jl    — @assert_typestable, _typestable_check_expr/_typestable_fast
  inlining.jl         — @assert_inlined, inline_suggestions (module-sweep advisory).
                        _inlined_survives returns `nothing` when it cannot tell (a signature that
                        is not concrete, no single method, no typed wrapper body); both tiers and
                        the macro report that as unevaluated, never as inlined
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
                        finish leaves the finding an ordinary SM0002. The verdict itself follows the
                        scheduler's code to the end, like the package's own (_followed_to_end): how
                        many calls down a wait allocates depends on what Base inlines (yield's queue
                        growth is one Base level deeper on 1.12 than on 1.13, measured), so a fixed
                        depth passed `yield()` on one release and failed it on the other. Scheduler
                        code is matched by file in any module under Base (_method_in_scheduler), so
                        Base.Partr's task queue and Threads' locks count. A scheduler body drops its
                        own boxing itself (_stmt_in_scheduler with `frame`), so that boxing never ends
                        an :alloc walk before the allocation below it (`schedule` boxes before it
                        queues; stopping there passed unlock(l)). A CALLABLE THE SCHEDULER WAS HANDED
                        (the f of lock(f, l)) is its caller's code whoever defined its type
                        (_calls_argument: the callee's function type IS one of the scheduler call's
                        argument types, _handed_params: other than the f a keyword body #f#N is
                        passed as itself, so wait's keyword body calling wait() is not a callable),
                        so its allocation is SM0002 and its boxing counts, inlined or
                        not; a wait it makes is the scheduler's again. Telling an inlined callable's
                        statements from the scheduler's needs debug-info edges, which a compiled body
                        does not keep: _typed_body re-reads such a body with debuginfo = :source
                        (_runs_handed_callable), and without edges every statement counts as the
                        caller's (_unsplit, asked once per body, not per statement). The re-read keeps the scan's answer the same before and after
                        the proof compiles the call (measured to differ without it). An origin below a scheduler call is the
                        scheduler's (_origin_in_scheduler) unless it is in such a callable or the path
                        from it passes through the package's code; _nonscheduler_origin reads a
                        scheduler body for the callable's statements and callees only. The proof's
                        _scheduler_site ends its frame walk the same way: where a non-inlined scheduler
                        frame's next frame calls one of its arguments (by method instance, or for an
                        inlined frame by matching its name against the argument type's methods), and
                        at an inlined frame whose file is not one of Base's image-relative "./" files,
                        which still decides a user closure inside a `lock` that itself inlined.
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
                        effects RAISES on a signature with no typed body, and @assert_effects
                        fails on it: infer_effects over zero matches reports every effect but
                        nothrow.
                        Every one is a PROOF: false means the compiler could not establish the
                        property, NOT that it fails — :noub is false for a non-const global read
                        and for a dynamic call, neither of which is undefined behavior (measured),
                        so a caller may act on true and must treat false as unknown.
                        CAUGHT CONTEXT: a callee :invoked from a try region whose handler can
                        return (_caught_contexts) is scanned with _skip_mask(code, true), the
                        unreachable mask alone, and so is everything below it; _signals_by_type
                        keys seen and _SIGNAL_MEMO on the context, and _signal_origin/_origin_node
                        carry it, so a body has one verdict per context. A context is false, true,
                        or a TYPE T (_join_caught): a handler `err isa T || rethrow()`
                        (_handler_filter, read from the IR pattern the_exception / isa / goto if
                        not / rethrow + unreachable) returns only for a T, and _deadend_mask then
                        keeps a statement alive through it only when the statement may throw (the
                        optimizer's IR_FLAG_NOTHROW is unset) and is not a throw whose types are
                        all known, concrete and no T (_rethrown/_thrown_types, which follow an
                        always-throwing :invoke like throw_boundserror a few levels, and name a bounds-checked
                        memoryrefnew (_bounds_checked_ref: ref/Int/Bool arguments, so only its check
                        can throw) as a BoundsError; the scan also counts such a call that may throw
                        as an allocation where _returns_for(context, BoundsError)). A callee in a
                        T context reads its own throws the same way. StrictModeTest's
                        _body_classes/_caught_sites/_walk_body use the same functions. A callee exempt from
                        :noalloc has its allocation AND its boxing excused in :alloc/:full mode (a
                        box is an allocation); :boxing mode, which :noboxing reads, excuses nothing.
                        What the caller HANDED it and it CALLS is the caller's: _handed_code walks
                        the exempt body and the callees it passes a handed value to (optimized IR,
                        two taint levels: HANDED = an argument or anything loaded from one by
                        getfield/memoryrefget/etc.; HOLDS = a :new the exempt code built around one,
                        so its own do-block closure stays its own code), and returns the :invoke
                        sigs whose FUNCTION is handed, plus inlined callables named by the argument
                        types (inlining edges) and singleton callables folded to constants (matched
                        by type). Each is scanned as the caller's own callee. A value whose type can carry no callable (_callable_types!
                        empty) is not followed, so the Any fields of a lock's Task cost nothing
                        unless something calls them. A handed value reaching a dynamic call or a
                        calling builtin, an unreadable body, or the budget makes the walk
                        incomplete and excuses NOTHING below the exempt callee.
                        ONE RULE says what a walk reads below a callee: _callee_excusal gives
                        :barrier (nothing below is the caller's), :exempt (only the handed-in
                        code is) or :own (an ordinary callee, and an exempt one whose handed-in
                        code was not read in full), and _scan_ci, _signal_origin and
                        _nonscheduler_origin all ask it. The invariant: a body counts for a caller
                        exactly when some path to it enters no :barrier or :exempt callee, in
                        whatever order the walk meets the paths. So the one read made below an
                        excused callee (_excused_signals: the exempt name a caller is pointed to,
                        a registered barrier's boxing or dictionary lookup, the signals an
                        excusal does not cover) marks a COPY of seen and can cut nothing the
                        caller reaches another way. Mode :alloc reads nothing below a barrier:
                        under :noalloc a box is an allocation, so a caller of a registered
                        barrier that boxes passes with no note, as a caller of a once-guard does;
                        the :info note that names the barrier is :noboxing's and :owned's.
                        A WIDER INVOKE is unread: every walk reads a body by the signature that
                        dispatches to it (_typed_body), and `invoke(f, Tuple{wider}, args...)`
                        names a specialization whose signature dispatches to ANOTHER method
                        (_names_other_method). _scan_ci does not follow that callee and marks the
                        result truncated (SM0207), so the call never passes on the strength of the
                        other method's body. The proof reads it (_reach_body, by specialization),
                        which makes this a real cause_diverged case: SM0207 against SM0002.
                        _skip_mask is what a body scan leaves out: _deadend_mask (no path returns
                        under ignore_throw; an EnterNode reaches its catch_dest, and every statement
                        of a try region does too, via _try_handlers, so a throw a returning catch
                        handles is NOT an error path) OR _unreachable_mask (not reached from the entry, where a
                        `goto if not` on `x === x` — one SSA value or argument compared with
                        itself — never jumps). An in-place triangular ldiv! inlines
                        `b === b ? b : copyto!(b, b)`; LLVM folds it, and the dead copy's unalias
                        allocation would otherwise fail a body AllocCheck proves clean. Two
                        DIFFERENT arguments compared keep both sides: identity is a value fact
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
                        target; the vector-type patterns accept `<vscale x N x …>` (SVE/SME).
                        The four PUBLIC reports (kernel_report, register_report, spill_report,
                        scalar_fp_loops) read their text through _report_text, which RAISES
                        _UnanalyzableSignature on an empty one (a signature that is not concrete,
                        or a printer that raised): a report of zeros reads as a clean kernel. The
                        guarantees do not go through it — they turn an empty text into :fail.
                        Spills are counted only where _vec_reg_re knows the vector register
                        names (x86, AArch64); elsewhere _spill_arch_unread makes spill_report
                        raise and :no_spill unevaluated
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
                        boundary inlines and its getfield would surface in an innocent caller.
                        `reinterpret(T, u)` raises like `u.x` (Base's generic reinterpret copies an
                        isbits payload) and the scan reports it; reinterpret/write/unsafe_write
                        (_BYTE_COPIERS) are reported by _untrusted_reach of every operand past the
                        first, so `reinterpret(T, [u])` and `write(io, Ref(u))` are certain reads, and an
                        operand whose type can hold one is a `held` site whose reason names the
                        type (every abstract type can, since any package may subtype it; a concrete
                        type is judged by its fields).
                        Those array/Ref forms, the reshape reinterpret and unsafe_write of a Ref
                        also RAISE at run time (methods on AbstractArray/StridedArray/Ref{<:Untrusted};
                        Base's write(::IO, ::StridedArray) needs its own); Serialization.serialize
                        does not. `show` and `dump` print `<redacted>`.
                        ==, isequal and hash raise (so an Untrusted is no Dict/Set key, and [u] == [v]
                        raises); === is a builtin and, with objectid/IdDict, still reads the bits.
                        A keyword function is judged by its body (_keyword_body: Base.bodyfunction,
                        accepted only when it carries the `#f#N` name of the method's function),
                        followed from the positional and kwcall methods, and a registered
                        boundary's body is the boundary (_is_trust_boundary).
                        A getfield/getproperty handed on with a constant field uses the direct
                        path's field rules (_handed_on_cleared). A Core.tuple holding one whose only
                        uses are _COMPARISONS operands (===, ==, isequal, in, ∉; slot and SSA copies
                        followed) is no read by itself (_only_compared); returned, indexed or passed
                        on, it is a read. A comparison other than the === builtin handing one on is
                        a read unless _compare_applies follows every method it can reach (Base's
                        too, unoptimized IR, the operand tracked through copies, field reads, splats
                        and calls) and none applies it; over 8 methods, 8 calls deep, a method that
                        can return it (tracked as :returns), an unread
                        method or an unfollowed builtin counts as applying it. A read inside a try is kept
                        when its catch can finish without raising (_may_return) or any statement
                        reachable from the handler reads a slot or SSA value the payload flows into
                        between the payload read and the raising field read (copies, field reads
                        of it; an unrelated `n = 0` is not held) (_reaches_use): a handler runs
                        before it rethrows, so a finally that stores the local hands it on.
                        trust_boundary! calls clear_cache!, like every registration a verdict
                        depends on (register_scoped!, register_alloc_barrier!, _exempt!). A
                        read whose result is STORED is the right-hand side of an assignment in
                        unoptimized IR (`_3 = (%1)(_2)`), which _call_callee_and_args unwraps;
                        read as a non-call it passed `b = unsafe_trust(u)`. An erased read of
                        field 1 is dropped when the SAME VALUE also has another field read
                        (_same_value_has_another_field: same operand, no branch, no jump target
                        and no reassignment between the two statements, and when the other field
                        is read SECOND nothing between them that can hand the payload on — a call
                        other than getfield, a foreigncall, a global store — and the payload read
                        not inside a try that catches (_in_try), whose catch swallows the raise —
                        so a read on the other arm of a type test clears nothing), and when the operand is what
                        iterate/indexed_iterate returned. `invoke(f, T, args...)` is read as
                        f(args...), and unsafe_trust as an operand of any call but a comparison is
                        a certain read (comparisons and in/∉ excepted; _handed_on_reads!: an operand whose TYPE carries it, so a
                        Base.Fix2 holding it counts, callee position included). getfield and
                        getproperty handed on the same way count by _untrusted_reach of the call's
                        operands: :certain for an Untrusted or a Tuple/array/Ref of them, :maybe
                        (erased) for an Any, an abstract type or a concrete struct with a field
                        that is not :none — a field is never :certain, since a function applied
                        to the struct reads that field and not the payload. An erased TWO-argument `getproperty` is NOT
                        reported while StrictMode's own method, which raises whatever the name,
                        is the only one an Untrusted reaches; once a package defines a more
                        specific getproperty for one (_untrusted_getproperty_overridden, asked
                        of the method table at each scan; for :trusted the findings cache
                        key carries its answer, since the compiler records no edge from an
                        untyped `p.x` to the new method, and _BODY_MEMO holds IR, not verdicts) an
                        untyped getproperty of ANY name, or of a name known only at run time, is an
                        erased read like the others, since the method picks its result whatever
                        the name; erased getfield and unsafe_trust are reported, and getproperty
                        on a value typed <:Untrusted is certain. The three-argument
                        getproperty(p, :x, order) is Base's and reads the field, so an erased one
                        is reported like getfield, and of any name once a package overrides that
                        arity too
  concurrency.jl      — @assert_concurrency_safe, @assert_no_threadid_state, pool_balance_report.
                        :no_threadid_state is IN _GUARANTEES, so a sweep covers it with no
                        annotation; check.jl clears a signature outright when the compiler proves
                        :notaskstate and runs the taint scan only otherwise. It GATES, because a
                        reported site is a store read from typed IR, not an unprovable inference —
                        its limit is recall, a threadid store in an unfollowable callee.
                        Suspension inside a callee is read by _sig_may_suspend from reach.jl's
                        graph; _inert_op leaves out a _SUSPEND_ON operation on an IOBuffer, an
                        IOContext of one, DevNull or a SpinLock, while its callees are still read.
                        Every later argument whose type meets IO is judged too (_suspends_on_args),
                        because write(to, from::IO) reads and waits on the source.
                        A sweep has nowhere to name WHICH argument is shared, so it reads argument
                        1: a `!` method therefore gets :info (its name declares that write), unless
                        the scan read a write to a constant global, which stays :fail, and an
                        isbits first argument reports nothing (a copy cannot be written through,
                        and seeding it taints every index derived from it, which made a store into
                        the method own fresh buffer read as a shared write). Both measured in the
                        field: 92 of 134 and 755 of 762 sweep failures were `!` methods.
                        The taint scan crosses TWO boundaries the statement loop would otherwise
                        drop: Expr(:new) passes taint to the struct built from a tainted value (an
                        INLINABLE wrapper is caught anyway, since inlining routes the store back
                        through the argument — only a @noinline one needs this), and a
                        :foreigncall to jl_new_task follows the task's closure body via
                        code_typed_by_type with the CLOSURE ITSELF tainted, since a capture reads
                        as getfield(self, …) and _PROJECT_OPS carries it on. Field-insensitive, so
                        a task writing a disjoint slice of a captured output still reports — a
                        partition is a property of values. Anything unresolvable is RECORDED, never
                        skipped. pool_balance_report RAISES _UnanalyzableSignature when it cannot
                        read a signature, because a count of nothing balances.
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
                        THREE ways a write reaches the plan without a store in the frame, each with
                        its own certainty. (1) A BASE callee that was not inlined is read like a
                        package's own when its name ends in `!` or its result can hold a reference
                        into an argument (_may_alias_result), _BASE_EXTRA_DEPTH frames past
                        max_depth; the body decides which argument is written, so a store read
                        there is `certain`. Do NOT replace this with "a Base `!` callee writes
                        whatever plan value it is given": `mul!(out, plan.A, x)` and
                        `copyto!(out, plan.buf)` read the plan, and _BASE_MUTATORS matching at any
                        position failed 19 read-only LinearAlgebra signatures (`A \ b`, `rank(A)`,
                        `cholesky(A)`, through an `unsafe_copyto!` FROM the plan) with a certain
                        record. _mutator_dest names the written position. (2) A :foreigncall
                        follows Go's cgo rule: a C function is assumed to write through every
                        pointer it gets, so it is a record with certain = false — except the ones
                        _FCALL_WRITES names (memmove/memcpy/memset write their destination, which
                        is certain; memcmp and the copying runtime calls write nothing), and
                        _FCALL_ALIASES, whose RESULT is the argument's memory (jl_ptr_to_array_1d
                        behind unsafe_wrap). Only the declared arguments are read, never the GC
                        roots after them. Every BLAS/LAPACK routine is unnamed, so a plan matrix
                        passed to dgemv reports. (3) A lock, condition, event, channel or semaphore
                        carries NO taint (_is_lock_type at a projection, a PiNode, a callee
                        parameter and the seed): what `lock(plan.lk)` writes is the
                        synchronization. A Threads.Atomic DOES carry it, so atomic_add! and
                        `x[] = v` on one (the atomic_pointer intrinsics) are records with certain
                        and deliberate both set, as an @atomic field write is. A constant GLOBAL
                        Threads.Atomic is treated the same (_is_mutable_global counts it as
                        mutable; the address of a global from jl_value_ptr carries `gset`): an
                        atomic write to it is certain and deliberate, so it warns and never
                        raises. A lock or channel global is not data. Global taint
                        crosses an :invoke like plan taint (`gpos` → `gargs` in _recurse, in the
                        memo key): a helper handed the global is read, silently when it cannot
                        be. _ConcViol.global_state marks a record about a global, and when every
                        record is a certain atomic write to one (_only_global_atomics) the
                        headline and the finding say the plan is NOT written. A Base callee
                        entered for its result and NOT READ returns :maybe: the call is an
                        undecided record and the result goes into `mset`, through which a store is
                        an undecided record too, never a certain one (a fresh buffer from a deep
                        `lu` must not raise). The memo keeps each result with its depth and
                        whether the walk was cut beneath it; a cut result answers only a visit at
                        least as deep. A builtin held as the callee VALUE is as read-only as one
                        named through a binding. _recurse_closure_body returns before the depth check for a
                        struct with no call method outside Base — it is data, with no body to read
  strict_function.jl  — @strict_function (load-time enforcement; `signatures = [...]` verifies
                        concrete instantiations a generic declaration cannot name, since such a
                        declaration infers to `Any`), @strict_stable (per-specialization instead:
                        body moves to a hidden `#f#inner`, the wrapper infers its return type via
                        promote_op so a stable specialization folds the branch away entirely),
                        @strict_exempt (a definition, a name, a `begin … end` block, or an
                        `include` whose definitions are found by diffing the census), @strict_policy. A
                        @strict_policy line checks only the methods defined ABOVE it and RAISES
                        when none above it is checked OR ACCOUNTED FOR (`require_methods` in
                        _auto_check_module, _policy_unaccounted: nothing above it, or only
                        undeclared generic methods; a method exempt from EVERY policy guarantee
                        (one exemption or several; `types = (...)` narrowing still
                        counts), one declared with `signatures = [...]`, a constructor, a
                        macro and a callable object's method are all accounted for): written
                        first it would load cleanly over a module it never read. `check = false` does not raise.
                        A callable object WITH FIELDS is never checked at load (no instance —
                        _module_load_items skips it); sweeps and proofs cover it. A singleton
                        callable has an instance and is checked like a function
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
                        (kwsorter name stripping), _kwbody_owner (the keyword body of a constructor
                        or callable object, which Julia names `_`, answers to that callable in
                        _callable_name, _func_name and _method_label: read from the lowered code of
                        the module's kwcall methods, indexed per module and world), and the ITEM
                        BUILDERS both tiers share:
                        _registry_items/_compiled_items/_map_findings/_run_and_report. The
                        reporting drivers _findings_all/_findings_compiled are here too;
                        StrictModeTest's test_registered/test_compiled reuse the same item lists.
                        module_methods is the CENSUS (Base.visit(Core.methodtable) filtered by
                        module, so a method on a FOREIGN function counts); _module_specializations,
                        the one enumerator behind every compiled sweep (audit sweep, test_compiled,
                        inline/dispatch/static-ownership suggestions), sweeps only methods WRITTEN
                        in the module (m.module === mod): the module own functions' methods, then
                        from the census each method it defines on a function another module owns,
                        sweeping that method only, and each callable object's method
                        (not a closure, an anonymous function, a generator or a keyword body of one:
                        _is_closure_type, and _is_inner_function for one with an instance; a
                        <: Function callable no name in the module
                        holds is swept here too, since the name walk skips only what it met), whose specializations it hands on as
                        (_callee(F), types): _Callable{F}() for a type with no instance. The census
                        filters a callable with no instance by its type (a predicate only/exempt
                        receives the type the METHOD declares, rewrapped: Boxed, not Boxed{T} with
                        a free T; a closure is not asked), and _decl_key keys on the
                        callable's TYPE, so a declaration made on an instance stamps those rows; an
                        exemption of such a function excuses only the declaring module's methods
                        (_exempt_in, asked per method by _is_exempt(f, m)). A submodule's or an
                        extension's methods are in the census but only in THAT module's sweep, so
                        a method gets one row, under the exemptions of the module that wrote it;
                        the registered scope (_registry_items modules=, _registered_findings_in,
                        _module_load_items) is the module that WROTE the declared method,
                        _mod_sym(f, types), the module its rows name, not the function's owner;
                        _coverage_all_findings
                        is default-deny over it, _coverage_findings the narrower public-function
                        form; _is_parametric_def keeps a `where` definition out of the registry.
                        _STORES/_store_for memoize each module's store so a reader never touches a
                        binding created in its own world (a Julia 1.12 warning, a later error).
                        declarations()/exemptions() union each loaded package's OWN store with this
                        session's; module_policy/_set_module_policy! back @strict_policy, and
                        _auto_check_module checks _module_load_items — the module's METHODS, so an
                        include'd definition is covered where a body rewrite could not see it
  audit.jl            — audit (the reporting entry point; no exit status, never throws on a
                        VIOLATION — it raises on an invalid argument: an unknown guarantee, a
                        target that is neither :registered nor a Module, an `only` or `exempt`
                        entry that matches no function — and no
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
                        StrictModeTest testitem enumerates _GUARANTEES to pin that shut.
                        The seam itself refuses (SM0203) a signature with no typed body, for
                        every guarantee it answers and in both tiers: with no method, a scan
                        finds nothing and infer_effects reports every effect but nothrow.
                        _ONE_BODY_GUARANTEES (noalloc/noboxing/owned) are also refused on a
                        signature that is not concrete, since the scan reads one of the methods
                        it matches; :typestable is not, its return is inferred over all of them.
                        _always_throws/_mark_always_throws/_gate_always_throws: a signature whose
                        inferred return is Union{} returns on no path, so every guarantee passed
                        on nothing. Each pass becomes an :info SM0208 note in both tiers (a
                        failure stays), which is what a sweep reports — an error helper is not a
                        defect, issue #36. The callers that LIST a signature turn the note into
                        a failure: test_signatures, @test_*, a @verify_strict line, and
                        @strict_function signatures = [...]. test_compiled, test_registered,
                        audit, @strict_policy and a @strict_function on a definition keep the note.
                        findings(sig::Type{<:Tuple}) takes Tuple{F, argtypes...} for a callable
                        object known by its type alone: the engine holds _Callable{F}() (effects.jl)
                        as the callee, and every reader of f goes through _ftype/_sigtype/_which,
                        _return_types/_infer_effects and _print_code_by_type (scheduling.jl), which
                        reach Base by the signature for it. _func_name names a callable by its type
                        WITH its parameters and without its module ("Boxed{Int64}"), so each
                        instantiation has its own key(); only/exempt still match nameof ("Boxed").
                        The cache key carries that type too: one method serves every Boxed{T}
  findings.jl         — StrictFinding struct (carries `tier`: :report vs :proof, `code`, and
                        `policy`: the macro line that required the guarantee),
                        format_findings,
                        nfailures, _failed, key (a finding's identity across runs), findings_diff
  explain.jl          — @explain, StrictReport (built on the value-free engine)
  codes.jl            — the diagnostic codes: _CODES keyed on (guarantee, cause) — NEVER on the
                        reason text, which is assembled per call site — plus explain(code)/codes().
                        A published code is permanent; a retired kind leaves a gap
  cache.jl            — (method, callable type, world, signature, guarantees, depth, and for :trusted whether
                        getproperty on an Untrusted is overridden) → findings cache. Each entry also
                        holds the CodeInstances its verdict was read from (_watch_instances): the
                        key cannot see an edit to a CALLEE, but Julia caps those instances'
                        max_world when one changes, so a stale entry is dropped on lookup. A
                        method with no compiled code has nothing to watch, nor has a verdict that
                        read a spawned task's body (_TASK_BODY_READS in concurrency.jl moved while
                        it was made: no edge leads from the spawner to what the task calls), so
                        such an entry answers only in the world it was made in (_entry_valid). An
                        entry also records length(Base.loaded_modules) and misses once it moves: a
                        package loaded since may hold a store (scoped type, boundary, barrier,
                        exemption) that no registration call announced. The memos under it that
                        outlive a world (_BODY_MEMO, _ESCAPE_MEMO in effects.jl; _SITES_MEMO in
                        StrictModeTest) carry a _ReadStamp and answer through _read_holds: the
                        compiler's record of the specialization must still be valid AND the
                        signature must still dispatch to that specialization. The second is not
                        implied by the first — Julia caps the records of a replaced method's
                        CALLERS and leaves the replaced method's own record at max_world = ∞
                        (measured on 1.12 and 1.13), and a more specific method added later takes
                        a signature over without touching the old record. No memo depends on a
                        Revise callback or on clear_cache!() to follow an edit
                        exempt_strict() is the live session vector, so findings, _alloc_signals
                        and _noalloc_exemptions call _sync_exemptions! (registry.jl): a content
                        hash of it that moved bumps _EXEMPT_GEN and runs clear_cache!();
                        _exempt! and clear_declarations! bump and clear directly
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
                        call. _sw_reach follows :invoke with reach.jl's policy: into callees
                        outside Base (a worker loop is usually a named function), and into a Base
                        callee whose signature names a type defined outside Base
                        (_reach_follows — a closure, or a user value whose show repr runs), or
                        at the CALL-SITE types when a @nospecialize method is handed one and those
                        types select the same method (_reach_same_method). Base is otherwise
                        judged by name and argument types and NOT entered, because yield itself
                        parks through wait. An argument typed abstractly (_reach_open), and an
                        `invoke` of a less specific Base method, are COUNTED as unfollowed.
                        Entering costs 25x on a worker passing user structs to repr/sort!/Dict
                        (1.3 ms -> 33 ms per report, warm), measured.
                        `lock` is not a blocking operation (a SpinLock spins) and take! on an
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
                        A Ptr TYPE counts as `:Ptr` as an operand of ANY call except those that
                        only look at it (_PTR_NAMERS: apply_type, isa, typeassert, <:, sizeof,
                        isbitstype, promote_type, hasintersect, similar, zero, string, print,
                        getfield of the type, cglobal, the ccall glue cconvert/unsafe_convert —
                        cconvert(Ptr{T}, addr) returns the integer, measured — the one-operand
                        getindex of `Ptr{T}[]`, and a tuple of nothing but types, a signature),
                        since lowered code cannot tell ntuple, Generator, a splat or a tuple
                        holding a value from a namer. `C_NULL + addr` (+/- with a pointer
                        constant) is :Ptr, and so is an OFFSET on a pointer argument (p + 8,
                        8 + p, p - 1, add_ptr/sub_ptr), and p - q of two pointer arguments is
                        :ptr_difference, the pointer operands read from m.sig
                        (_ptr_arg_slots): reading it from typed IR cost ~5x the whole Base scan
                        (measured), so an offset on a Ptr LOCAL is missed.
                        It reads the census's constructors, closures and unnamed callables too
                        (module_methods' `keep`): the census skips them because no declaration
                        names them, which says nothing about their code.
                        A function counts wherever the method NAMES it, since lowering gives a
                        global its own statement and the call that receives it may be map,
                        broadcasted, Core.kwcall or Core._apply_iterate: _scan_unsafe! judges each
                        name at its uses (callee, argument, stored local, returned value) and
                        skips a comparison, so `f === unsafe_load` is clean. _UNSAFE_NAMES adds the
                        intrinsics (pointerref, pointerset, llvmcall, cglobal); _UNSAFE_LIBC is
                        matched by IDENTITY, because a package may define its own `free`; :Ptr is a
                        call of a Ptr type or a reinterpret to one (Ptr{T} is apply_type in a
                        statement of its own, which _lowered_callee resolves to the type being
                        parameterized), and so is convert to one, whatever is converted, since
                        lowered code carries no types — a Ptr argument or annotation is not; a
                        local assigned ONCE is followed to its value (_single_assignment:
                        `B = Base; B.unsafe_load(p)`, `T = Ptr{Float64}; T(a)`), and the module
                        operand of `M.name` to EVERY module it can hold (_lowered_modules: each
                        assignment of a local assigned more than once, through the convert/
                        typeassert of a typed local); a module global
                        read by a run-time name cannot be resolved and is reported as
                        :dynamic_global (_dynamic_global_read: getglobal always, getproperty and
                        getfield only when the first operand can be a Module); code evaluated at
                        run time (Core.eval, Base.eval, include_string, include, and any
                        Core.EvalInto/Base.IncludeInto — a module's own eval/include) is :eval,
                        named as a callee or as a value, for the same reason; a
                        name read through a module (`f = Base.unsafe_load`, getglobal(Base, …)) is
                        resolved by _lowered_global_read, as a statement or as a stored value; :cfunction is a
                        statement head; a memoryref builtin or getfield with a literal `false`
                        bounds check is reported under its name. _check_allow RAISES on an `allow`
                        entry that is no construct; a misspelling that still begins with
                        `unsafe_` cannot be told from a real name and is accepted
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
                        positional method are one function. Reuses spinwait.jl's task-closure
                        reading. A Base callee is entered when its signature names a type defined
                        outside Base (_reach_carries_user: a handed closure, or a user array whose
                        getindex `sum` calls); one on concrete Base types is neither entered nor
                        counted. One with an ABSTRACT argument type (_reach_open: Any,
                        AbstractVector{Float64}, Vararg{Any}; type parameters at EVERY depth, so
                        Vector{Any}, Dict{Symbol,Any} and Vector{Vector{Any}} are open too, since
                        sum of a Vector{Any} runs the + of what it holds; a non-type parameter such
                        as Val{:a} or an array's rank is not judged; spinwait.jl and
                        concurrency.jl's _sig_may_suspend share this) is not entered but counts as
                        dynamic, whether reached by :invoke,
                        an enumerated dispatch or an unenumerable one: a user value may arrive
                        there. An :invoke is judged by its CALL-SITE argument types, since a
                        @nospecialize method instance (print_to_string, Vararg{Any}) is wider than
                        what an error-message interpolation of an Int passes.
                        _reach_argtype reads a compilerbarrier (and a π of one) as its operand, and
                        a @nospecialize Base :invoke handed a user type is ENTERED at the call-site
                        types when they select the same method (_reach_same_method) — the default
                        show of a struct is reached that way. One the site types do NOT select (an
                        explicit invoke of a less specific method) is counted as dynamic. _reach(…; quiet) leaves a callee
                        signature out of `found` while still following it.
                        So a route that computes with fetch(t) (inferred Any) is incomplete. A run-time dispatch is followed
                        when it matches at most _REACH_MAX_METHODS methods. `stop` cuts a hub (a pool
                        dispatcher reaches every job).
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
  StrictModeReviseExt.jl    — watch()/unwatch(): re-check declarations() after each Revise edit and
                              print what fails. It clears no cache; the caches follow an edit on
                              their own (see cache.jl)
  StrictModeMcaExt.jl       — llvm-mca CLI glue for mca_report (weak dep, `using LLVM_full_jll`,
                              ~680MiB — never a test/CI default, see test/mca_test.jl's live-path guard)
StrictModeTest/       — the PROOF tier, a SEPARATE package, sibling subfolder, test-environment only
  src/StrictModeTest.jl — module root; AllocCheck/JET/TrimCheck as HARD deps. __init__ REFUSES to
                        load unless StrictMode.checks_enabled() (otherwise every @assert_* is a
                        bare call, nothing registers, and test_registered() sweeps an empty
                        registry and passes), then announces the proof tier.
  src/proofs.jl       — _raw_allocs/_is_boxing/_checked_allocs (AllocCheck), _raw_allocs warns that
                        unattributed sites may be the guard's only when a site of the guard frame was
                        dropped (_guard_unattributed): a wait has unattributed sites and no guard. A
                        callable object known
                        by its type alone (StrictMode._Callable) is proved through _check_allocs
                        (AllocCheck on StrictMode._call_through, the wrapper frame then dropped
                        from every backtrace: same sites as an instance), _jet_target (JET by the
                        signature) and StrictMode._base_return_types; _exempt_split (the sites
                        inside functions exempt from :noalloc are set aside FIRST, as the scan
                        sets them aside, and the call's own sites pick the code: own sites that
                        all wait are SM0017, any other own site is SM0002, with allow_exempt or
                        without; a call with no site of its own and
                        whose EVERY allocation site has a frame whose method is exempt from
                        :noalloc is its own result: SM0018, with StrictFinding.exempt_by listing
                        each exempt function and its reason. Its status is :fail FROM THE PROOF,
                        so every reader of _failed/nfailures/status sees it as not passed with
                        no gate in between (alloc_entry_report, proof_findings, proof_audit,
                        the Revise watcher); `allow_exempt = true` is threaded into
                        _proof_findings and makes it :info. divergence_report reads it beside the
                        scan own exempt note as agreement. A site is the exempt function's only
                        if no frame between it and the allocation belongs to a handed-in call the
                        exempt code makes (_runs_handed_in reads StrictMode._handed_code on the
                        exempt frame's signature, matched on the callee type for a frame with a
                        specialization, on its method names for an inlined one; an incomplete
                        reading makes every site below the frame the caller's, as in the scan);
                        otherwise an exempt wrapper would launder its caller's closure. A site
                        with NO exempt frame (a backtrace ended at "multiple call sites") is the
                        exempt function's when the call reaches its specialization only through
                        an exempt callee with a complete reading and not through the handed code
                        (_only_through_exempt, over the same :invoke graph as the barrier filter).
                        Any other site without an exempt frame, or an exempt
                        callee that was inlined and so has no frame, is a plain failure; the match
                        is StrictMode._mi_exemption, on the method module and name, with
                        declared_in_module = true: an exemption declared with NO module covers
                        by name everywhere, names no method, and excuses no proof site, though
                        the scan still notes it), _opt_reports (JET,
                        wrapped in AnalysisError). _checked_allocs drops a barrier's sites: a
                        backtrace through the barrier, or a function
                        reached ONLY through a barrier (_only_through_barrier, over the :invoke
                        graph of optimized IR — a helper called from several places is compiled
                        once and its backtrace ends at "multiple call sites"). Each edge of that
                        graph (_invoke_reach) leads to the specialization AllocCheck compiles, the
                        one for the argument types inferred at the statement (_compiled_callee),
                        not to the compilation signature Julia's :invoke names: a site's
                        specialization is otherwise in no set and a guarded helper that builds a
                        string fails (print_to_string(::String, ::Vararg{Any}) on 1.13). An edge
                        whose specialization cannot be determined makes the graph incomplete. A
                        site is taken from the call only when the graph names its specialization
                        inside the excused callee; a graph that cannot
                        be read in full keeps the site. The filter runs on every site, from
                        either AllocCheck run, whenever the call reaches a barrier; only when it
                        leaves NO site and the scan finds alloc/boxing/abscontainer is the
                        unfiltered list returned (never more permissive than the scan). _is_boxing drops a DynamicDispatch that is a C
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
                        CAUGHT THROWS: AllocCheck's ignore_throw drops every site leading to a throw,
                        caught or not, and every site a catch reaches. When the walk read a statement
                        a caught throw reaches on a call that returns (_caught_mask: a try region
                        whose handler can return, or that handler, which the walk enters and
                        _catch_only_mask finds, or a callee read in a caught context: _walk_body
                        keeps those in _WALK_CAUGHT_MEMO and skips nothing), _check_allocs runs AllocCheck again
                        with ignore_throw = false and _caught_sites keeps the extra sites whose
                        frame groups (one per compiled body) include a TRY-REGION one with no dead
                        group OUTSIDE it (groups inside it are a callee the try body called), or a
                        HANDLER-statement one with no dead group anywhere (a callee the handler
                        calls is outside the try, so its own throw is an error path). A try-region
                        group whose handlers return only for a type (_handler_filter) does not end
                        the walk: the groups inside it are classified in that caught context
                        (_body_classes(interp, mi, ctx)), and a dead one drops the site. In a type's
                        context a jl_bounds_error* call, and the MemoryRef box reported at the same
                        frames where the statements there are a memoryrefnew of that type plus
                        allocation-free ones (_bounds_error_site/_quiet_stmt), is a BoundsError
                        throw and is dropped when the type does not cover it — on 1.12 under
                        --check-bounds=yes codegen checks memoryrefnew even where the IR marks it
                        unchecked. Groups are
                        matched to statements by the inlining lines of Base.IRShow.buildLineInfoNode
                        (a raw getdebugidx line can index a further line table) and, for a group
                        that called a callee, by the :invoke of that callee: a try-body call and a
                        handler call on one line have the same lines. The second
                        run is the cost: ~20 s on a @strict-guarded signature, measured.
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
                        omitted — omitting it is what makes a suite read as covered. A positional
                        entry whose proof returned only a note is NOT :pass: SM0208 (always
                        throws) is :unproven, an accepted SM0018 is :info. The kwcall
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
                        which is why it lives here). `diverged` is pass-vs-fail and is all isempty
                        reads; `cause_diverged` is both-fail with different codes (SM0017 vs SM0002)
  test/               — its own suite, @testitem/TestItemRunner like StrictMode's: runtests.jl is
                        the runner, fixtures.jl the shared @testmodule, then one file per concern
                        (proofs/macros/drivers/trim/typestable/divergence). Covers the proof
                        primitives StrictMode cannot test, because StrictMode does not depend on
                        those packages at all.
                        corpus_test.jl is the :noalloc CORPUS: 590 generated modules (wrapper ×
                        reach × repeat × compiled-for-one-or-several × effect), each with the
                        verdict and code EXPECTED of the scan, the proof, the proof under
                        allow_exempt and divergence_report, computed from the documented rules
                        alone (`expected`) and never from an engine. A change to an excusal rule
                        is made in `expected` first; a new way of reaching or guarding code is a
                        new part of the generator, not one more hand-written fixture
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
- **A name an entry point does not know raises, naming it and the accepted ones.** Every macro that
  takes `key = value` options parses them through `_macro_call(name, args, allowed)` (macros.jl),
  which throws at EXPANSION on a key outside `allowed`; taken for a positional argument, the key would be
  reported as a malformed call, or one definition too many, and never as the option. A macro with a fixed argument
  list (`@assert_reaches`, `@test_reaches`, `@strict_stable`) has a varargs method that ends in
  `_reject_options`. An option a macro has dropped goes in `hidden`, so it is parsed, rejected with
  its own message, and not listed. A function keyword is left to Julia: no public function takes
  `kwargs...` without forwarding to explicit keywords, so an unknown one is a `MethodError` naming
  it. Guarantee names are checked BEFORE a sweep (`_audit`, `_compiled_items`, `_registry_items`,
  `test_signatures`): a module with nothing compiled reaches no per-method check, so
  `audit(M; guarantees = (:noaloc,))` would otherwise return zero findings. An `only` or `exempt` entry that
  matches no function with a method in the module raises in `_check_name_filters`, which
  `module_methods`, `_module_specializations` and `_coverage_findings` call first (the names are
  the census's: demangled, so a keyword body and a closure answer to the function that wrote
  them); a `stop` entry raises in `reach_report` when the walk never met it AND no reached body names
  it before optimization (`_reach_named_unoptimized`: a call the optimizer folded away leaves no
  statement and no inlining edge, and a `stop` list must not depend on that; a function
  HANDED to any callee, Base included, counts as named and its methods are read, via
  `_reach_handed!`, which is what finds a hub called from a closure, a `do` block, a generator, a
  broadcast, a keyword call or a splat), and in
  `route_parity` only when NEITHER route met it. A preference key StrictMode does not read WARNS at load
  (`_warn_unknown_preferences`, called from `__init__`, so it scans the preference files by bytes
  and is pinned trim-clean in `StrictModeTest/test/trim_test.jl`); it is NOT gated on the
  `banner` preference, which hides the tier banner alone: a misspelled `banner` is what the
  warning is for.
  `test/options_test.jl` holds the list of macros and their accepted options, and fails when a
  macro gains one without it
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
- **The same holds for every registration a verdict depends on.** `trust_boundary!`,
  `register_scoped!` and `register_alloc_barrier!` each push onto a constant in the root module of the
  package that owns the function or type (`__strict_trust_boundaries__`, `__strict_scoped_types__`,
  `__strict_barriers__`), and the readers (`_is_trust_boundary`, `_scoped_types`,
  `_barrier_functions`) union the loaded packages' stores with this session's set. A set inside
  StrictMode alone is lost at a cached load: `:trusted` then fails on the registered boundary itself
  and `:noescape` passes with no type registered. The first two write the constant ONLY while a package image is
  being generated (`_keep_registration!`): in a session the session's set is the registration, and
  a test that empties it to take a registration back must not find it again in `Main`. During a
  precompile `_persist_registration!` decides, the same for all three: only a store THIS PROCESS
  CREATED (`_STORES_CREATED`) is written with the image, because only the package being
  precompiled has an open module. A store that was already there belongs to a package loaded
  from its own cache, and pushing onto it is silent loss, so that case RAISES and asks for
  `mod = @__MODULE__` (`_registration_lost`), as does a module that cannot take the constant at
  all. Two exceptions, both a session registration that never raises. A call from a module's own
  initializer (`_called_from_init`: the zero-argument `__init__` of the module that defines it, not
  any frame of that name): a dependency's `__init__` runs while its dependent precompiles, with
  the dependency's module closed, and it runs again at every load. And a call made by the OWNING
  package's own code (`_registered_by_owner`: the first stack frame outside StrictMode and Base
  runs a method of that package, or, when it has no method — an inlined call or top-level code —
  its file lies in the directory of the package's own source file. Not the package directory: an
  extension in `ext/` or a package nested under it is another package): a table a package
  registers on first use, first used by a dependent's precompile workload, must not break that
  precompile.
  `jl_generating_output() == 1` alone does not say whose code is running. A callable object
  belongs to the module of its type (`_owner_module`). A TRUST BOUNDARY is registered by value
  (`findings(f, types)` has the value). An ALLOC BARRIER is registered as its TYPE and covers every
  instance (`_barrier_covers`: `p <: T`, which `Type{T}`, a constructor call, is not): the scan
  meets it as the callee type of an :invoke and has no value, so `register_alloc_barrier!` RAISES
  on an instance of a non-singleton type rather than silently excuse the others.
  `test/consumer/dependents.jl` builds three packages and pins each case from their caches.
- **Certainty decides throw-vs-warn, and it can be per FINDING, not only per guarantee.** StrictMode
  throws only where it is 100% sure and warns where its verdict is a heuristic; StrictModeTest throws
  by definition, because AllocCheck/JET/TrimCheck are full machinery rather than a scan. `_fail`
  takes a `gates` keyword for exactly this, so one guarantee can do both: `_ConcViol` carries
  `certain`, set at the record sites where the scan READ a write (a store, a named
  `_BASE_MUTATORS` callee with the plan at its written position, or a `memmove`-class foreign
  function with the plan at its destination) and left `false` at every "flagged conservatively" or
  "not read" site, a foreign function with no known effect among them, and
  `_assert_concurrency_safe` raises only when `any(v -> v.certain, vs)`. Its message and the sweep's
  finding list the records by `_conc_groups`: writes the scan read first, marked `[write n]`, then
  atomic ones, then `[undecided n]`; a report of 77 sites in which two are proved is otherwise
  unusable. `typestability.jl` and
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
- **A signature that always throws is not a pass.** Its inferred return is `Union{}`, and with the
  throw paths set aside nothing is left for a guarantee to read: `bad(x::Int) = x + "a"`, a call
  that leaves out a required keyword argument, and a loop that never returns all have nothing on
  a returning path for `(:typestable, :noalloc, :noboxing, :trim_compatible)` to check. The verdict is the
  SM0208 note, `:info` in a sweep and `:fail` where the signature was listed (see check.jl in the
  map). An `@assert_*` or `@test_*` macro performs its call, so there the call's own error is raised
  and no verdict is given.
- **A finding the analysis could not evaluate is `:fail`**, carrying the error text (`_unevaluated`
  in check.jl, `_errored_findings` in registry.jl). Never `:pass`: "could not check" and "is fine"
  rendering the same is how a crashed backend reported success for every method in a sweep. Tests
  should assert `StrictMode._failed(f)` rather than `f.status === :fail`, which pins a symbol
  instead of the intent.
- `_demangle(sym)` in `registry.jl` strips `#foo#NN` kwsorter mangling so `only`/`exempt` match keyword-argument functions correctly. A keyword body Julia names `_` (a constructor's or a callable object's) is named by `_kwbody_owner` instead, after the callable it implements.
- `ignore_throw() = true` is the default and lives in StrictMode (`effects.jl`) — throw-path allocations don't count, and BOTH tiers honor it, so the scan and AllocCheck answer the same question.
- **A compiled-output guarantee reads compiled output or fails.** `_llvm_ir`/`_native_asm` return
  `""` when the printer raises AND for a signature that is not concrete: `code_llvm` prints the
  method compiled for the abstract types, not the code a concrete call runs (for
  `sum(::AbstractVector{Float64})`, one run-time dispatch and no loop or spill), which every loop and
  register check would read as clean. `:vectorized`, `:no_scalar_loops`,
  `:no_spill` and `:inlined` turn an empty text (or `nothing` from `_inlined_survives`) into
  `_unevaluated`, in `_compiled_output_finding` and in the `@assert_*` macros alike. The public
  reports (`spill_report`, `scalar_fp_loops`, `kernel_report`, `register_report`) raise
  `_UnanalyzableSignature` for it, through `_report_text`. The same rule elsewhere: `_unsafe_constructs` returns `nothing` for a
  method it could not read and `unsafe_report` fails it (SM0203); the concurrency scan records a
  plan value handed to a callee whose typed IR it cannot read (a callable struct with fields).
- `kernel_report` and `@assert_vectorized` work from `InteractiveUtils.code_llvm` — no backend needed. `_CACHE_BYTES` is a tunable `Ref` for cache-residency annotation thresholds.

## FEEDBACK.md

Documents dogfooding findings (F1–F74 as of this writing — check the file's own status table for
the current count, it moves faster than this file) from the PureFFT.jl and BlazingPorts.jl/QR
campaigns. Most findings are ✅ closed; a few are 🔴 open by design (e.g. F29/F30 — necessary-but-
not-sufficient axes `kernel_report`/the guarantees don't yet cover: data-dependent load latency,
scalar-gather transpose cost). Update the status table when closing or opening a finding — don't
trust "all ✅" without checking, it has been wrong before.
