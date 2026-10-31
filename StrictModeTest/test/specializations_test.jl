@testitem "test_specializations gates the growth, since the count itself has no limit" begin
    using StrictMode, StrictModeTest

    module SpecGate
    f(x::Int) = x + 1
    g(x) = x * 2
    end
    SpecGate.f(1)
    SpecGate.g(1)
    SpecGate.g(1.0)

    bl = tempname()

    # First run has nothing to compare against, so it records and cannot fail. Adding this to a
    # suite is never a failure on the day it is added.
    recorded = test_specializations(SpecGate; baseline = bl, workload = "gate")
    @test recorded isa Dict{String, Int}
    @test isfile(bl)
    @test test_specializations(SpecGate; baseline = bl, workload = "gate") == recorded

    # Three more specializations of `g` compile, and the gate names `g` and its two counts.
    SpecGate.g(1.0f0)
    SpecGate.g(1 // 2)
    SpecGate.g(0x1)
    err = try
        test_specializations(SpecGate; baseline = bl, workload = "gate")
        nothing
    catch e
        e
    end
    @test err isa StrictMode.StrictViolation
    msg = sprint(showerror, err)
    @test occursin("compiled specializations", msg)
    @test occursin("SpecGate.g", msg)
    @test !occursin("SpecGate.f", msg)        # `f` did not grow
    @test occursin("compile-time pressure", msg)

    # Room to grow, and a way to accept growth that is intended.
    @test test_specializations(SpecGate; baseline = bl, workload = "gate", tolerance = 10) isa Dict
    test_specializations(SpecGate; baseline = bl, workload = "gate", update = true)
    @test test_specializations(SpecGate; baseline = bl, workload = "gate") isa Dict

    # The key is `(Julia version, workload)`: a count measured after different work is a different
    # measurement, so naming it apart records a baseline of its own rather than comparing.
    @test test_specializations(SpecGate; baseline = bl, workload = "other") isa Dict

    # A method the baseline does not name has nothing to regress against.
    @eval SpecGate h(x::Float64) = x - 1
    SpecGate.h(1.0)
    @test test_specializations(SpecGate; baseline = bl, workload = "gate") isa Dict

    # The knobs are checked rather than silently meaning something else.
    @test_throws ArgumentError test_specializations(SpecGate; baseline = bl, workload = "")
    @test_throws ArgumentError test_specializations(
        SpecGate; baseline = bl, workload = "gate", tolerance = -1
    )
    write(bl, "not a baseline")
    @test_throws ArgumentError test_specializations(SpecGate; baseline = bl, workload = "gate")
end
