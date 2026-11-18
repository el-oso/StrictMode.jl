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
    @test_logs (:warn,) match_mode = :any @verify_strict SlowMetric begin
        score2(ms, xs)
    end
end

@testitem "@verify_strict guarantees = … checks only the named guarantees" begin
    using StrictMode
    using TypeContracts

    StrictMode.clear_declarations!()
    @strict_contract AbstractMetric3 begin
        score3(::Self, xs::AbstractVector{<:Real})::Real
    end
    function score3 end

    struct SlowMetric3 end
    score3(::SlowMetric3, xs::AbstractVector{<:Real}) = sum(collect(xs))   # stable, allocates

    ms = SlowMetric3()
    xs = [1.0, 2.0, 3.0]
    # :typestable only: the allocation is not checked here, so nothing warns.
    @test_logs @verify_strict SlowMetric3 guarantees = (:typestable,) begin
        score3(ms, xs)
    end
    # Each listed signature is registered with the named guarantees, for the test-time drivers.
    @test StrictMode.declarations()[(score3, (SlowMetric3, Vector{Float64}))].guarantees == (:typestable,)

    # Naming :noalloc brings the allocation warning back.
    @test_logs (:warn,) match_mode = :any @verify_strict SlowMetric3 guarantees = (:noalloc,) begin
        score3(ms, xs)
    end

    # An unstable call still stops the block under :typestable.
    struct BadMetric3 end
    const G3 = Ref{Any}(1.0)
    score3(::BadMetric3, xs::AbstractVector{<:Real}) = G3[]
    bm = BadMetric3()
    @test_throws StrictViolation @verify_strict BadMetric3 guarantees = (:typestable,) begin
        score3(bm, xs)
    end
    StrictMode.clear_declarations!()
end


# Regression: `@strict_contract` forwarded only 2 arguments to `TypeContracts.@contract`, so the
# 3-argument (type, description, block) form — which @contract has always supported — failed with a
# MethodError on the macro itself. Per-method `=> "doc"` and `:optional` were never affected (they are
# inside the block, forwarded verbatim); the gap was exactly the interface-level description.
@testitem "@strict_contract accepts an interface description and per-method docs" begin
    using StrictMode, TypeContracts
    abstract type _SCDescIface end
    abstract type _SCDocIface end

    # 3-arg form: description between the type and the block
    @strict_contract _SCDescIface "an entity that can vocalize" begin
        _sc_speak(::Self)::String
    end
    @test _SCDescIface in StrictMode.registered_strict_contracts()
    @test occursin("vocalize", TypeContracts._contract_desc(_SCDescIface))

    # 2-arg form still works, and per-method `=>` docs + `:optional` pass through the block
    @strict_contract _SCDocIface begin
        _sc_area(::Self)::Float64 => "area enclosed by the shape"
        :optional
        _sc_name(::Self)::String => "human-readable name"
    end
    @test _SCDocIface in StrictMode.registered_strict_contracts()

    # a non-literal description is a clear error, not a confusing macro MethodError
    @test_throws LoadError @eval @strict_contract _SCDescIface (1 + 1) begin
        _sc_speak(::Self)::String
    end
end
