@testitem "test_calls passes a module whose calls all resolve" begin
    using StrictMode, StrictModeTest

    module CallsOk
    good(x::Int) = x + 1
    sums(v::Vector{Float64}) = sum(v)
    guarded(v::Vector{Int}) = (i = findfirst(iszero, v); isnothing(i) ? 0 : v[i])
    end
    CallsOk.good(1); CallsOk.sums([1.0]); CallsOk.guarded([0])      # warm

    fs = test_calls(CallsOk)
    @test iszero(nfailures(fs))
    @test length(fs) == 3
    @test all(f -> f.guarantee === :calls && f.tier === :proof, fs)
end

@testitem "test_calls finds a MethodError the optimization proofs are blind to" begin
    using StrictMode, StrictModeTest

    module CallsBad
    rare(x::Int) = x > 1000 ? x + "oops" : x + 1
    fine(x::Int) = x * 2
    end
    CallsBad.rare(1); CallsBad.fine(1)                              # warm; the bad branch is cold

    # The gap this driver exists for: the call analysis sees the unreachable-in-practice branch,
    # and the optimization analysis behind `@test_typestable` does not.
    @test isempty(StrictModeTest._opt_reports("t", CallsBad.rare, (Int,)))
    @test !isempty(StrictModeTest._call_reports("t", CallsBad.rare, (Int,), CallsBad))

    @test_throws StrictMode.StrictViolation test_calls(CallsBad)
    @test_throws "no matching method" test_calls(CallsBad)

    # One function is at fault, and only that one is reported.
    fs = StrictModeTest._call_findings(CallsBad)
    @test nfailures(fs) == 1
    bad = only(filter(StrictMode._failed, fs))
    @test bad.func == "rare"
    @test bad.code === :SM0204
    @test occursin("exempt", bad.suggestion)

    # …and the name filters are the escape hatch for a guard inference cannot follow.
    @test iszero(nfailures(test_calls(CallsBad; exempt = (:rare,))))
    @test iszero(nfailures(test_calls(CallsBad; only = r"^fine$")))
end

@testitem "test_calls finds a name that is not defined" begin
    using StrictMode, StrictModeTest

    module CallsUndef
    reads_undefined(x::Int) = x + NOT_DEFINED_IN_THIS_MODULE
    end
    try
        CallsUndef.reads_undefined(1)
    catch
    end
    @test_throws StrictMode.StrictViolation test_calls(CallsUndef)
    @test_throws "not defined" test_calls(CallsUndef)
end

@testitem "test_calls gates only the two actionable report kinds" begin
    using StrictMode, StrictModeTest

    # Both shapes below are CORRECT code that JET's call analysis reports. Gating them would make
    # the driver unusable: over StrictMode's own signatures the non-boolean-condition reports
    # outnumber the method errors by more than a hundred to one, and a method every path of which
    # throws is a deliberate error helper — `:typestable` accepts its `Union{}` return for the same
    # reason (issue #36).
    module CallsNoisy
    # Every path throws — `UncaughtExceptionReport`.
    refuse(x::Int) = throw(ArgumentError("never ok"))
    # `in` over a `Vector{Any}` can return `Missing` on one union split — `NonBooleanCondErrorReport`.
    searched(v::Vector{Any}) = (:k in v) ? 1 : 0
    end
    try
        CallsNoisy.refuse(1)
    catch
    end
    CallsNoisy.searched(Any[:k])                                    # warm

    @test iszero(nfailures(test_calls(CallsNoisy)))

    # The reports exist — they are filtered, not absent, so this pins the choice rather than an
    # accident of what JET happened to find.
    jet = StrictModeTest.JET
    for (f, tt, kind) in (
            (CallsNoisy.refuse, (Int,), :UncaughtExceptionReport),
            (CallsNoisy.searched, (Vector{Any},), :NonBooleanCondErrorReport),
        )
        raw = jet.get_reports(jet.report_call(f, tt; target_modules = (CallsNoisy,)))
        @test any(r -> nameof(typeof(r)) === kind, raw)
        @test !any(StrictModeTest._is_call_defect, raw)
    end
    @test StrictModeTest._CALL_REPORT_KINDS == (:MethodErrorReport, :UndefVarErrorReport)
end
