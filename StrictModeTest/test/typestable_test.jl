# F39 (StrictMode issue #27): the proof must not be weaker than the scan. JET cannot see a
# union-typed local that boxes a member on the way in — union splitting is not dynamic dispatch —
# so `@test_typestable` has to consult the scan's `unionphi` signal or it waves through exactly the
# class `@assert_typestable` catches.

@testitem "issue #27: @test_typestable catches the union-phi box JET is blind to" begin
    using StrictMode, StrictModeTest
    @noinline function boxing_union_local(A::AbstractMatrix{Float64}, take::Bool)
        local x = take ? view(A, :, 1:1) : A
        s = 0.0
        for i in eachindex(x)
            s += @inbounds x[i]
        end
        return s
    end
    A = rand(4, 4)
    boxing_union_local(A, true)
    tt = (Matrix{Float64}, Bool)

    # The proof's other two layers both pass on this signature, which is what makes the class
    # invisible to them: the return type is concrete and JET reports nothing.
    @test only(Base.return_types(boxing_union_local, Tuple{tt...})) === Float64
    @test isempty(StrictModeTest._opt_reports("probe", boxing_union_local, tt))

    # The scan sees it, and so must the proof.
    @test StrictMode._alloc_signals(boxing_union_local, tt; depth = 0).unionphi
    f = only(proof_findings(boxing_union_local, tt; guarantees = (:typestable,)))
    @test StrictMode._failed(f)
    @test occursin("union-typed local", f.reason)
end

# Issue #30: on Julia 1.13 JET reports an optimization failure inside Base's scheduler for any target
# that wakes or yields a task. That report is located in Base and must not fail the target.
@testitem "issue #30: a task-waking target is not failed by Base's scheduler" begin
    using StrictMode, StrictModeTest
    const JET = StrictModeTest.JET
    const EV = Base.Event(true)
    wake(x::Int) = (notify(EV); yield(); x + 1)
    dispatch(v::Vector{Any}) = (v[1] + 1)::Int
    wake(1)
    dispatch(Any[1])

    raw = JET.get_reports(JET.report_opt(wake, (Int,)))
    if VERSION >= v"1.13"
        # The fixture must still reach the Base cycle, or the assertions below prove nothing.
        @test !isempty(raw)
        @test all(r -> r isa JET.OptimizationFailureReport, raw)
        @test all(StrictModeTest._is_foreign_opt_failure, raw)
        # The same cycle, entered from Base itself, is not foreign and still counts.
        @test !isempty(StrictModeTest._opt_reports("probe", yield, ()))
    end
    @test isempty(StrictModeTest._opt_reports("probe", wake, (Int,)))
    @test !StrictMode._failed(only(proof_findings(wake, (Int,); guarantees = (:typestable,))))

    # A report in the target's own code still fails, and the reason says where it is.
    f = only(proof_findings(dispatch, (Vector{Any},); guarantees = (:typestable,)))
    @test StrictMode._failed(f)
    @test occursin("RuntimeDispatchReport in ", f.reason)
    @test occursin(".dispatch", f.reason)
end

# Issue #31: an OptimizationFailureReport located in the target's OWN package says the optimizer
# declined a recursive frame. The types are known, so it is logged, not failed.
@testitem "issue #31: an optimizer bail is logged, not a type-stability failure" begin
    using StrictMode, StrictModeTest
    const JET = StrictModeTest.JET
    # Types grow with depth, so inference limits the cycle and declines to optimize the frame.
    grow(t::Tuple, n::Int)::Float64 = n <= 0 ? sum(Float64[t...]) : grow((t..., Float64(n)), n - 1)
    dispatch(v::Vector{Any}) = (v[1] + 1)::Int
    grow((1.0,), 3)
    dispatch(Any[1])
    tt = (Tuple{Float64}, Int)

    raw = JET.get_reports(JET.report_opt(grow, tt))
    if VERSION >= v"1.13"
        # The fixture must still produce the report, or this proves nothing.
        @test any(r -> r isa JET.OptimizationFailureReport, raw)
        # It is in the target's own module, so #30's filter keeps it — #31 is about the verdict.
        @test !any(StrictModeTest._is_foreign_opt_failure, raw)
        @test !isempty(StrictModeTest._opt_reports("probe", grow, tt))
    end
    f = only(proof_findings(grow, tt; guarantees = (:typestable,)))
    @test !StrictMode._failed(f)
    @test @test_logs (:info, r"no optimized IR") match_mode = :any (proof_findings(grow, tt; guarantees = (:typestable,))) isa Vector

    # A real dispatch still fails, and now names its cause and fix.
    g = only(proof_findings(dispatch, (Vector{Any},); guarantees = (:typestable,)))
    @test StrictMode._failed(g)
    @test occursin("RuntimeDispatchReport in ", g.reason)
    @test occursin("Vector{Any}", g.reason)
    @test occursin("concrete element type", g.suggestion)
end

# The bail has a cost JET cannot cover: its dispatch analysis reads optimized IR, and a bailed frame
# has none, so that frame's own body can never produce a dispatch report. It is scanned directly.
@testitem "issue #31: a dynamic call inside an unoptimized frame still fails" begin
    using StrictMode, StrictModeTest
    const SINK = Any[sin]
    # Same limited-recursion shape as the clean fixture, with a dynamic call in the body.
    growdyn(t::Tuple, n::Int)::Float64 =
        n <= 0 ? (SINK[1](1.0)::Float64) : growdyn((t..., Float64(n)), n - 1)
    growdyn((1.0,), 3)
    tt = (Tuple{Float64}, Int)

    f = only(proof_findings(growdyn, tt; guarantees = (:typestable,)))
    @test StrictMode._failed(f)
    @test occursin("runtime dispatch", f.reason)

    # The scanner that covers the bailed frame, exercised directly on its own reports.
    reps = StrictModeTest._opt_reports("probe", growdyn, tt)
    bails = filter(r -> r isa StrictModeTest.JET.OptimizationFailureReport, reps)
    if VERSION >= v"1.13" && !isempty(bails)
        @test !isempty(reduce(vcat, StrictModeTest._bail_frame_dispatches.(bails)))
    end
end
