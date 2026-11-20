@testitem "the proofs check a callable object from its type" begin
    using StrictMode, StrictModeTest
    module ProofCallables
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
    end
    P = ProofCallables
    P.Bits(1)(2); P.Mut(1)(1); P.Vec([1.0])(1); P.Clean(1)(1)
    G = (:typestable, :noalloc)

    # The proof of the signature is the proof of an instance: same verdicts, reasons and sites.
    for (f, tt) in ((P.Bits(1), (Int,)), (P.Mut(1), (Int,)), (P.Vec([1.0]), (Int,)), (P.Clean(1), (Int,)))
        a = proof_findings(f, tt; guarantees = G)
        b = proof_findings(StrictMode._callee(typeof(f)), tt; guarantees = G)
        @test [(x.status, x.reason, x.file, x.line) for x in a] == [(x.status, x.reason, x.file, x.line) for x in b]
        @test all(x -> x.func == string(nameof(typeof(f))), b)
    end

    fs = proof_audit(P; sweep = true, dispatch_suggest = false)
    for name in ("Bits", "Mut", "Vec")
        rs = [f for f in fs if f.func == name]
        @test length(rs) == 2
        @test any(StrictMode._failed, rs)
        @test all(f -> f.tier === :proof, rs)
    end
    @test !any(StrictMode._failed, [f for f in fs if f.func == "Clean"])
    @test length([f for f in fs if f.func == "Clean"]) == 2

    err = try
        test_compiled(P; guarantees = G)
        nothing
    catch e
        e
    end
    @test err isa StrictViolation
    msg = sprint(showerror, err)
    @test all(n -> occursin("] " * n * " (Int64)", msg), ("Bits", "Mut", "Vec"))
    @test !occursin("Clean", msg)
    @test length(test_compiled(P; guarantees = G, only = (:Clean,))) == 2

    # A signature nothing matches is unproven, never proved.
    none = proof_findings(StrictMode._callee(P.Clean), (String,); guarantees = G)
    @test all(StrictMode._failed, none)
end

@testitem "an exempt callable object is excused by its type in the proofs" begin
    using StrictMode, StrictModeTest
    module ExemptCallable
    using StrictMode
    struct Pool
        k::Int
    end
    @noinline (p::Pool)(n::Int) = zeros(n + p.k)
    @strict_exempt Pool guarantees = (:noalloc,) reason = "grows once"
    user(n::Int) = sum(Pool(1)(n))
    end
    E = ExemptCallable
    E.user(2)
    # The callable's own row is the exemption's note; its caller allocates only inside it.
    fs = proof_audit(E; sweep = true, guarantees = (:noalloc,), dispatch_suggest = false)
    pool = only(f for f in fs if f.func == "Pool")
    @test pool.status === :info
    u = only(f for f in fs if f.func == "user")
    @test u.code === :SM0018
    @test u.exempt_by == ("Pool" => "grows once",)
end
