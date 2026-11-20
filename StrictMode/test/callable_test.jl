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
