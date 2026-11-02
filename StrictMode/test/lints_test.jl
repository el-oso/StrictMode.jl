@testitem "bang_report finds a name and its mutation disagreeing" begin
    using StrictMode

    module BangSubject
    copy_into!(d::Vector{Float64}, s::Vector{Float64}) = (d .= s; d)   # honest
    liar!(a::Vector{Float64}) = sum(a)                                 # `!`, writes nothing
    sneaky(a::Vector{Float64}) = (a[1] = 0.0; a)                       # writes, no `!`
    pure(v::Vector{Float64}) = sum(v)                                  # honest
    end
    S = BangSubject
    S.copy_into!(zeros(2), ones(2)); S.liar!(ones(2)); S.sneaky(zeros(2)); S.pure(ones(2))

    by = Dict(f.func => f for f in bang_report(S))
    @test Set(keys(by)) == Set(["liar!", "sneaky"])      # the two honest names are silent
    @test all(f -> f.status === :info && f.code === :SM0305, values(by))

    @test occursin("does not end in `!`", by["sneaky"].reason)
    @test occursin("rename it `sneaky!`", by["sneaky"].suggestion)
    @test occursin("no argument is written", by["liar!"].reason)
    # The weaker direction says so where a reader will see it, because mutation through a callee
    # the scan cannot follow reads as no mutation.
    @test occursin("Check by hand", by["liar!"].suggestion)

    @test isempty(bang_report(S; exempt = (:liar!, :sneaky)))
end

@testitem "specialization_report reports counts and depth against the limits given" begin
    using StrictMode

    module SpecSubject
    nested(v::Vector{Vector{Tuple{Int, Int}}}) = length(v)
    shallow(x::Int) = x + 1
    generic(x) = x
    end
    S = SpecSubject
    S.nested([[(1, 2)]]); S.shallow(1)
    for v in (1, 1.0, "a", :b, 1 // 2, 0x01, 1.0f0, true)
        S.generic(v)
    end

    deep = only(filter(f -> f.func == "nested", specialization_report(S; max_type_depth = 3)))
    @test deep.status === :info && deep.code === :SM0306
    @test occursin("type-parameter depth 4 (limit 3)", deep.reason)
    @test occursin("where the time goes, not", deep.suggestion)   # it does not claim a defect

    # A generous limit reports nothing: the numbers are the caller's to choose.
    @test isempty(filter(f -> f.func == "nested", specialization_report(S; max_type_depth = 9)))

    # The count limit is judged separately from depth.
    counted = filter(f -> f.func == "generic", specialization_report(S; max_specializations = 2, max_type_depth = 99))
    @test !isempty(counted)
    @test occursin("compiled specializations (limit 2)", only(counted).reason)

    @test_throws "max_specializations must be at least 1" specialization_report(S; max_specializations = 0)
    @test_throws "max_type_depth must be at least 1" specialization_report(S; max_type_depth = 0)
end

@testitem "_type_depth measures nesting, not breadth" begin
    using StrictMode

    @test StrictMode._type_depth(Int) == 0
    @test StrictMode._type_depth(Vector{Int}) == 1
    @test StrictMode._type_depth(Vector{Vector{Int}}) == 2
    @test StrictMode._type_depth(Tuple{Int, Int, Int, Int}) == 1       # breadth is not depth
    @test StrictMode._type_depth(Vector{Vector{Tuple{Int, Int}}}) == 3
    @test StrictMode._type_depth(Union{Int, Float64}) == 1
    @test StrictMode._type_depth(Vector{T} where {T}) >= 1             # a UnionAll reads its body
end

@testitem "the `!` convention is read through Julia's keyword mangling" begin
    using StrictMode

    module BangKw
    # The author wrote the `!`. Julia's keyword lowering moves the body into a method named
    # `#blend!#NN`, whose name ends in a digit.
    function blend!(out::Vector{Float64}, src::Vector{Float64}; w::Float64 = 1.0)
        for i in eachindex(out, src)
            out[i] = src[i] * w
        end
        return out
    end
    # No `!`, takes keywords, and writes an argument: this one is a genuine finding, and the
    # suggestion has to name something the author can rename.
    function mix(out::Vector{Float64}, src::Vector{Float64}; w::Float64 = 1.0)
        for i in eachindex(out, src)
            out[i] = src[i] + w
        end
        return out
    end
    end
    BangKw.blend!(zeros(3), ones(3))
    BangKw.mix(zeros(3), ones(3))

    fs = StrictMode.bang_report(BangKw)
    # A raw name test reports every keyword-taking `f!` as a mutating method that forgot its `!`.
    @test !any(f -> StrictMode._demangle(Symbol(f.func)) === :blend!, fs)
    # The real finding survives on both of the methods a keyword definition creates, and the
    # rename it suggests is one the author can actually write.
    mixed = filter(f -> StrictMode._demangle(Symbol(f.func)) === :mix, fs)
    @test length(mixed) == length(fs) == 2
    @test all(f -> occursin("does not end in `!`", f.reason), mixed)
    @test all(f -> occursin("`mix!`", f.suggestion), mixed)
end
