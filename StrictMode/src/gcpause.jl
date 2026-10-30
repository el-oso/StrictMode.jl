# A call that allocates nothing can still be stopped by the garbage collector. Julia's collector is
# stop-the-world: when any thread triggers a collection, every other thread is paused at its next
# safepoint, however clean its own code is. So `:noalloc` on the hot path is necessary and not
# sufficient, and no analysis of the hot path can close the gap — the trigger is in another thread.
#
# What can be settled is whether a collection landed inside the window, and how long the calls took
# when one did. That needs real argument values and has to run the call, so it sits outside the
# value-free `findings`/`audit` pipeline, like `steady_state_report` and `memsafe_report`. The
# gating form is `StrictModeTest.@test_no_gc_pause`; this one never raises.
#
# The GC counters are process-wide, which is the point: a collection triggered by a thread this
# call knows nothing about still shows up in the window's `pause` count.

"""
    GcPauseReport

What [`gc_pause_report`](@ref) measured over `samples` calls.

`collections` is the number of garbage collections that ran during a measured call, so
`iszero(collections)` is the verdict that nothing paused the call. `gc_ns` is the collector time
inside those calls.

`process_bytes` is the allocation Julia's counters recorded while the worst single call ran, in the
**whole process** rather than in this call. Those counters are global, so a thread the call never
touches contributes to them — which is what makes the field useful here: it sizes the pressure the
rest of the process put on the collector during the window. It is not this call's own allocation,
and `@test_noalloc` is what answers that question.

The timing fields describe the per-call wall clock: `median_ns`, `q99_ns`, `max_ns`, and
`slow_calls`, the number of calls that took more than `slow_factor` times the median. An
uninterrupted region has a `q99_ns` close to its median; a region the collector stopped has a long
tail, and that shape is the signal.

Below a median of one microsecond the harness costs more than the call, so the spread between
samples is the sampling clock rather than the program. `show` says so and withholds the tail count
there, rather than reporting a tail that is an artifact of measuring. The collection count is
unaffected.

It covers the calls that ran, in the process they ran in, under whatever else that process was
doing. It is a measurement, not a proof: a run with no pauses on an idle machine says nothing about
a busy one.
"""
struct GcPauseReport
    target::String
    samples::Int
    process_bytes::Int
    collections::Int
    gc_ns::Int
    median_ns::Int
    q99_ns::Int
    max_ns::Int
    slow_calls::Int
    slow_factor::Float64
end

gc_free(r::GcPauseReport) = iszero(r.collections)

_ms(ns::Integer) = round(ns / 1.0e6; digits = 3)

# Below this the harness costs more than the call, so the spread between samples is the sampling
# clock rather than the program: `time_ns` alone is ~18 ns and a sample is ~140 ns. A tail reported
# at that scale names a problem that is not there, which is the one thing a report must not do.
const _TIMING_FLOOR_NS = 1_000

function Base.show(io::IO, r::GcPauseReport)
    printstyled(io, "GcPauseReport"; bold = true)
    print(io, ": ", r.target, "\n")
    if gc_free(r)
        printstyled(io, "  no pause"; color = :green)
        print(io, ": no collection ran during ", r.samples, " call(s)")
    else
        printstyled(io, "  PAUSED"; color = :yellow, bold = true)
        print(
            io, ": ", r.collections, " collection(s) ran during ", r.samples, " call(s), ",
            _ms(r.gc_ns), " ms of collector time"
        )
    end
    print(io, ".\n")
    print(
        io, "  per call: median ", _ms(r.median_ns), " ms, q99 ", _ms(r.q99_ns), " ms, max ",
        _ms(r.max_ns), " ms\n"
    )
    if r.median_ns < _TIMING_FLOOR_NS
        print(
            io, "  the call is shorter than the harness (~140 ns per sample), so the timing ",
            "fields above measure the sampling clock; the collection count still holds\n"
        )
    elseif r.slow_calls > 0
        print(
            io, "  ", r.slow_calls, " of ", r.samples, " call(s) took more than ", r.slow_factor,
            "x the median\n"
        )
    end
    if !iszero(r.process_bytes)
        print(
            io, "  process allocation: ", r.process_bytes, " byte(s) recorded while the worst ",
            "call ran. Julia's counters are process-wide, so this is what the whole process ",
            "allocated, not what this call did — use `@test_noalloc` for that.\n"
        )
    end
    if !gc_free(r)
        print(
            io, "  A collection stops every thread at its next safepoint, so a pause here may ",
            "have been triggered by code this call does not reach. Find the allocating thread; ",
            "tuning the collector moves the pause rather than removing it."
        )
    else
        print(
            io, "  Measured in this process, under whatever else it was doing — a run with no ",
            "pauses on an idle machine says nothing about a busy one."
        )
    end
    return nothing
end

# Sampling must not allocate: a harness that allocates triggers the collections it is counting.
# `time_ns` and `Base.gc_num` both return isbits values and are allocation-free, and the sample
# buffer is built before the window opens.
function _gc_pause_samples!(
        times::Vector{UInt64}, @nospecialize(f), @nospecialize(args::Tuple)
    )
    collections = 0
    gc_ns = 0
    process_bytes = 0
    for i in eachindex(times)
        n0 = Base.gc_num()
        t0 = time_ns()
        f(args...)
        t1 = time_ns()
        n1 = Base.gc_num()
        times[i] = t1 - t0
        d = Base.GC_Diff(n1, n0)
        collections += d.pause
        gc_ns += d.total_time
        # Process-wide, like every counter in `GC_Num`: another thread's allocation lands here too.
        process_bytes = max(process_bytes, Int(d.allocd))
    end
    return (; collections, gc_ns, process_bytes)
end

"""
    gc_pause_report(f, args...; samples = 100, warmups = 2, slow_factor = 2.0) -> GcPauseReport

Measure whether a garbage collection runs while `f(args...)` does, and what the calls cost when one
does. Returns a [`GcPauseReport`](@ref) and never raises.

This is the axis the allocation guarantees do not cover. `@test_noalloc` proves that *this* call
allocates nothing; it cannot say that nothing else in the process does. Julia's collector stops the
world, so a thread that allocates pauses an allocation-free kernel at its next safepoint, and the
kernel's own analysis can never see the cause.

Like [`steady_state_report`](@ref) and [`memsafe_report`](@ref) it takes **values**, runs the call,
and therefore sits outside the value-free `findings`/`audit` pipeline. Put it in a probe or a
benchmark, not at a `src` call site. The gating form is `StrictModeTest.@test_no_gc_pause`.

```julia
gc_pause_report(gemm!, C, A, B)                      # no pause: no collection in the window
gc_pause_report(gemm!, C, A, B; samples = 2000)      # a longer window sees rarer pauses
```

A verdict of no pauses is a statement about the run, not about the code: the same call measured
while another thread allocates reports the collections that thread caused. That is the intended
use — measure under the load the kernel will actually meet.

The sampling window allocates nothing, so the harness does not create the collections it counts;
it costs about 140 ns per sample. For a call much shorter than a microsecond that overhead
dominates the timing fields, though the collection count stays meaningful.
"""
function gc_pause_report(
        @nospecialize(f), args...;
        samples::Int = 100, warmups::Int = 2, slow_factor::Real = 2.0
    )
    samples >= 1 || throw(ArgumentError("gc_pause_report: samples must be at least 1"))
    warmups >= 1 || throw(ArgumentError("gc_pause_report: warmups must be at least 1"))
    slow_factor > 1 || throw(ArgumentError("gc_pause_report: slow_factor must be greater than 1"))
    target = string(nameof(typeof(f) <: Function ? f : typeof(f))) *
        "(" * join(map(a -> string(typeof(a)), args), ", ") * ")"
    for _ in 1:warmups
        f(args...)
    end
    times = Vector{UInt64}(undef, samples)
    acc = _gc_pause_samples!(times, f, args)
    sort!(times)
    med = Int(times[cld(samples, 2)])
    q99 = Int(times[clamp(ceil(Int, 0.99 * samples), 1, samples)])
    slow = count(>(slow_factor * med), times)
    return GcPauseReport(
        target, samples, acc.process_bytes, acc.collections, acc.gc_ns,
        med, q99, Int(times[end]), slow, Float64(slow_factor)
    )
end
