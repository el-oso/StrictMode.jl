# The two measurements that need a process per thread count. The package named is one the child
# can always load; the code under test is defined by `setup`, so nothing here depends on a real
# threaded package being installed.

@testmodule ThreadedModel begin
    # `psum` splits its reduction by thread count, so its rounding changes with it. `fixedsum`
    # uses a task and reduces in one order. `JOBS` is the witness a package's pool would keep.
    const SETUP = """
    const JOBS = Threads.Atomic{Int}(0)
    function psum(x)
        n = Threads.nthreads()
        n == 1 && return sum(x)
        chunks = collect(Iterators.partition(eachindex(x), cld(length(x), n)))
        ts = map(c -> Threads.@spawn(begin JOBS[] += 1; sum(view(x, c)) end), chunks)
        return sum(fetch, ts)
    end
    fixedsum(x) = (t = Threads.@spawn(begin JOBS[] += 1; nothing end); wait(t); sum(x))
    scaled() = sleep(0.4 / Threads.nthreads())
    flat() = sleep(0.1)
    slower() = sleep(Threads.nthreads() > 1 ? 0.3 : 0.03)
    x = collect(1.0:0.1:20000.0) .^ 1.3
    """
end

@testitem "threadcount_invariant_report compares bits across thread counts" setup = [ThreadedModel] begin
    using StrictMode
    setup = ThreadedModel.SETUP

    r = threadcount_invariant_report(:Test, "fixedsum(x)"; setup, threads = 1:3, witness = "JOBS[] > 0")
    @test r isa ThreadcountInvariantReport
    @test r.nthreads == [1, 2, 3]
    @test StrictMode.invariant(r)
    @test StrictMode.witnessed(r)

    # A reduction split per thread agrees to rounding and not to the bit.
    d = threadcount_invariant_report(:Test, "psum(x)"; setup, threads = [1, 3], witness = "JOBS[] > 0")
    @test !StrictMode.invariant(d)
    @test d.identical == [true, false]
    @test d.first_difference[2] > 0
    @test occursin("differs", sprint(show, d))

    # Identical results from a call that never threads: the witness is what tells them apart.
    s = threadcount_invariant_report(:Test, "sum(x)"; setup, threads = 1:2, witness = "JOBS[] > 0")
    @test StrictMode.invariant(s)
    @test !StrictMode.witnessed(s)
    @test occursin("did NOT run", sprint(show, s))

    n = threadcount_invariant_report(:Test, "sum(x)"; setup, threads = 1:2)
    @test isnothing(n.witnessed)
    @test !StrictMode.witnessed(n)
    @test occursin("no witness", sprint(show, n))

    @test_throws "no fixed bit representation" threadcount_invariant_report(
        :Test, "string(x[1])"; setup, threads = 1:1
    )
end

@testitem "threaded_speedup_report times one thread against many" setup = [ThreadedModel] begin
    using StrictMode
    r = threaded_speedup_report(
        :Test, "scaled()"; setup = ThreadedModel.SETUP, cpus = 2, threads = 4, repeats = 2
    )
    @test r isa ThreadedSpeedupReport
    @test r.nthreads == 4
    @test r.workers == 4
    @test r.pinned == !isnothing(Sys.which("taskset"))
    # 0.4 s against 0.1 s of sleep: the ratio is set by the model, not by the host.
    @test StrictMode.speedup(r) > 2
    @test StrictMode.efficiency(r) ≈ StrictMode.speedup(r) / 4
    @test occursin("4 threads", sprint(show, r))

    w = threaded_speedup_report(
        :Test, "flat()"; setup = ThreadedModel.SETUP, cpus = 2, threads = 4, workers = "2", repeats = 1
    )
    @test w.workers == 2
    @test_throws "did not report a result" threaded_speedup_report(:Test, "undefined_call()"; cpus = 2, threads = 2)
end
