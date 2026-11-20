@testitem "findings reads a callable object from its signature type" begin
    using StrictMode
    module Functors
    using StrictMode
    struct Bits
        k::Int
    end
    (b::Bits)(x::Vector{Float64}) = (s = 0.0; for v in x; s += v * b.k; end; s)
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
    boxed = [f for f in fs if f.func == "Boxed" && f.guarantee === :typestable]
    @test sort([f.status for f in boxed]) == [:fail, :pass]
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
