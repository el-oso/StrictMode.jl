# The gating forms of the two per-thread-count measurements. The models sleep, so the ratios they
# produce are set by the model and not by the host the suite runs on.

@testitem "test_threaded_speedup gates on the ratio to the serial run" begin
    using StrictMode, StrictModeTest
    setup = """
    scaled() = sleep(0.4 / Threads.nthreads())
    flat() = sleep(0.1)
    slower() = sleep(Threads.nthreads() > 1 ? 0.3 : 0.03)
    """
    kw = (; setup, cpus = 2, threads = 4, repeats = 2)

    @test test_threaded_speedup(:Test, "scaled()"; kw...) isa ThreadedSpeedupReport
    # Threading that loses to the serial path fails with no bound named.
    @test_throws "against a limit of 1.5x" test_threaded_speedup(:Test, "slower()"; kw...)
    # No speedup at all is inside the default limit, and outside an efficiency bound.
    @test test_threaded_speedup(:Test, "flat()"; kw...) isa ThreadedSpeedupReport
    if !isnothing(Sys.which("taskset"))
        @test test_threaded_speedup(:Test, "scaled()"; kw..., efficiency = 0.4) isa ThreadedSpeedupReport
        @test_throws "an efficiency of 0.4 over 4 worker(s)" test_threaded_speedup(
            :Test, "flat()"; kw..., efficiency = 0.4
        )
    end
    @test_throws "no bound was given" test_threaded_speedup(:Test, "flat()"; kw..., max_slowdown = nothing)
end

@testitem "test_threadcount_invariant needs identical bits and a witness" begin
    using StrictMode, StrictModeTest
    setup = """
    const JOBS = Threads.Atomic{Int}(0)
    function psum(x)
        n = Threads.nthreads()
        n == 1 && return sum(x)
        chunks = collect(Iterators.partition(eachindex(x), cld(length(x), n)))
        ts = map(c -> Threads.@spawn(begin JOBS[] += 1; sum(view(x, c)) end), chunks)
        return sum(fetch, ts)
    end
    fixedsum(x) = (t = Threads.@spawn(begin JOBS[] += 1; nothing end); wait(t); sum(x))
    x = collect(1.0:0.1:20000.0) .^ 1.3
    """
    w = "JOBS[] > 0"

    r = test_threadcount_invariant(:Test, "fixedsum(x)"; setup, witness = w, threads = 1:2)
    @test r isa ThreadcountInvariantReport

    @test_throws "differs from the one at -t 1" test_threadcount_invariant(
        :Test, "psum(x)"; setup, witness = w, threads = [1, 3]
    )
    # Bit-identical, and never threaded.
    @test_throws "threaded path did not run" test_threadcount_invariant(
        :Test, "sum(x)"; setup, witness = w, threads = 1:2
    )
    @test_throws "pass `witness`" test_threadcount_invariant(:Test, "sum(x)"; setup, threads = 1:2)
    @test_throws "no process had more than one thread" test_threadcount_invariant(
        :Test, "sum(x)"; setup, witness = "true", threads = 1:1
    )
end
