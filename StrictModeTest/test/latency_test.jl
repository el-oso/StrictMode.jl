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
