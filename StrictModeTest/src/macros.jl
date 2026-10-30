# The companion macros. `StrictMode.@assert_noalloc` names a value-free scan that reports;
# `StrictModeTest.@test_noalloc` names the AllocCheck proof of the same property, and it gates.
# Which engine a call site uses is decided by which macro you wrote — there is no mode to switch
# and no ambient state to read.
#
# These are deliberately NOT wrapped in `StrictMode._gate`: a gate that compiles itself away under
# a preference is a gate that can vanish silently. `__init__` refuses to load with checks disabled,
# so the question does not arise.

# Prove `guarantees` and raise if any fails. `kind` names the macro in the exception, so a
# composite reports as `@strict`/`@kernel` rather than as whichever of its parts failed first.
function _test_guarantee(kind::Symbol, guarantees::Tuple, target, @nospecialize(f), @nospecialize(types::Tuple))
    fs = _proof_findings(f, types, guarantees)
    failed = filter(StrictMode._failed, fs)
    isempty(failed) && return nothing
    msg = sprint(io -> StrictMode.format_findings(io, failed; format = :text))
    throw(StrictMode.StrictViolation(kind, target, msg))
end

# Shared expansion for every `@test_*`: evaluate each argument once, run the call for its value,
# prove the guarantees, hand the value back. One `_proof_findings` call covers a composite, so
# `@test_kernel` runs AllocCheck once rather than once per bundled guarantee.
function _test_macro_expr(kind::Symbol, guarantees::Tuple, macroname::String, args)
    pos, opts = StrictMode._macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("$macroname needs a call expression"))
    call = pos[1]
    target = string(call)
    p = StrictMode._call_parts(call; types = get(opts, :types, nothing))
    return quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_test_guarantee)($(QuoteNode(kind)), $guarantees, $target, $(p.checkfn), $(p.types))
        _val
    end
end

"""
    @test_noalloc f(args...)
    @test_noalloc f(args...) types=(T1, T2, …)

Fail unless AllocCheck can **prove** `f(args...)` allocates nothing on any path.

This is the authoritative counterpart to [`StrictMode.@assert_noalloc`](@ref), which reads typed IR
and only reports. A violation here throws a `StrictMode.StrictViolation`, so it is what a test suite
or a CI gate should use. Each argument is evaluated once and the macro returns the call's value.

Allocations on never-taken throw branches are ignored by default — see [`StrictMode.set_ignore_throw!`](@ref) —
as is a call whose only allocation is a recognized one-time-init barrier
(see [`set_ignore_barrier!`](@ref)).

```julia
@test_noalloc dot3(a, b)              # ok
@test_noalloc grows_a_vector(1000)    # throws StrictViolation listing the allocation sites
```
"""
macro test_noalloc(args...)
    return _test_macro_expr(:noalloc, (:noalloc,), "@test_noalloc", args)
end

"""
    @test_noboxing f(args...)

Fail unless AllocCheck proves `f(args...)` performs no boxing or dynamic dispatch, while
**allowing** legitimate typed heap allocations (a `Vector`, a `Memory`, …). The proving counterpart
to [`StrictMode.@assert_noboxing`](@ref).

```julia
@test_noboxing fill_buffer!(buf, xs)        # ok: allocates a buffer, but no boxing
@test_noboxing sum_runtime_index(htuple)    # throws: jl_get_nth_field_checked (tuple boxing)
```
"""
macro test_noboxing(args...)
    return _test_macro_expr(:noboxing, (:noboxing,), "@test_noboxing", args)
end

"""
    @test_typestable f(args...)

Fail unless `f(args...)` is type stable: the inferred return type is a single concrete type (or a
small isbits `Union`), **and** JET's optimization analysis reports nothing.

[`StrictMode.@assert_typestable`](@ref) throws on the return-type layer too — that half is exact —
but substitutes an IR boxing signal for JET, and only warns on it. This macro is the proof of that
second layer.

```julia
@test_typestable muladd(2.0, 3.0, 1.0)          # ok
@test_typestable pick(heterogeneous_tuple, i)   # throws: Union from runtime tuple index
```
"""
macro test_typestable(args...)
    return _test_macro_expr(:typestable, (:typestable,), "@test_typestable", args)
end

"""
    @test_trim_compatible f(args...)

Fail unless juliac's own `verify_typeinf_trim` verifier accepts `f(args...)` for a
`--trim=safe` build. The authoritative counterpart to
[`StrictMode.@assert_trim_compatible`](@ref)'s static scan, and unlike that scan it covers
reachability-limit union-splits.

```julia
@test_trim_compatible entrypoint(argv)
```
"""
macro test_trim_compatible(args...)
    return _test_macro_expr(:trim_compatible, (:trim_compatible,), "@test_trim_compatible", args)
end

"""
    @test_strict f(args...)

Fail unless `f(args...)` is both type stable and allocation-free — the proving counterpart of
[`StrictMode.@strict`](@ref) for type stability and allocation-freedom; the owned-scratch check
@strict also runs has no proving counterpart.

```julia
@test_strict kernel!(C, A, B)
```
"""
macro test_strict(args...)
    return _test_macro_expr(:strict, (:typestable, :noalloc), "@test_strict", args)
end

"""
    @test_kernel f(args...)

Fail unless `f(args...)` is type stable, allocation-free **and** vectorized — the proving
counterpart of [`StrictMode.@kernel`](@ref). `:vectorized` is a best-effort LLVM-IR scan in both
tiers (it observes compiled output, so it already gated); what this adds over `@kernel` is
AllocCheck's proof for the allocation half and JET's for the stability half.

```julia
@test_kernel axpy!(y, a, x)
```
"""
macro test_kernel(args...)
    return _test_macro_expr(:kernel, (:typestable, :noalloc, :vectorized), "@test_kernel", args)
end

# --- the measured steady state --------------------------------------------------------------

# Allocation that stops after a bounded number of calls is not a property of the code: a pool that
# grows to a high-water mark allocates again whenever the mark moves, so an all-paths proof must
# report the growth path forever and `:noalloc` can never pass. The claim such code really makes is
# about the CALL SEQUENCE — "warm it, and from then on it allocates nothing" — and that is settled
# by measuring, not by inference. So this is a value-based check like `memsafe_report`, deliberately
# outside the value-free `findings`/`audit` pipeline.
function _check_steady_state(
        kind::Symbol, target, @nospecialize(thunk), warmups::Int, repeats::Int, fresh_task::Bool
    )
    warmups >= 1 || throw(ArgumentError("$kind: warmups must be at least 1, got $warmups"))
    repeats >= 1 || throw(ArgumentError("$kind: repeats must be at least 1, got $repeats"))
    for _ in 1:warmups
        thunk()
    end
    # A per-task initializer is alloc-free only for the task that already paid for it, so measuring
    # on the warming task would pass it. Measuring on a fresh one asks the question the caller
    # means: does a NEW caller allocate?
    measure() = @allocated thunk()
    bytes = if fresh_task
        t = Task(() -> measure())
        schedule(t)
        fetch(t)
    else
        measure()
    end
    for _ in 2:repeats
        b = fresh_task ? fetch(schedule(Task(() -> measure()))) : measure()
        bytes = max(bytes, b)
    end
    iszero(bytes) && return nothing
    throw(
        StrictMode.StrictViolation(
            kind, target,
            "allocated $bytes byte(s) after $warmups warmup call(s)" *
                (fresh_task ? ", measured on a fresh task" : "") *
                ".\n  This is a MEASUREMENT of the calls that ran, not a proof over every path: " *
                "it says the warmed call allocates nothing, and says nothing about an argument " *
                "shape it was not given.\n  A pool that is still growing needs more warmups; one " *
                "that allocates per task fails here with `fresh_task = true` and passes without it."
        )
    )
end

"""
    @test_steady_state f(args...)
    @test_steady_state f(args...) warmups = 3 repeats = 2 fresh_task = true

Fail unless `f(args...)` allocates **nothing once warmed**: the call is made `warmups` times, then
measured, and anything above zero bytes raises a `StrictMode.StrictViolation`.

This is the check for code [`@test_noalloc`](@ref) can never pass and should not: a workspace pool
that allocates whenever it grows to a new high-water mark, an arena that folds slabs, any buffer
that reaches a steady state after a bounded number of calls. `:noalloc` asks whether allocation is
*possible on any path*, and for such code it always is, so an all-paths proof must report the growth
path forever. The property the code actually has is about the **call sequence** — warm it and it
stops allocating — which is settled by measuring.

So this is a measurement, and the distinction matters when you read a pass:

- It covers **the calls that ran**, not every path. It says nothing about an argument shape it was
  not given, where `@test_noalloc` would have.
- It is the counterpart to an exemption, not a replacement for one. Mark the function
  `@strict_exempt :noalloc reason = "…"` so the allocation is excused where a reader can see it,
  then assert the real property here.

`fresh_task = true` measures on a newly scheduled task. Use it to tell a **pool** from a **per-task
initializer**: a pool that has reached its high-water mark allocates nothing for any caller and
passes either way, while a `OncePerTask` accessor passes on the warming task and fails on a fresh
one, because every new task pays again. That is the difference between "bounded" and "once per
task", and it is only visible by choosing which task does the measuring.

`repeats` measures more than once and keeps the largest, for a pool whose growth is uneven.

```julia
ws = Workspace()
@test_steady_state solve!(ws, A, b)                      # warmed, then zero
@test_steady_state scratch(ws) fresh_task = true         # fails if it is per-task
```

Each argument is evaluated once, before the warmup calls, so the same values are reused throughout.
"""
macro test_steady_state(args...)
    pos, opts = StrictMode._macro_call(args, (:warmups, :repeats, :fresh_task))
    isempty(pos) && throw(ArgumentError("@test_steady_state needs a call expression"))
    call = pos[1]
    p = StrictMode._call_parts(call)
    return quote
        $(p.binds...)
        $(_check_steady_state)(
            :test_steady_state, $(string(call)), $(p.thunk),
            $(esc(get(opts, :warmups, 2))), $(esc(get(opts, :repeats, 1))),
            $(esc(get(opts, :fresh_task, false)))
        )
        $(p.litcall)
    end
end

# A pause budget is a measurement, so it belongs in the gating tier beside `@test_steady_state`
# rather than at a `src` call site. It needs no analysis backend: the question is what the process
# did while the call ran, and only running it answers that.
function _check_gc_quiet(
        kind::Symbol, target, @nospecialize(thunk), samples::Int, warmups::Int,
        max_collections::Int, max_q99_ms, slow_factor::Real
    )
    max_collections >= 0 ||
        throw(ArgumentError("$kind: max_collections must be at least 0, got $max_collections"))
    r = StrictMode.gc_quiet_report(thunk; samples, warmups, slow_factor)
    over_q99 = !isnothing(max_q99_ms) && r.q99_ns > max_q99_ms * 1.0e6
    r.collections <= max_collections && !over_q99 && return r
    why = if over_q99 && r.collections > max_collections
        "q99 was $(StrictMode._ms(r.q99_ns)) ms against a budget of $max_q99_ms ms, and " *
            "$(r.collections) collection(s) ran against a budget of $max_collections"
    elseif over_q99
        "q99 was $(StrictMode._ms(r.q99_ns)) ms against a budget of $max_q99_ms ms"
    else
        "$(r.collections) collection(s) ran during $samples call(s), against a budget of " *
            "$max_collections"
    end
    throw(
        StrictMode.StrictViolation(
            kind, target,
            why * ".\n  per call: median $(StrictMode._ms(r.median_ns)) ms, q99 " *
                "$(StrictMode._ms(r.q99_ns)) ms, max $(StrictMode._ms(r.max_ns)) ms; " *
                "$(StrictMode._ms(r.gc_ns)) ms of collector time.\n  Julia's collector stops " *
                "every thread at its next safepoint, so a pause here may have been triggered by " *
                "code this call does not reach — an allocation-free kernel is paused by an " *
                "allocating neighbor. Find that allocation; a collector setting moves the pause " *
                "rather than removing it.\n  This is a MEASUREMENT of the calls that ran in this " *
                "process, not a proof: it cannot cover a thread that stayed idle during the window."
        )
    )
end

"""
    @test_gc_quiet f(args...)
    @test_gc_quiet f(args...) samples = 1000 max_collections = 0 max_q99_ms = 1.0

Fail unless no garbage collection runs while `f(args...)` does.

This gates the axis the allocation proofs do not cover. [`@test_noalloc`](@ref) proves that *this*
call allocates nothing, and that is necessary without being sufficient: Julia's collector stops the
world, so a thread that allocates pauses an allocation-free kernel at its next safepoint. No
analysis of the kernel can see the cause, because the cause is not in the kernel.

Measured, not proven. The call is warmed, then run `samples` times, and the collector's own
counters say whether a collection landed inside a call. `max_collections = 0` is the default
because that is what "quiet" means; raise it for a process you know is doing other work.

`max_q99_ms` adds a latency budget on top: the 99th-percentile call must come in under it. Leave it
unset and only the collection count is gated, which is the deterministic half — a wall-clock
threshold depends on the machine, so state it only where you know the machine.

```julia
@test_gc_quiet gemm!(C, A, B)                                   # no collection in the window
@test_gc_quiet gemm!(C, A, B) samples = 2000 max_q99_ms = 1.0   # and a tail-latency budget
```

A failure names the budget it missed and reports the distribution, because the number you need in
order to act — how long the worst calls took — is not in the verdict. For the non-gating form, and
for the full report at the REPL, use [`StrictMode.gc_quiet_report`](@ref).

Each argument is evaluated once, before the warmup calls, so the same values are reused throughout.
"""
macro test_gc_quiet(args...)
    pos, opts = StrictMode._macro_call(
        args, (:samples, :warmups, :max_collections, :max_q99_ms, :slow_factor)
    )
    isempty(pos) && throw(ArgumentError("@test_gc_quiet needs a call expression"))
    call = pos[1]
    p = StrictMode._call_parts(call)
    return quote
        $(p.binds...)
        $(_check_gc_quiet)(
            :test_gc_quiet, $(string(call)), $(p.thunk),
            $(esc(get(opts, :samples, 100))), $(esc(get(opts, :warmups, 2))),
            $(esc(get(opts, :max_collections, 0))), $(esc(get(opts, :max_q99_ms, nothing))),
            $(esc(get(opts, :slow_factor, 2.0)))
        )
        $(p.litcall)
    end
end
