@testitem "latency_report measures a cold load and a first call" begin
    using StrictMode

    # The package under test is already loaded here, so its own cache is warm: skipping the
    # precompile child keeps this item to one process instead of two.
    r = latency_report(
        :StrictMode;
        calls = ["StrictMode.checks_enabled()", "StrictMode.explain(:SM0001)"],
        precompile = false
    )
    @test r isa LatencyReport
    @test r.target == "StrictMode"
    @test r.load_ms > 0                         # a real `using` cannot be free
    @test length(r.first_call_ms) == 2
    @test first.(r.first_call_ms) == ["StrictMode.checks_enabled()", "StrictMode.explain(:SM0001)"]
    @test all(ms -> ms >= 0, last.(r.first_call_ms))
    @test !r.precompiled                        # states what THIS call did, not what anyone did

    out = sprint(show, r)
    @test occursin("load:", out)
    @test occursin("no precompile cache", out)  # …and says so, since the number is then not comparable
end

@testitem "latency_report reports a child that could not load the package" begin
    using StrictMode

    # A package that does not exist cannot report a load time. Returning a zero would be a budget
    # that always passes, so this raises and carries the child's own error text.
    @test_throws "did not report a load time" latency_report(
        :NoSuchPackageExistsAnywhere; precompile = false
    )
end

@testitem "latency_report keeps a call's text away from the child's protocol" begin
    using StrictMode

    # The child reports by line, and a call's text is the caller's: it may hold spaces, quotes or a
    # newline. Times are keyed by index for that reason, and the text only ever travels inside the
    # code the child evaluates.
    tricky = "StrictMode.explain(Symbol(\"SM0001\"))"
    script = StrictMode._latency_child_script(:StrictMode, [tricky])
    @test occursin("STRICTMODE_LATENCY call1 ", script)
    @test !occursin("STRICTMODE_LATENCY $tricky", script)

    r = latency_report(:StrictMode; calls = [tricky], precompile = false)
    @test only(first.(r.first_call_ms)) == tricky
end
