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

@testitem "@verify_strict signature lines name types instead of values" begin
    using StrictMode
    using TypeContracts

    StrictMode.clear_declarations!()
    @strict_contract AbstractKernel4 begin
        apply4(::Self, xs::AbstractVector{<:Real})::Real
    end
    function apply4 end
    struct Kernel4 end
    apply4(::Kernel4, xs::AbstractVector{<:Real}; alpha::Float64 = 1.0, beta::Float64 = 0.0, shift = 0) =
        alpha * xs[begin] + beta + shift

    gs = (:typestable,)
    decls() = Set(keys(StrictMode.declarations()))

    # No keywords: the declaration an example call with those types registers.
    @verify_strict Kernel4 guarantees = gs begin
        apply4(::Kernel4, ::Vector{Float64})
    end
    @test decls() == Set([(apply4, (Kernel4, Vector{Float64}))])

    # Keywords in declaration order, in another order, and as an example call: one declaration.
    k = Kernel4()
    xs = [1.0, 2.0]
    NT = @NamedTuple{alpha::Float64, beta::Float64}
    kwsig = (Core.kwcall, (NT, typeof(apply4), Kernel4, Vector{Float64}))
    for block in (
            :(apply4(::Kernel4, ::Vector{Float64}; alpha::Float64, beta::Float64)),
            :(apply4(::Kernel4, ::Vector{Float64}; beta::Float64, alpha::Float64)),
            :(apply4(k, xs; alpha = 2.0, beta = 1.0)),
        )
        StrictMode.clear_declarations!()
        @eval @verify_strict Kernel4 guarantees = $gs begin
            $block
        end
        @test decls() == Set([kwsig])
        @test StrictMode.declarations()[kwsig].guarantees == gs
    end

    # An omitted keyword is absent from the NamedTuple, so the sorter supplies its default; the
    # listed one keeps the type the line gives it, not the default's.
    StrictMode.clear_declarations!()
    @verify_strict Kernel4 guarantees = gs begin
        apply4(::Kernel4, ::Vector{Float64}; shift::Float64)
    end
    onekw = (Core.kwcall, (@NamedTuple{shift::Float64}, typeof(apply4), Kernel4, Vector{Float64}))
    @test decls() == Set([onekw])
    @test Base.return_types(onekw...) == [Float64]

    # Signature lines and call lines in one block, in the form without `guarantees` too.
    StrictMode.clear_declarations!()
    @verify_strict Kernel4 guarantees = gs begin
        apply4(::Kernel4, ::Vector{Float64}; beta::Float64, alpha::Float64)
        apply4(k, xs)
        apply4(::Kernel4, ::Vector{Float32})
    end
    @test decls() == Set([kwsig, (apply4, (Kernel4, Vector{Float64})), (apply4, (Kernel4, Vector{Float32}))])
    @test_logs @verify_strict Kernel4 begin
        apply4(::Kernel4, ::Vector{Float64}; beta::Float64, alpha::Float64)
        apply4(k, xs; shift = 1)
    end
    StrictMode.clear_declarations!()
end

@testitem "@verify_strict signature lines reject what no call could be" begin
    using StrictMode
    using TypeContracts

    @strict_contract AbstractKernel5 begin
        apply5(::Self, xs::AbstractVector{<:Real})::Real
    end
    function apply5 end
    struct Kernel5 end
    apply5(::Kernel5, xs::AbstractVector{<:Real}; alpha::Float64 = 1.0) = alpha * xs[begin]
    struct Splat5 end
    apply5(::Splat5, xs::AbstractVector{<:Real}; alpha::Float64 = 1.0, rest...) = alpha * xs[begin]
    k = Kernel5()

    for gs in (nothing, (:typestable,))
        opt = isnothing(gs) ? () : (:(guarantees = $gs),)
        verify(T, line) = @eval @verify_strict $T $(opt...) begin
            $line
        end
        # An undeclared keyword, also where the method takes `rest...`.
        @test_throws "keyword `uplo` in `apply5(::Kernel5, ::Vector{Float64}; uplo::Char)` is not declared" verify(
            :Kernel5, :(apply5(::Kernel5, ::Vector{Float64}; uplo::Char))
        )
        @test_throws "declared keywords: alpha" verify(:Splat5, :(apply5(::Splat5, ::Vector{Float64}; uplo::Char)))
        @test_throws "listed more than once" verify(
            :Kernel5, :(apply5(::Kernel5, ::Vector{Float64}; alpha::Float64, alpha::Float64))
        )
        # A positional signature no method matches, with and without keywords.
        @test_throws "no method matches" verify(:Kernel5, :(apply5(::Kernel5, ::String; alpha::Float64)))
        @test_throws "no method matches" verify(:Kernel5, :(apply5(::Kernel5, ::String)))
        # A line that is half signature, half call.
        @test_throws "mixes a signature with an example call" verify(:Kernel5, :(apply5(k, ::Vector{Float64})))
        @test_throws "mixes a signature with an example call" verify(
            :Kernel5, :(apply5(::Kernel5, ::Vector{Float64}; alpha = 1.0))
        )
        @test_throws "mixes a signature with an example call" verify(:Kernel5, :(apply5(k, [1.0]; alpha::Float64)))
    end

    amb5(x::Integer, y; a = 1) = 1
    amb5(x, y::Integer; a = 1) = 2
    @test_throws "more than one method matches" StrictMode._signature_kwcall_types(
        amb5, (Int, Int), (:a,), (Int,), "amb5(::Int, ::Int; a::Int)"
    )
    StrictMode.clear_declarations!()
end

@testitem "@verify_strict signature lines check the keyword body" begin
    using StrictMode
    using TypeContracts

    StrictMode.clear_declarations!()
    @strict_contract AbstractKernel6 begin
        apply6(::Self, xs::AbstractVector{<:Real})::Real
    end
    function apply6 end

    # The allocation and the instability are in the keyword body: the positional method only
    # forwards the defaults to it.
    struct Alloc6 end
    apply6(::Alloc6, xs::AbstractVector{<:Real}; scale::Float64 = 1.0) = scale * sum(collect(xs))
    @test_logs (:warn, r"noalloc.*kwcall.*scale::Float64") match_mode = :any @verify_strict Alloc6 guarantees = (:noalloc,) begin
        apply6(::Alloc6, ::Vector{Float64}; scale::Float64)
    end
    @test_logs (:warn,) match_mode = :any @verify_strict Alloc6 begin
        apply6(::Alloc6, ::Vector{Float64}; scale::Float64)
    end

    struct Unstable6 end
    const G6 = Ref{Any}(1.0)
    apply6(::Unstable6, xs::AbstractVector{<:Real}; scale::Float64 = 1.0) = G6[]
    @test_throws StrictViolation @verify_strict Unstable6 guarantees = (:typestable,) begin
        apply6(::Unstable6, ::Vector{Float64}; scale::Float64)
    end
    @test_throws StrictViolation @verify_strict Unstable6 begin
        apply6(::Unstable6, ::Vector{Float64}; scale::Float64)
    end
    StrictMode.clear_declarations!()
end

@testitem "@verify_strict registers the same declarations at top level, in a let and in a function" begin
    using StrictMode
    using TypeContracts

    @strict_contract AbstractKernel7 begin
        apply7(::Self, xs::AbstractVector{<:Real})::Real
    end
    function apply7 end
    struct Kernel7 end
    apply7(::Kernel7, xs::AbstractVector{<:Real}; alpha::Float64 = 1.0, shift = 0) = alpha * xs[begin] + shift

    const K7 = Kernel7()
    xs7 = [1.0, 2.0]
    decls() = Dict(k => v.guarantees for (k, v) in StrictMode.declarations())

    StrictMode.clear_declarations!()
    @verify_strict Kernel7 guarantees = (:typestable,) begin
        apply7(::Kernel7, ::Vector{Float32})
        apply7(::Kernel7, ::Vector{Float64}; shift::Int, alpha::Float64)
        apply7(K7, xs7)
        apply7(K7, xs7; alpha = 2.0)
    end
    top = decls()
    @test length(top) == 4

    StrictMode.clear_declarations!()
    let k = Kernel7(), ys = [3.0]
        @verify_strict Kernel7 guarantees = (:typestable,) begin
            apply7(::Kernel7, ::Vector{Float32})
            apply7(::Kernel7, ::Vector{Float64}; shift::Int, alpha::Float64)
            apply7(k, ys)
            apply7(k, xs7; alpha = 2.0)
        end
    end
    @test decls() == top

    function in_function(k, ys)
        a = 2.0
        @verify_strict Kernel7 guarantees = (:typestable,) begin
            apply7(::Kernel7, ::Vector{Float32})
            apply7(::Kernel7, ::Vector{Float64}; shift::Int, alpha::Float64)
            apply7(k, ys)
            apply7(K7, ys; alpha = a)
        end
    end
    StrictMode.clear_declarations!()
    @test isnothing(in_function(Kernel7(), [4.0]))
    @test decls() == top

    # A block at top level leaves the world age where it found it. Each line binds its callee and
    # arguments, and a binding that became a global would advance it once per name.
    for opt in ((), (:(guarantees = (:typestable,)),))
        block = :(
            @verify_strict Kernel7 $(opt...) begin
                apply7(::Kernel7, ::Vector{Float32})
                apply7(K7, xs7; alpha = 2.0)
            end
        )
        @test isnothing(Core.eval(@__MODULE__, block))
        world = Base.get_world_counter()
        Core.eval(@__MODULE__, block)
        @test Base.get_world_counter() == world
    end
    StrictMode.clear_declarations!()
end
