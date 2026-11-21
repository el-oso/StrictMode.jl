@testitem "findings reads a callable object from its signature type" begin
    using StrictMode
    module Functors
    using StrictMode
    struct Bits
        k::Int
    end
    (b::Bits)(x::Vector{Float64}) = (
        s = 0.0; for v in x
            s += v * b.k
        end; s
    )
    mutable struct Mut
        k::Any
    end
    (m::Mut)(x::Int) = x + m.k
    struct Boxed{T}
        v::Vector{T}
    end
    (b::Boxed)(x::Int) = b.v[1] + x
    end
    F = Functors
    F.Bits(2)([1.0]); F.Mut(1)(1); F.Boxed([1])(1); F.Boxed(Any[1])(1)
    G = StrictMode._GUARANTEES

    # The signature form reads what the instance form reads, guarantee by guarantee.
    for (f, tt) in ((F.Bits(2), (Vector{Float64},)), (F.Mut(1), (Int,)))
        a = findings(f, tt; guarantees = G)
        StrictMode.clear_cache!()
        b = findings(Tuple{typeof(f), tt...}; guarantees = G)
        @test [(x.guarantee, x.status, x.reason, x.code) for x in a] ==
            [(x.guarantee, x.status, x.reason, x.code) for x in b]
        # Named by its type in both forms, never by the printed value.
        @test all(x -> x.func == string(nameof(typeof(f))), vcat(a, b))
        @test all(x -> x.mod === :Functors, vcat(a, b))
    end
    @test !any(StrictMode._failed, findings(Tuple{F.Bits, Vector{Float64}}))
    bad = findings(Tuple{F.Mut, Int})
    @test all(StrictMode._failed, bad)
    @test [x.guarantee for x in bad] == [:typestable, :noalloc]

    # One method serves `Boxed{Int}` and `Boxed{Any}`; the cache keeps their verdicts apart.
    StrictMode.clear_cache!()
    @test !any(StrictMode._failed, findings(Tuple{F.Boxed{Int}, Int}; guarantees = (:typestable,)))
    @test all(StrictMode._failed, findings(Tuple{F.Boxed{Any}, Int}; guarantees = (:typestable,)))
    @test all(StrictMode._failed, findings(F.Boxed(Any[1]), (Int,); guarantees = (:typestable,)))

    # A signature nothing matches is a failing "could not check", not a pass.
    none = findings(Tuple{F.Bits, String}; guarantees = G)
    @test length(none) == length(G)
    @test all(StrictMode._failed, none)
    @test all(x -> occursin("no typed body", x.reason), none)
    @test_throws "without free type parameters" findings(Tuple{F.Boxed{T}, Int} where {T})
end

@testitem "a module sweep checks the methods of its callable objects" begin
    using StrictMode
    module SweepCallables
    using StrictMode
    struct Bits                       # an isbits field
        k::Int
    end
    (b::Bits)(n::Int) = fill(b.k, n)
    mutable struct Mut                # mutable, with a field of abstract type
        k::Any
    end
    (m::Mut)(x::Int) = x + m.k
    struct Vec                        # immutable, with a reference field
        v::Vector{Float64}
    end
    (c::Vec)(n::Int) = push!(copy(c.v), n)
    struct Clean
        k::Int
    end
    (c::Clean)(x::Int) = x + c.k
    struct Op end                     # a singleton that is not a Function
    (::Op)(n::Int) = zeros(n)
    struct Boxed{T}
        v::Vector{T}
    end
    (b::Boxed)(x::Int) = b.v[1] + x
    struct Cold
        k::Int
    end
    (c::Cold)(n::Int) = zeros(n)
    @strict_exempt Cold
    struct Narrow
        k::Int
    end
    (c::Narrow)(n::Int) = zeros(n)
    @strict_exempt Narrow guarantees = (:noalloc,)
    end
    S = SweepCallables
    S.Bits(1)(2); S.Mut(1)(1); S.Vec([1.0])(1); S.Clean(1)(1); S.Op()(1)
    S.Boxed([1])(1); S.Boxed(Any[1])(1); S.Cold(1)(1); S.Narrow(1)(1)

    # The census names each callable object's method.
    ms, _ = StrictMode.module_methods(S)
    for T in (S.Bits, S.Mut, S.Vec, S.Clean, S.Op, S.Boxed, S.Narrow)
        @test any(m -> StrictMode._method_function(m) <: T, ms)
    end
    @test !any(m -> StrictMode._method_function(m) <: S.Cold, ms)       # exempt

    fs = audit(S; sweep = true)
    rows(name) = [f for f in fs if f.func == name && f.guarantee in (:typestable, :noalloc)]
    for name in ("Bits", "Mut", "Vec", "Op")
        rs = rows(name)
        @test length(rs) == 2
        @test any(StrictMode._failed, rs)
        @test all(f -> f.mod === :SweepCallables && f.signature == "(Int64)", rs)
    end
    @test length(rows("Clean")) == 2
    @test !any(StrictMode._failed, rows("Clean"))
    # Two instantiations of one method: two rows, with their own verdicts.
    boxed = [f for f in fs if startswith(f.func, "Boxed") && f.guarantee === :typestable]
    @test sort([(f.func, f.status) for f in boxed]) == [("Boxed{Any}", :fail), ("Boxed{Int64}", :pass)]
    @test isempty(rows("Cold"))
    @test sort([(f.guarantee, f.status) for f in rows("Narrow")]) == [(:noalloc, :info), (:typestable, :pass)]
    # The advisories walk the same specializations.
    @test any(f -> f.func == "Mut", StrictMode.dispatch_suggestions(S))
    @test StrictMode.inline_suggestions(S) isa Vector{StrictFinding}
    @test StrictMode.static_ownership_suggestions(S) isa Vector{StrictFinding}

    # `only` and `exempt` name a callable object by its type.
    scoped = audit(S; sweep = true, only = (:Mut,), dispatch_suggest = false)
    @test !isempty(scoped)
    @test all(f -> f.func == "Mut", scoped)
    @test !any(f -> f.func == "Mut", audit(S; sweep = true, exempt = (:Mut,), dispatch_suggest = false))

    # A declaration made on an instance stamps the sweep's rows of that type with its source, as it
    # does its own rows: two from the registry and two from the sweep.
    StrictMode.register_strict!(S.Vec([2.0]), (Int,); source = "callable_test.jl:1")
    try
        stamped = [f for f in audit(S; sweep = true, only = (:Vec,), dispatch_suggest = false) if f.func == "Vec"]
        @test length(stamped) == 4
        @test all(f -> f.policy == "callable_test.jl:1", stamped)
    finally
        delete!(StrictMode.STRICT_REGISTRY, (only(k for k in keys(StrictMode.STRICT_REGISTRY) if k[1] isa S.Vec)))
    end
end

@testitem "a callable object's rows are named with its type parameters" begin
    using StrictMode
    module ParamRows
    using StrictMode
    struct Boxed{T}
        v::Vector{T}
    end
    (b::Boxed)(n::Int) = fill(b.v[1], n)
    end
    P = ParamRows
    P.Boxed([1])(1); P.Boxed(Any[1])(1)

    fs = audit(P; sweep = true, dispatch_suggest = false)
    boxed = [f for f in fs if startswith(f.func, "Boxed") && f.guarantee === :noalloc]
    @test sort([f.func for f in boxed]) == ["Boxed{Any}", "Boxed{Int64}"]
    @test length(unique(StrictMode.key.(boxed))) == 2
    @test all(f -> f.mod === :ParamRows, boxed)
    # The instance and signature forms name the row the same way.
    @test all(x -> x.func == "Boxed{Int64}", findings(P.Boxed([1]), (Int,)))
    @test all(x -> x.func == "Boxed{Any}", findings(Tuple{P.Boxed{Any}, Int}))

    # Both instantiations fail `:noalloc`; a run that has only one of them failing is a different
    # set of failures, not the same one.
    int = filter(f -> f.func == "Boxed{Int64}", boxed)
    any_ = filter(f -> f.func == "Boxed{Any}", boxed)
    @test all(StrictMode._failed, vcat(int, any_))
    d = findings_diff(int, any_)
    @test length(d.introduced) == 1 && length(d.fixed) == 1 && isempty(d.unchanged) && isempty(d.changed)

    # `only` and `exempt` by name still match every instantiation.
    scoped = audit(P; sweep = true, only = (:Boxed,), dispatch_suggest = false)
    @test Set(f.func for f in scoped if f.guarantee === :noalloc) == Set(["Boxed{Int64}", "Boxed{Any}"])
    @test !any(f -> startswith(f.func, "Boxed"), audit(P; sweep = true, exempt = (:Boxed,), dispatch_suggest = false))
    @test Set(f.func for f in audit(P; sweep = true, only = r"^Box", dispatch_suggest = false) if f.guarantee === :noalloc) ==
        Set(["Boxed{Int64}", "Boxed{Any}"])
end

@testitem "a predicate only or exempt receives a callable object's type" begin
    using StrictMode
    module PredCallables
    using StrictMode
    struct Mut
        k::Any
    end
    (m::Mut)(x::Int) = x + m.k
    struct Boxed{T}
        v::Vector{T}
    end
    (b::Boxed)(n::Int) = fill(b.v[1], n)
    plain(n::Int) = zeros(n)
    end
    P = PredCallables
    P.Mut(1)(1); P.Boxed([1])(1); P.Boxed(Any[1])(1); P.plain(1)

    sweep(; kw...) = Set(f.func for f in audit(P; sweep = true, dispatch_suggest = false, kw...))
    # The predicate is asked with the type the method declares for its callable.
    seen = Any[]
    sweep(; only = f -> (push!(seen, f); true))
    @test P.Mut in seen && P.Boxed in seen && P.plain in seen

    @test sweep(; only = f -> f === P.Mut) == Set(["Mut"])
    @test sweep(; only = f -> f isa Type && f <: P.Boxed) == Set(["Boxed{Int64}", "Boxed{Any}"])
    @test isempty(sweep(; only = f -> f === Int))
    all_ = sweep()
    @test sweep(; exempt = f -> f === P.Mut) == setdiff(all_, ["Mut"])
    @test sweep(; exempt = f -> f === Int) == all_
    @test "Mut" in all_ && "plain" in all_

    # The census answers the same way.
    ms, _ = StrictMode.module_methods(P; only = f -> f === P.Boxed)
    @test length(ms) == 1 && StrictMode._method_function(only(ms)) <: P.Boxed
    ms, _ = StrictMode.module_methods(P; exempt = f -> f === P.Boxed)
    @test !any(m -> StrictMode._method_function(m) <: P.Boxed, ms)
end
