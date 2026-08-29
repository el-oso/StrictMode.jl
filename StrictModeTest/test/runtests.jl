# StrictModeTest owns the proofs — AllocCheck, JET, TrimCheck — and the `@test_*` / `test_*` API
# that gates on them. These tests cover exactly that: the primitives StrictMode itself cannot test,
# because StrictMode does not depend on those packages at all.
using StrictModeTest
using StrictMode
using Test

# Top level: `const` is not allowed inside a `@testset` (local scope). The sink is what makes the
# allocation below ESCAPE, so neither optimizer can elide it — see StrictMode's once_barrier fixtures.
const SINK = Ref{Any}(nothing)

@testset "StrictModeTest — the proof tier" begin

    @testset "loading requires checks to be enabled" begin
        # Anti-vacuity: with checks disabled every `@assert_*` is a bare call, nothing registers,
        # and `test_registered()` would sweep an empty registry and pass. `__init__` refuses to load
        # in that state, so reaching this line at all is the assertion — state it anyway.
        @test StrictMode.checks_enabled()
        @test StrictMode.proofs_loaded()
    end

    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    T3 = (NTuple{3, Float64}, NTuple{3, Float64})
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    Thet = (Tuple{Int, Float64, Float32},)

    allocs(n::Int) = (v = rand(n); SINK[] = v; length(v))

    @testset "the negative fixtures are still negative" begin
        # Every assertion in this file that says "the proof flags this" rests on these two fixtures
        # actually exhibiting the defect. An optimizer that elides `allocs`, or a `boxy` that stops
        # boxing, turns those assertions into tautologies while the suite stays green — the failure
        # mode that has recurred most often in this repo.
        allocs(4); boxy((1, 2.0, 3.0f0))                  # compile before measuring
        @test @allocated(allocs(4)) > 0
        @test StrictMode._alloc_signals(boxy, Thet).boxing
    end

    @testset "the AllocCheck primitive finds real allocations and clears clean code" begin
        @test isempty(StrictModeTest._raw_allocs(clean, T3))
        @test !isempty(StrictModeTest._raw_allocs(allocs, (Int,)))
    end

    @testset "_is_boxing separates boxing from a plain typed allocation" begin
        # Runtime-indexing a heterogeneous tuple boxes; allocating a Vector does not.
        boxing_insts = StrictModeTest._raw_allocs(boxy, Thet)
        @test !isempty(boxing_insts)
        @test any(StrictModeTest._is_boxing, boxing_insts)
        @test !any(StrictModeTest._is_boxing, StrictModeTest._raw_allocs(allocs, (Int,)))
    end

    @testset "the AllocCheck primitive honors ignore_throw" begin
        # A bounds-check throw branch is an allocation site AllocCheck can see; ignore_throw (the
        # default) must exclude it, since it is not on the hot path.
        sum_unchecked(a::Vector{Float64}, n::Int) = (
            s = 0.0; for i in 1:n
                s += a[i]
            end; s
        )
        A = rand(8)
        sum_unchecked(A, 8)
        old = StrictMode.ignore_throw()
        try
            StrictMode.set_ignore_throw!(true)
            @test isempty(StrictModeTest._raw_allocs(sum_unchecked, (Vector{Float64}, Int)))
            StrictMode.set_ignore_throw!(false)
            @test !isempty(StrictModeTest._raw_allocs(sum_unchecked, (Vector{Float64}, Int)))
        finally
            StrictMode.set_ignore_throw!(old)
            StrictMode.clear_cache!()
        end
    end

    @testset "the JET primitive reports internal dispatch" begin
        @test isempty(StrictModeTest._opt_reports("clean", clean, T3))
        dispatchy(x) = (v = Any[1, 2.0]; sum(a -> a + x, v))
        dispatchy(1)
        @test !isempty(StrictModeTest._opt_reports("dispatchy", dispatchy, (Int,)))
    end

    @testset "_trim_validate returns (passed, findings)" begin
        passed, findings = StrictModeTest._trim_validate(clean, Tuple{NTuple{3, Float64}, NTuple{3, Float64}})
        @test passed
        @test isempty(findings)
        # It also accepts a plain tuple of types, which is the other shape it is called with.
        p2, _ = StrictModeTest._trim_validate(clean, T3)
        @test p2 === passed
        # A non-inferrable signature is reported, not thrown.
        bad, why = StrictModeTest._trim_validate(identity, (Any,))
        @test bad isa Bool
        @test why isa Vector{String}
    end

    @testset "the @test_* macros gate where the @assert_* macros only report" begin
        # This is the split's whole premise: the same property, two macros, and only one of them
        # can break a build.
        @test_throws StrictViolation @test_noalloc allocs(4)
        @test (@test_noalloc clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
        @test_throws StrictViolation @test_noboxing boxy((1, 2.0, 3.0f0))
        @test (@test_typestable clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
        @test (@test_trim_compatible clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0

        # …while StrictMode's own macro warns on the very same call.
        @test_logs (:warn,) match_mode = :any (@assert_noalloc allocs(4))
    end

    @testset "the drivers collect every failure and raise once" begin
        err = try
            test_signatures([(clean, T3), (allocs, (Int,)), (boxy, Thet)]; guarantees = (:noalloc,))
            nothing
        catch e
            e
        end
        @test err isa StrictViolation
        # Both failing signatures must appear: a gate that stops at the first bad method leaves the
        # rest unevaluated, which is how a sweep reports less than it checked.
        @test occursin("allocs", err.details)
        @test occursin("boxy", err.details)
    end

    @testset "test_registered reports its count and re-proves the registry" begin
        old = copy(StrictMode.STRICT_REGISTRY)
        try
            empty!(StrictMode.STRICT_REGISTRY)
            StrictMode.register_strict!(clean, T3; guarantees = (:noalloc,))
            @test_logs (:info,) match_mode = :any test_registered()
            StrictMode.register_strict!(allocs, (Int,); guarantees = (:noalloc,))
            @test_throws StrictViolation test_registered()
        finally
            empty!(StrictMode.STRICT_REGISTRY)
            merge!(StrictMode.STRICT_REGISTRY, old)
        end
    end
end

include("divergence_test.jl")

@testset "the composite proving macros" begin
    clean2(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    T3b = (NTuple{3, Float64}, NTuple{3, Float64})
    SINK2 = Ref{Any}(nothing)
    allocs2(n::Int) = (v = rand(n); SINK2[] = v; length(v))
    allocs2(4)
    @test @allocated(allocs2(4)) > 0          # the fixture must still be bad

    @test (@test_strict clean2((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
    @test_throws StrictViolation @test_strict allocs2(4)
    # The exception names the COMPOSITE, not whichever bundled guarantee tripped first — otherwise
    # `@test_strict` failures would be indistinguishable from `@test_noalloc` ones in a log.
    err = try
        @test_strict allocs2(4)
        nothing
    catch e
        e
    end
    @test err.kind === :strict
end

module ProofAuditDemo
    hot(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    cold(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
end

@testset "proof_findings / proof_audit return proved verdicts as DATA" begin
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

    # …and it is genuinely the PROOF, not the scan: `:noboxing` is the guarantee where the two
    # engines are known to disagree — the scan calls an abstract-eltype container boxing, AllocCheck
    # does not — so a `proof_audit` that had quietly fallen back to the scan would differ here.
    abstract type _PA end
    struct _PA1 <: _PA
        x::Int
    end
    absc(n::Int) = (v = _PA[_PA1(n)]; length(v))
    absc(1)
    @test StrictMode._failed(only(StrictMode.findings(absc, (Int,); guarantees = (:noboxing,))))
    @test only(proof_findings(absc, (Int,); guarantees = (:noboxing,))).status === :pass
end
