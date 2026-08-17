# StrictModeTest is a thin package: it implements StrictMode's `_be_*` backend seam and flips the
# availability flags. These tests cover exactly that seam — the classification and plumbing that
# StrictMode itself cannot test, because in StrictMode's own suite the seam is a set of undefined
# stub functions. What the guarantees DO with these results is tested over in StrictMode.
using StrictModeTest
using StrictMode
using AllocCheck
using Test

# Top level: `const` is not allowed inside a `@testset` (local scope). The sink is what makes the
# allocation below ESCAPE, so neither optimizer can elide it — see StrictMode's once_barrier fixtures.
const SINK = Ref{Any}(nothing)

@testset "StrictModeTest — the :full backend seam" begin

    @testset "__init__ flips both availability flags" begin
        # Anti-vacuity: with checks disabled every `@assert_*` below is a bare call and passes
        # regardless. test/Project.toml sets this; assert it rather than trust it.
        @test StrictMode.checks_enabled()
        @test StrictMode.backend_available()
        @test StrictMode.trimcheck_available()
    end

    @testset "every seam stub has an implementation" begin
        # A stub with no methods would make the corresponding guarantee throw at :full, which is the
        # failure mode this package exists to prevent.
        for f in (
                StrictMode._be_check_allocs, StrictMode._be_is_boxing,
                StrictMode._be_opt_result, StrictMode._be_opt_reports,
                StrictMode._be_trim_validate,
            )
            @test !isempty(methods(f))
        end
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

    @testset "_be_check_allocs finds real allocations and clears clean code" begin
        @test isempty(StrictMode._be_check_allocs(clean, T3))
        @test !isempty(StrictMode._be_check_allocs(allocs, (Int,)))
    end

    @testset "_be_is_boxing separates boxing from a plain typed allocation" begin
        # Runtime-indexing a heterogeneous tuple boxes; allocating a Vector does not.
        boxing_insts = StrictMode._be_check_allocs(boxy, Thet)
        @test !isempty(boxing_insts)
        @test any(StrictMode._be_is_boxing, boxing_insts)
        @test !any(StrictMode._be_is_boxing, StrictMode._be_check_allocs(allocs, (Int,)))
    end

    @testset "_be_check_allocs honors ignore_throw" begin
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
            @test isempty(StrictMode._be_check_allocs(sum_unchecked, (Vector{Float64}, Int)))
            StrictMode.set_ignore_throw!(false)
            @test !isempty(StrictMode._be_check_allocs(sum_unchecked, (Vector{Float64}, Int)))
        finally
            StrictMode.set_ignore_throw!(old)
            StrictMode.clear_cache!()
        end
    end

    @testset "_be_opt_result / _be_opt_reports drive JET" begin
        @test isempty(StrictMode._be_opt_reports(StrictMode._be_opt_result(clean, T3)))
        dispatchy(x) = (v = Any[1, 2.0]; sum(a -> a + x, v))
        dispatchy(1)
        @test !isempty(StrictMode._be_opt_reports(StrictMode._be_opt_result(dispatchy, (Int,))))
    end

    @testset "_be_trim_validate returns (passed, findings)" begin
        passed, findings = StrictMode._be_trim_validate(clean, Tuple{NTuple{3, Float64}, NTuple{3, Float64}})
        @test passed
        @test isempty(findings)
        # It also accepts a plain tuple of types, which is the other shape StrictMode calls it with.
        p2, _ = StrictMode._be_trim_validate(clean, T3)
        @test p2 === passed
        # A non-inferrable signature is reported, not thrown.
        bad, why = StrictMode._be_trim_validate(identity, (Any,))
        @test bad isa Bool
        @test why isa Vector{String}
    end

    @testset "loading this package escalates StrictMode's guarantees end to end" begin
        # The point of the split: the heuristic passes `mkvec` (LLVM elides the allocation) and so
        # does the proof — but a REAL escaping allocation must fail through the proof path, and
        # `_noalloc_mode(nothing)` must still be `:heuristic` (the default that escalates), not a
        # baked `:static`.
        @test StrictMode._noalloc_mode(nothing) === :heuristic
        @test_throws StrictViolation @assert_noalloc allocs(4)
        @test (@assert_noalloc clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
    end
end
