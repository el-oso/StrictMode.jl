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

@testitem "gc_pause_report sees a collection another thread caused" begin
    using StrictMode

    # The reason this check exists: the collector stops the world, so an allocation-free call is
    # paused by an allocating neighbor, and no analysis of the call can see the cause. The kernel
    # below is the same in both measurements — only the neighbor changes.
    if Threads.nthreads() < 2
        @test_skip false
    else
        clean_kernel() = (
            acc = 0.0; for i in 1:2000
                acc += sqrt(i)
            end; acc
        )

        function with_neighbor(allocating::Bool)
            stop = Threads.Atomic{Bool}(false)
            t = Threads.@spawn begin
                acc = 0.0
                while !stop[]
                    acc += allocating ? sum(rand(20_000)) : 1.0
                end
                acc
            end
            try
                sleep(0.05)
                return gc_pause_report(clean_kernel; samples = 400)
            finally
                stop[] = true
                wait(t)
            end
        end

        # Control: a busy neighbor that allocates nothing must not disturb the verdict.
        @test StrictMode.gc_free(with_neighbor(false))
        # The case: the same kernel, a neighbor that allocates.
        noisy = with_neighbor(true)
        @test noisy.collections > 0
        @test !StrictMode.gc_free(noisy)
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
    noop() = nothing
    times = Vector{UInt64}(undef, 500)
    sample() = StrictMode._gc_pause_samples!(times, noop, ())
    sample()
    @test iszero(@allocated sample())
end

@testitem "gc_pause_report's process_bytes counts the process, not the call" begin
    using StrictMode

    # Every counter in `Base.GC_Num` is process-wide. That is deliberate here — it sizes the
    # pressure the rest of the process put on the collector — but it must not be read as the call's
    # own allocation, and `@allocated` is no better: it reports a neighbor's bytes too.
    if Threads.nthreads() < 2
        @test_skip false
    else
        clean_kernel() = (
            acc = 0.0; for i in 1:2000
                acc += sqrt(i)
            end; acc
        )
        @test iszero(@allocated clean_kernel())            # ground truth, measured alone

        stop = Threads.Atomic{Bool}(false)
        t = Threads.@spawn (
            while !stop[]
                sum(rand(20_000))
            end
        )
        try
            sleep(0.05)
            r = gc_pause_report(clean_kernel; samples = 200)
            @test r.process_bytes > 0                      # …yet the window records bytes
        finally
            stop[] = true
            wait(t)
        end
    end
end

@testitem "gc_pause_report rejects a measurement it cannot make" begin
    using StrictMode

    noop() = nothing
    @test_throws "samples must be at least 1" gc_pause_report(noop; samples = 0)
    @test_throws "warmups must be at least 1" gc_pause_report(noop; warmups = 0)
    @test_throws "slow_factor must be greater than 1" gc_pause_report(noop; slow_factor = 1.0)
end
