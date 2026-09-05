# The drivers that gate a whole scope, and the data half that reports without throwing.

@testitem "the drivers collect every failure and raise once" setup = [Fixtures] begin
    using StrictMode, StrictModeTest
    err = try
        test_signatures(
            [(Fixtures.clean, Fixtures.T3), (Fixtures.allocs, (Int,)), (Fixtures.boxy, Fixtures.THET)];
            guarantees = (:noalloc,)
        )
        nothing
    catch e
        e
    end
    @test err isa StrictViolation
    # Both failing signatures must appear: a gate that stops at the first bad method leaves the rest
    # unevaluated, which is how a sweep reports less than it checked.
    @test occursin("allocs", err.details)
    @test occursin("boxy", err.details)
end

@testitem "test_registered reports its count and re-proves the registry" setup = [Fixtures] begin
    using StrictMode, StrictModeTest
    old = copy(StrictMode.STRICT_REGISTRY)
    try
        empty!(StrictMode.STRICT_REGISTRY)
        StrictMode.register_strict!(Fixtures.clean, Fixtures.T3; guarantees = (:noalloc,))
        @test_logs (:info,) match_mode = :any test_registered()
        StrictMode.register_strict!(Fixtures.allocs, (Int,); guarantees = (:noalloc,))
        @test_throws StrictViolation test_registered()
    finally
        empty!(StrictMode.STRICT_REGISTRY)
        merge!(StrictMode.STRICT_REGISTRY, old)
    end
end

@testmodule ProofAuditDemo begin
    hot(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    cold(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
end

@testitem "proof_findings / proof_audit return proved verdicts as DATA" setup = [ProofAuditDemo] begin
    using StrictMode, StrictModeTest
    ProofAuditDemo.hot((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
    ProofAuditDemo.cold((1, 2.0, 3.0f0))

    # `test_compiled` throws on this module, so it cannot hand back findings for it — which is
    # exactly the case an agent wants them in. `proof_findings`/`proof_audit` are the data half.
    @test_throws StrictViolation test_compiled(ProofAuditDemo; guarantees = (:noboxing,))

    fs = proof_findings(ProofAuditDemo; guarantees = (:noboxing,))
    @test fs isa Vector{StrictMode.StrictFinding}
    @test any(f -> f.func == "cold" && StrictMode._failed(f), fs)
    @test any(f -> f.func == "hot" && f.status === :pass, fs)

    buf = IOBuffer()
    fa = proof_audit(ProofAuditDemo; sweep = true, guarantees = (:noboxing,), format = :json, io = buf)
    @test fa isa Vector{StrictMode.StrictFinding}
    @test StrictMode.nfailures(fa) >= 1
    @test occursin("\"status\":\"fail\"", String(take!(buf)))
end

@testitem "proof_audit really is the PROOF, not the scan" begin
    using StrictMode, StrictModeTest
    # `:noboxing` is the guarantee where the two engines are known to disagree — the scan calls an
    # abstract-eltype container boxing, AllocCheck does not — so a `proof_audit` that had quietly
    # fallen back to the scan would differ here.
    abstract type _PA end
    struct _PA1 <: _PA
        x::Int
    end
    absc(n::Int) = (v = _PA[_PA1(n)]; length(v))
    absc(1)
    @test StrictMode._failed(only(StrictMode.findings(absc, (Int,); guarantees = (:noboxing,))))
    @test only(proof_findings(absc, (Int,); guarantees = (:noboxing,))).status === :pass
end
