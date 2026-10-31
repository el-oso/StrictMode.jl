@testitem "gc_pause_report reports no pause when no collection runs" begin
    using StrictMode

    noop() = nothing
    r = gc_pause_report(noop; samples = 200)
    @test r isa GcPauseReport
    @test StrictMode.gc_free(r)
    @test iszero(r.collections)
    @test iszero(r.gc_ns)
    @test r.samples == 200
    @test r.median_ns <= r.q99_ns <= r.max_ns          # the quantiles are ordered
    @test occursin("no pause", sprint(show, r))
end

@testitem "gc_pause_report sees a collection that lands inside the window" begin
    using StrictMode

    # The detector has to fire on something, or a no-pause verdict means only that nothing was
    # measured. A call that allocates heavily triggers its own collections, which needs no second
    # thread — the multithreaded case is the next item.
    hungry() = sum(rand(100_000))
    r = gc_pause_report(hungry; samples = 300)
    @test !StrictMode.gc_free(r)
    @test r.collections > 0
    @test r.gc_ns > 0
    @test occursin("PAUSED", sprint(show, r))
end

@testitem "gc_pause_report records a collection the measured call did not cause" begin
    using StrictMode

    # The reason this check exists: the collector stops the world, so a call that allocates nothing
    # is still paused by work it does not contain, and no analysis of the call can see the cause.
    #
    # The collection is requested rather than waited for. An allocating neighbor trips the
    # collector's heuristic when it happens to, and a window of a few milliseconds either catches
    # that or does not — a test built on it measures the scheduler. Here another task collects on
    # demand, so the window provably contains a collection the measured call did not cause. The
    # handshake blocks the measuring task, so the other task runs even on one thread.
    n = 4
    go = Channel{Nothing}(1)
    done = Channel{Nothing}(1)
    collector = Threads.@spawn for _ in 1:(n + 1)      # one warmup call, then n measured
        take!(go)
        GC.gc(false)
        put!(done, nothing)
    end
    paused() = (put!(go, nothing); take!(done))

    r = gc_pause_report(paused; samples = n, warmups = 1)
    wait(collector)
    @test r.collections >= n
    @test !StrictMode.gc_free(r)
    @test r.gc_ns > 0
end

@testitem "gc_pause_report is undisturbed by a neighbor that allocates nothing" begin
    using StrictMode

    # The control the verdict depends on: a second thread that is busy but allocation-free gives
    # the collector nothing to do, so an allocation-free call must still report no pause. Without
    # this, "no pause" could just mean the measurement is insensitive to other threads.
    clean_kernel() = (
        acc = 0.0; for i in 1:2000
            acc += sqrt(i)
        end; acc
    )
    if Threads.nthreads() < 2
        # A single-threaded session has no second thread to spawn the busy loop onto — the loop
        # never yields, so it would run forever rather than concurrently. The weaker half still
        # holds and is asserted: an allocation-free call reports no pause. What only a
        # multi-threaded run can show is that the verdict is SENSITIVE to another thread, which is
        # why CI sets JULIA_NUM_THREADS.
        @test StrictMode.gc_free(gc_pause_report(clean_kernel; samples = 200))
    else
        stop = Threads.Atomic{Bool}(false)
        busy = Threads.@spawn begin
            acc = 0.0
            while !stop[]
                acc += 1.0
            end
            acc
        end
        try
            sleep(0.05)
            @test StrictMode.gc_free(gc_pause_report(clean_kernel; samples = 200))
        finally
            stop[] = true
            wait(busy)
        end
    end
end

@testitem "gc_pause_report withholds a tail it cannot measure" begin
    using StrictMode

    # A call far below the harness cost has a median near the timer's resolution, so almost any
    # sample exceeds `slow_factor` times it. Reporting that as a tail names a problem that is not
    # there — the one thing a report must not do. The collection count is unaffected by scale.
    noop() = nothing
    tiny = gc_pause_report(noop; samples = 200)
    @test tiny.median_ns < StrictMode._TIMING_FLOOR_NS
    out = sprint(show, tiny)
    @test occursin("shorter than the harness", out)
    @test !occursin("took more than", out)
    @test occursin("no pause", out)

    # Above the floor the tail count is reported, because there it means something.
    work() = (
        acc = 0.0; for i in 1:20_000
            acc += sqrt(i)
        end; acc
    )
    real = gc_pause_report(work; samples = 200)
    @test real.median_ns >= StrictMode._TIMING_FLOOR_NS
    @test !occursin("shorter than the harness", sprint(show, real))
end

@testitem "the gc-pause sampling window allocates nothing" begin
    using StrictMode

    # A harness that allocates inside the window creates the collections it is counting, so the
    # measurement would report its own noise. The sample buffer is built before the window opens.
    #
    # Asked of the sampling function's own IR, not with `@allocated`: that reads a process-wide
    # counter, so a neighbor thread's bytes would land in the answer — which is the very confusion
    # `process_bytes` exists to name, and it would be odd to rest this test on it.
    # The buffer and the thunk are arguments, so the analyzed signature is concrete: closing over
    # non-`const` globals would box them at the call site before the window opens, and the scan
    # would report that — the call site's cost, not the harness's.
    noop() = nothing
    sample(buf, f) = StrictMode._gc_pause_samples!(buf, f, ())
    fs = findings(sample, (Vector{UInt64}, typeof(noop)); guarantees = (:noalloc, :noboxing))
    @test !isempty(fs)
    @test all(f -> f.status === :pass, fs)
end

@testitem "gc_pause_report's process_bytes counts the process, not the call" begin
    using StrictMode

    # Every counter in `Base.GC_Num` is process-wide. That is deliberate here — it sizes the
    # pressure the rest of the process put on the collector — but it must not be read as the call's
    # own allocation, and `@allocated` is no better: given a neighbor it reports the neighbor's
    # bytes for a call that allocates none.
    #
    # The neighbor allocates on request, so the window provably overlaps allocation this call did
    # not perform; the handshake blocks the measuring task, so it runs on one thread too.
    clean_kernel() = (
        acc = 0.0; for i in 1:2000
            acc += sqrt(i)
        end; acc
    )
    clean_kernel()
    # Ground truth from the scan, which reads this function's IR. `@allocated` cannot establish it
    # here: it is process-wide, so with the neighbor below running it reports the neighbor's bytes
    # for a kernel that allocates none — exactly the reading `process_bytes` is named to prevent.
    @test all(f -> f.status === :pass, findings(clean_kernel, (); guarantees = (:noalloc,)))

    n = 4
    go = Channel{Nothing}(1)
    done = Channel{Nothing}(1)
    neighbor = Threads.@spawn for _ in 1:(n + 1)
        take!(go)
        sum(rand(20_000))                                  # ~160 KB, charged to this task
        put!(done, nothing)
    end
    with_neighbor() = (put!(go, nothing); clean_kernel(); take!(done))

    r = gc_pause_report(with_neighbor; samples = n, warmups = 1)
    wait(neighbor)
    @test r.process_bytes > 0                              # …yet the window records bytes
end

@testitem "gc_pause_report rejects a measurement it cannot make" begin
    using StrictMode

    noop() = nothing
    @test_throws "samples must be at least 1" gc_pause_report(noop; samples = 0)
    @test_throws "warmups must be at least 1" gc_pause_report(noop; warmups = 0)
    @test_throws "slow_factor must be greater than 1" gc_pause_report(noop; slow_factor = 1.0)
end
