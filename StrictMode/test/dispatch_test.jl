# Cause classification and `dispatch_report`. Inference resolves a call while at most `max_methods`
# methods match it; the next method turns the call dynamic wherever it is called from.

@testitem "_instability_cause names the declaration to edit" begin
    using StrictMode
    NONCONST = 2.0
    const CONSTG = 2.0
    struct AbsField
        x::Real
    end
    struct ConcField
        x::Float64
    end
    abstract type Shape end
    for (i, nm) in enumerate((:S1, :S2, :S3, :S4))
        @eval struct $nm <: Shape
            v::Float64
        end
        @eval area(s::$nm) = s.v * $i
    end

    readglobal(y::Float64) = y * NONCONST
    readconst(y::Float64) = y * CONSTG
    readabs(a::AbsField) = a.x + 1.0
    readcon(a::ConcField) = a.x + 1.0
    sumany(v::Vector{Any}) = (
        t = 0.0; for x in v
            t += x::Float64
        end; t
    )
    refl(x::Int) = Base.return_types(sin, (Float64,))[x]      # returns Any: reflection decides the type
    fourmeth(s::Shape) = area(s)

    readglobal(1.0); readconst(1.0); readabs(AbsField(1.0)); readcon(ConcField(1.0))
    sumany(Any[1.0]); refl(1); fourmeth(S1(1.0))

    @test StrictMode._instability_cause(readglobal, (Float64,))[1] === :nonconst_global
    @test StrictMode._instability_cause(readabs, (AbsField,))[1] === :abstract_field
    @test StrictMode._instability_cause(sumany, (Vector{Any},))[1] === :abstract_eltype
    @test StrictMode._instability_cause(refl, (Int,))[1] === :reflection
    @test StrictMode._instability_cause(fourmeth, (Shape,))[1] === :method_count

    # A declaration on its own causes nothing: these are stable, so there is no cause to name.
    @test isnothing(StrictMode._instability_cause(readconst, (Float64,)))
    @test isnothing(StrictMode._instability_cause(readcon, (ConcField,)))

    # The subject is specific enough to act on.
    @test occursin("NONCONST", StrictMode._instability_cause(readglobal, (Float64,))[2])
    @test occursin("Real", StrictMode._instability_cause(readabs, (AbsField,))[2])
    @test occursin("limit $(StrictMode._max_methods())", StrictMode._instability_cause(fourmeth, (Shape,))[2])
end

@testitem "a :typestable finding carries the cause and its matching fix" begin
    using StrictMode
    BACKEND = 2.0
    scaled(x::Float64) = x * BACKEND
    scaled(1.0)
    f = only(findings(scaled, (Float64,); guarantees = (:typestable,)))
    @test StrictMode._failed(f)
    @test occursin("non-const global", f.reason)
    @test occursin("BACKEND", f.reason)
    @test occursin("`const`", f.suggestion)
    # The generic hint must NOT be what the user sees when the cause is known.
    @test !occursin("annotate the unstable variable", f.suggestion)
end

@testitem "dispatch_report: at the limit today, dynamic when one method is added" begin
    using StrictMode
    module Cliff
    abstract type Shape end
    for (i, nm) in enumerate((:T1, :T2, :T3))
        @eval struct $nm <: Shape
            v::Float64
        end
        @eval area(s::$nm) = s.v * $i
    end
    struct T4 <: Shape          # a fourth subtype with no `area` method yet
        v::Float64
    end
    total(v::Vector{Shape}) = (
        t = 0.0; for s in v
            t += area(s)
        end; t
    )
    end
    Cliff.total(Cliff.Shape[Cliff.T1(1.0)])

    limit = StrictMode._max_methods()
    r1 = dispatch_report(Cliff)
    @test r1.limit == limit
    # Three methods match, which is exactly the limit: static today, one method from dynamic.
    @test any(s -> s.func == "total" && s.callee == "area", r1.cliff)
    @test isempty(filter(s -> s.callee == "area", r1.dynamic))
    @test occursin("AT THE LIMIT", sprint(show, r1))

    # The hazard is non-local: `total` is not edited, and a method added elsewhere flips it.
    @eval Cliff area(s::T4) = s.v * 4.0
    Cliff.total(Cliff.Shape[Cliff.T4(1.0)])
    r2 = dispatch_report(Cliff)
    @test any(s -> s.func == "total" && s.callee == "area", r2.dynamic)
    @test isempty(filter(s -> s.callee == "area", r2.cliff))
end

@testitem "dispatch_report counts a clean module as clear" begin
    using StrictMode
    module Clean
    add(x::Float64, y::Float64) = x + y
    scale(x::Float64) = 2.0 * x
    end
    Clean.add(1.0, 2.0); Clean.scale(1.0)
    r = dispatch_report(Clean)
    @test isempty(r.dynamic)
    @test isempty(r.cliff)
    @test r.nclear >= 2
    @test occursin("CLEAR", sprint(show, r))
end

@testitem "a cause is only reported for a body that is actually unstable" begin
    using StrictMode
    G = 1.0                                   # untyped, non-const
    global TG::Int = 3                        # typed: the read is concrete
    struct SmallU
        x::Union{Int, Nothing}                # splittable union: rides unboxed
    end
    lenonly(v::Vector{Real}) = length(v)      # abstract eltype DECLARED, none flows
    lenplusG(v::Vector{Real}) = length(v) + G
    readTG(x::Int) = x + TG
    readsmall(s::SmallU) = isnothing(s.x) ? 0 : s.x
    lenonly(Real[1]); lenplusG(Real[1]); readTG(1); readsmall(SmallU(1))

    # `length(::Vector{Real})` is stable, so its argument declaration is not to blame.
    @test isnothing(StrictMode._instability_cause(lenonly, (Vector{Real},)))
    @test isnothing(StrictMode._instability_cause(readTG, (Int,)))
    @test isnothing(StrictMode._instability_cause(readsmall, (SmallU,)))
    # Declarations outrank method counts: the widened global is the root, `+` matching many methods
    # on an `Any` argument is its consequence.
    @test StrictMode._instability_cause(lenplusG, (Vector{Real},))[1] === :nonconst_global
end

@testitem "_instability_cause: captured variables, runtime type parameters, non-array containers" begin
    using StrictMode
    boxed() = (t = 0; f = () -> (t += 1); f(); f(); t)
    tup(n::Int) = ntuple(i -> i, n)
    sumdict(d::Dict{String, Any}) = (
        t = 0.0; for (_, v) in d
            t += v::Float64
        end; t
    )
    boxed(); tup(3); sumdict(Dict{String, Any}("a" => 1.0))

    @test StrictMode._instability_cause(boxed, ())[1] === :captured_variable
    @test StrictMode._instability_cause(tup, (Int,))[1] === :runtime_type_parameter
    # A `Dict` payload is the same mistake as a `Vector{Any}` element, and must be named too.
    @test StrictMode._instability_cause(sumdict, (Dict{String, Any},))[1] === :abstract_eltype
    @test occursin("Dict", StrictMode._instability_cause(sumdict, (Dict{String, Any},))[2])
end

@testitem "dispatch_report honors a raised max_methods and reports an unknown callee" begin
    using StrictMode
    module Raised
    Base.Experimental.@max_methods 4
    abstract type S end
    for (i, nm) in enumerate((:A, :B, :C, :D))
        @eval struct $nm <: S
            v::Float64
        end
        @eval area(s::$nm) = s.v * $i
    end
    total(v::Vector{S}) = (
        t = 0.0; for s in v
            t += area(s)
        end; t
    )
    end
    Raised.total(Raised.S[Raised.A(1.0)])
    @test StrictMode._max_methods(Raised.area) == 4
    @test StrictMode._max_methods() == 3
    r = dispatch_report(Raised)
    # Four methods, and the module raised the limit to four: static, and AT the raised limit. Reading
    # the global 3 instead would drop this site entirely.
    @test any(s -> s.callee == "area" && occursin("limit 4", s.detail), r.cliff)
    @test isempty(filter(s -> s.callee == "area", r.dynamic))

    module Hidden
    struct Holder
        fn::Function            # the callee is not known statically
    end
    apply(h::Holder, x::Float64) = h.fn(x)
    end
    Hidden.apply(Hidden.Holder(sin), 1.0)
    r2 = dispatch_report(Hidden)
    @test any(s -> occursin("not statically known", s.detail), r2.dynamic)
end

@testitem "audit carries dispatch findings by default" begin
    using StrictMode
    module Dyn
    abstract type S end
    for (i, nm) in enumerate((:A, :B, :C, :D))
        @eval struct $nm <: S
            v::Float64
        end
        @eval area(s::$nm) = s.v * $i
    end
    total(v::Vector{S}) = (
        t = 0.0; for s in v
            t += area(s)
        end; t
    )
    end
    Dyn.total(Dyn.S[Dyn.A(1.0)])
    fs = audit(Dyn; sweep = true, io = devnull)                     # on by default
    ds = filter(f -> f.guarantee === :dispatch, fs)
    @test !isempty(ds)
    # Advisory only: a dispatch finding never counts as a failure.
    @test all(f -> f.status === :info, ds)
    @test !any(StrictMode._failed, ds)
    # And it can be turned off, for a sweep that does not want the extra typed-IR read.
    @test isempty(filter(f -> f.guarantee === :dispatch, audit(Dyn; sweep = true, dispatch_suggest = false, io = devnull)))
end
