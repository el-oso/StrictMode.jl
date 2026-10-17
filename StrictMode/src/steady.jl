# Allocation that stops after a bounded number of calls is not a property of the code: a pool that
# grows to a high-water mark allocates again whenever the mark moves, so `:noalloc` can never pass
# and should not. The claim such code makes is about the CALL SEQUENCE — warm it, and from then on
# it allocates nothing — which is settled by measuring.
#
# That needs real argument values and has to run the call, so it cannot live in the value-free
# `findings`/`audit` pipeline or at a `src` call site. It is the same species as `memsafe_report`
# and `mca_report`: a value-taking function that measures and reports. The gating form is
# `StrictModeTest.@test_steady_state`, which raises; this one never does.

"""
    SteadyStateReport

What [`steady_state_report`](@ref) measured. `bytes` is the allocation of the measured call — the
worst of `repeats` of them — after `warmups` warming calls, so `iszero(bytes)` is the steady-state
verdict. `fresh_task` records whether the measured call ran on a newly scheduled task, which is
what distinguishes a pool from a per-task initializer.

The measurement covers the calls that ran and says nothing about an argument shape it was not
given.
"""
struct SteadyStateReport
    target::String
    bytes::Int
    warmups::Int
    repeats::Int
    fresh_task::Bool
end

steady(r::SteadyStateReport) = iszero(r.bytes)

function Base.show(io::IO, r::SteadyStateReport)
    printstyled(io, "SteadyStateReport"; bold = true)
    print(io, ": ", r.target, "\n")
    if steady(r)
        printstyled(io, "  steady"; color = :green)
        print(io, ": allocates nothing after ", r.warmups, " warmup call(s)")
    else
        printstyled(io, "  NOT steady"; color = :yellow, bold = true)
        print(io, ": allocated ", r.bytes, " byte(s) after ", r.warmups, " warmup call(s)")
    end
    r.fresh_task && print(io, ", measured on a fresh task")
    r.repeats > 1 && print(io, ", worst of ", r.repeats)
    print(io, ".\n")
    if !steady(r)
        print(
            io, "  A pool still climbing to its high-water mark needs more warmups; one that ",
            "allocates per task is steady on the warming task and not on a fresh one.\n"
        )
    end
    print(
        io, "  Measured over the calls that ran, so it says nothing about an argument shape it ",
        "was not given."
    )
    return nothing
end

"""
    steady_state_report(f, args...; warmups = 2, repeats = 1, fresh_task = false) -> SteadyStateReport

Measure whether `f(args...)` allocates anything **once warmed**: the call is made `warmups` times,
then measured. Returns a [`SteadyStateReport`](@ref) and never raises.

This is the development-time counterpart to `StrictModeTest.@test_steady_state`, for code whose only
allocation is a workspace pool climbing to a high-water mark. `:noalloc` cannot express that — the
growth path exists on every path, so an all-paths proof must report it forever — and the property
the code really has is about the call sequence, which is why this measures rather than infers.

Like [`memsafe_report`](@ref) and [`mca_report`](@ref) it takes **values**, not types, and runs the
call. It therefore sits outside the value-free `findings`/`audit` pipeline and does not belong at a
`src` call site: put it in a probe, a dogfood block, or a REPL session.

```julia
ws = Workspace()
steady_state_report(solve!, ws, A, b)          # SteadyStateReport: steady
steady_state_report(scratch, ws; fresh_task = true)   # per-task init shows up here
```

`fresh_task = true` measures on a newly scheduled task, which is what separates a **pool** from a
**per-task initializer**: a pool at its high-water mark allocates nothing for any caller, while a
`OncePerTask` accessor is steady on the warming task and not on a fresh one.

`repeats` measures more than once and keeps the worst, for a pool whose growth is uneven.

A `steady` report covers the calls that ran. It says nothing about an argument shape it was not
given, where an all-paths proof would have — so choose the shapes you measure the way you would
choose benchmark sizes.
"""
function steady_state_report(
        @nospecialize(f), args...;
        warmups::Int = 2, repeats::Int = 1, fresh_task::Bool = false
    )
    warmups >= 1 || throw(ArgumentError("steady_state_report: warmups must be at least 1"))
    repeats >= 1 || throw(ArgumentError("steady_state_report: repeats must be at least 1"))
    target = string(nameof(typeof(f) <: Function ? f : typeof(f))) *
        "(" * join(map(a -> string(typeof(a)), args), ", ") * ")"
    for _ in 1:warmups
        f(args...)
    end
    measure() = @allocated f(args...)
    worst = 0
    for _ in 1:repeats
        b = fresh_task ? fetch(schedule(Task(() -> measure()))) : measure()
        worst = max(worst, b)
    end
    return SteadyStateReport(target, worst, warmups, repeats, fresh_task)
end
