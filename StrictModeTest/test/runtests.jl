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
