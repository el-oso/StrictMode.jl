@testitem "@strict_contract + @verify_strict accept a fast, compliant implementation" begin
    using StrictMode
    using TypeContracts

    @strict_contract AbstractMetric begin
        score(::Self, xs::AbstractVector{<:Real})::Real
    end
    function score end

    struct FirstMetric end
    score(::FirstMetric, xs::AbstractVector{<:Real}) = @inbounds xs[begin]

    m = FirstMetric()
    xs = [1.5, 2.5, 3.5]
    @verify_strict FirstMetric begin
        score(m, xs)
    end
    @test AbstractMetric in StrictMode.registered_strict_contracts()
    @test score(m, xs) == 1.5
end

@testitem "@verify_strict rejects an allocating implementation" begin
    using StrictMode
    using TypeContracts

    @strict_contract AbstractMetric2 begin
        score2(::Self, xs::AbstractVector{<:Real})::Real
    end
    function score2 end

    struct SlowMetric end
    # Satisfies the interface (returns a Real) but allocates via collect → StrictMode rejects it.
    score2(::SlowMetric, xs::AbstractVector{<:Real}) = sum(collect(xs))

    ms = SlowMetric()
    xs = [1.0, 2.0, 3.0]
    @test_throws StrictViolation @verify_strict SlowMetric begin
        score2(ms, xs)
    end
end
