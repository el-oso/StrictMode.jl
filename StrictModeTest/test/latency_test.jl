@testitem "test_latency measures and returns when no budget is given" begin
    using StrictMode, StrictModeTest

    # With no budget nothing can fail. That is the form to use first: record the numbers on the
    # host that will hold the budget, then choose it.
    r = test_latency(:StrictMode; precompile = false)
    @test r isa LatencyReport
    @test r.load_ms > 0
end

@testitem "test_latency fails a budget it is given, and only that budget" begin
    using StrictMode, StrictModeTest

    @test_throws StrictMode.StrictViolation test_latency(
        :StrictMode; max_load_ms = 1.0e-6, precompile = false
    )
    @test_throws "against a budget of" test_latency(
        :StrictMode; max_load_ms = 1.0e-6, precompile = false
    )
    # The failure says where the numbers came from, because a budget set on one host means nothing
    # on another.
    msg = try
        test_latency(:StrictMode; max_load_ms = 1.0e-6, precompile = false)
        ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("fresh process on this machine", msg)
    @test occursin("cache was NOT built by this call", msg)

    # A generous budget passes, and a first-call budget is judged per call.
    @test test_latency(:StrictMode; max_load_ms = 600_000, precompile = false) isa LatencyReport
    @test_throws "the first `StrictMode.explain(:SM0001)`" test_latency(
        :StrictMode; calls = ["StrictMode.explain(:SM0001)"],
        max_first_call_ms = 1.0e-9, precompile = false
    )
end

@testitem "first-call time really includes the first call's compilation" begin
    using StrictMode, StrictModeTest

    # A top-level statement is compiled before it runs, and a call inside one is specialized as
    # part of that compilation — so a bare `@elapsed (call)` starts its clock after the work it
    # means to measure is already done, and reports a first call as fast as a second. Then
    # `max_first_call_ms` can never catch a regression, which is the whole point of the budget.
    # `@eval` inside the timed region is what moves the compilation inside the clock.
    #
    # Pinned on the generated script rather than on a timing ratio, deliberately. Measured on a
    # function with a 4000-statement body, `@elapsed (call)` gives 0.03 ms for the first call and
    # 0.02 ms for the second, against 1791.8 ms and 0.45 ms for `@elapsed @eval (call)` — so the
    # defect is real, but no call reachable through StrictMode's own API isolates it: the first-call
    # cost of a StrictMode entry point is its internal memoization, which differs between the two
    # forms either way, and an expression carrying a closure re-specializes on every `@eval` and so
    # is slow on every call. A ratio test over those reads the same whether this is fixed or not,
    # and a test that passes both ways tests nothing.
    script = StrictMode._latency_child_script(:StrictMode, ["foo(1)", "bar(2)"])
    @test occursin("@elapsed @eval (foo(1))", script)
    @test occursin("@elapsed @eval (bar(2))", script)
    # The load measurement must NOT be wrapped: `using` does its work when the statement runs, so
    # the plain form already times it, and `@eval` would only add its own parse to the number.
    @test occursin("@elapsed (using StrictMode)", script)

    # …and the whole path still runs and reports a number per call.
    r = test_latency(:StrictMode; calls = ["StrictMode.explain(:SM0001)"], precompile = false)
    @test length(r.first_call_ms) == 1
    @test last(r.first_call_ms[1]) > 0
end
