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

@testitem "bang_report sees a write through a raw pointer" begin
    using StrictMode
    module BangPtr
    ptrset!(x::Vector{Float64}) = (GC.@preserve x unsafe_store!(pointer(x), 1.0); x)
    end
    x = [0.0]
    BangPtr.ptrset!(x)
    @test x[1] == 1.0
    @test !any(f -> occursin("no argument is written", string(f)), StrictMode.bang_report(BangPtr))
end

@testitem "alias_guard_report credits a guard only to the method that wrote it" begin
    using StrictMode
    module GuardSiblings
    fill_from!(a::AbstractVector, b::AbstractVector) = (a .= b; a)
    fill_from!(a::Vector{Float64}, b::Vector{Float64}) = (copyto!(a, Base.unalias(a, b)); a)
    end
    fs = filter(f -> f.func == "fill_from!", alias_guard_report(GuardSiblings))
    @test length(fs) == 1
    @test occursin("AbstractVector", only(fs).signature)
end

@testitem "a module sweep names a callable object by its type" begin
    using StrictMode
    module WithFunctor
    struct Scale end
    (::Scale)(x) = 2x
    end
    ms, _ = StrictMode.module_methods(WithFunctor)
    @test any(m -> m.sig <: Tuple{WithFunctor.Scale, Any}, ms)
    @test StrictMode._callable_name(WithFunctor.Scale()) === :Scale
    @test first(StrictMode._reach_key(WithFunctor.Scale())) === WithFunctor
end

@testitem "a sweep filtered by name scopes a capturing closure by the function it is in" begin
    using StrictMode
    module ClosureScope
    wanted(x) = x + 1
    function other(p::Ptr{Float64}, n)
        helper(i) = unsafe_load(p, i)       # captures `p`: no singleton instance
        s = 0.0
        for i in 1:n
            s += helper(i)
        end
        s
    end
    end
    @test isempty(unsafe_report(ClosureScope; only = [:wanted]))
    @test [f.func for f in unsafe_report(ClosureScope; only = [:other])] == ["helper"]
    @test isempty(unsafe_report(ClosureScope; exempt = [:other]))
end

@testitem "a body that cannot be read is :fail, and conversion_report does not crash on it" begin
    using StrictMode
    module GenRaises
    @generated g(p::Ptr{T}, a::Float32) where {T} = T === Any ? error("no body for Any") : :(a)
    end
    GenRaises.g(Ptr{Float64}(0), 1f0)
    G = (:typestable, :noalloc, :noboxing)
    fs = StrictMode.findings(GenRaises.g, (Ptr{Any}, Float32); guarantees = G)
    @test all(StrictMode._failed, fs)
    @test all(f -> occursin("no typed body", f.reason), fs)
    @test !any(StrictMode._failed, StrictMode.findings(GenRaises.g, (Ptr{Float64}, Float32); guarantees = G))
    @test isempty(StrictMode._conversions(GenRaises.g, (Ptr{Any}, Float32)))
end

@testitem "a constructor and an anonymous closure answer to their own and their owner's names" begin
    using StrictMode
    module Names8
    struct Box3; v::Vector{Float64}; end
    Box3(n::Int) = Box3(zeros(n))
    struct Par{T}; x::T; end
    outer2(v, k) = sum(map(i -> v[i] * k, 1:3))
    end
    Names8.outer2([1.0, 2, 3], 2.0)
    @test StrictMode._callable_name(Names8.Box3) === :Box3
    @test StrictMode._callable_name(Names8.Par{Float64}) === :Par
    @test StrictMode._name_matcher([:Box3])(Names8.Box3)
    inscope(only) = sort([string(m.name) for m in first(StrictMode.module_methods(Names8; only))])
    @test any(startswith("#outer2"), inscope([:outer2]))
    @test !any(startswith("#outer2"), inscope([:Box3]))
end

@testitem "every guarantee fails on a body that cannot be read, in findings and the macros" begin
    using StrictMode
    module Unread5
    @generated gen(x) = (x <: Integer || error("only integers"); :(x + 1))
    nomethod(x::Int) = x
    end
    Unread5.gen(1)
    @test all(StrictMode._failed, StrictMode.findings(Unread5.gen, (Float64,); guarantees = StrictMode._GUARANTEES))
    @test all(StrictMode._failed, StrictMode.findings(Unread5.nomethod, (String,); guarantees = (:typestable, :owned)))
    @test_throws StrictMode.StrictViolation StrictMode._assert_owned("t", Unread5.gen, (Float64,))
end

@testitem "a call checked but not performed fails when no method matches it" begin
    using StrictMode
    macro checked_only(c); StrictMode._strict_expr(c; execute = false); end
    module NoMethod4
    f(x::Int) = x
    const G = Ref{Any}(1)
    unstable(x::Int) = G[]
    end
    @test_throws "no method matches this call" @checked_only NoMethod4.f("s")
    @test_throws "not concrete" @checked_only NoMethod4.unstable(1)
end
