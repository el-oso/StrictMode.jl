# The split's premise, checked in the only environment that can check it: StrictMode with NO
# analysis backend installed at all. Every other test in this repo runs with StrictModeTest loaded,
# so none of them can catch a guarantee that has quietly re-acquired a hard AllocCheck/JET/TrimCheck
# dependency — which is exactly the regression that would make `StrictMode` unusable as a plain
# `[deps]` entry in someone's `Project.toml`.
using StrictMode
using Test

@testset "StrictMode standalone (no proofs installed)" begin
    @test StrictMode.checks_enabled()
    @test !StrictMode.proofs_loaded()
    # The isolation itself is asserted FIRST, because the three `identify_package` checks below
    # pass on any machine whose global `@v#.#` environment happens not to have these packages —
    # which is every clean CI runner. Without this, dropping `JULIA_LOAD_PATH="@:@stdlib"` from the
    # CI step leaves the whole premise gate green while testing nothing, which is exactly how the
    # original isolation bug stayed invisible here for two commits.
    @test !any(p -> occursin(r"^@v#\.#$", p), LOAD_PATH)

    # …and only then: the proofs must not be RESOLVABLE. `--project=X` alone keeps the global
    # environment on the path, so `identify_package` would find anything installed there and this
    # suite would be testing the developer's machine rather than the repo.
    @test isnothing(Base.identify_package("AllocCheck"))
    @test isnothing(Base.identify_package("JET"))
    @test isnothing(Base.identify_package("StrictModeTest"))

    dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    A = (1.0, 2.0, 3.0)
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    het = (1, 2.0, 3.0f0)

    @testset "call-site guarantees run on the value-free scan" begin
        @test (@assert_noalloc dot3(A, A)) === 14.0
        @test (@assert_noboxing dot3(A, A)) === 14.0
        @test (@assert_typestable dot3(A, A)) === 14.0
        @test (@strict dot3(A, A)) === 14.0
    end

    @testset "and are not vacuous — they still catch bad code" begin
        # Reported, not thrown: this engine cannot see what LLVM elides, and a check that guesses
        # must not be able to abort a build. The proof that does gate is `StrictModeTest`'s
        # `@test_noalloc`, which is unavailable here by construction.
        @test_logs (:warn,) match_mode = :any (@assert_noalloc boxy(het))
        @test_logs (:warn,) match_mode = :any (@assert_noboxing boxy(het))
        # …and the guarantee whose scan layer IS exact still throws, with no backend in sight.
        unstable(x::Int) = x > 0 ? 1 : "negative"
        @test_throws StrictViolation (@assert_typestable unstable(1))
    end

    @testset "asking a StrictMode macro for a proof is refused, not silently downgraded" begin
        err = try
            @assert_noalloc static = true dot3(A, A)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("StrictModeTest", err.msg)
    end

    @testset "load-time enforcement (the reason src/ can depend on StrictMode alone)" begin
        # @strict_function runs at the annotated module's PRECOMPILE, where StrictModeTest is not
        # loadable by construction. It must therefore never require a backend...
        @strict_function sf_ok(x::Float64, y::Float64) = x * y + 1.0
        @test sf_ok(2.0, 3.0) === 7.0
        # ...and must WARN rather than throw on a scan verdict: a structural guess would otherwise
        # abort a consumer's module load for code that may be provably clean (issue #18 part 2,
        # ~28% false positives per issue #17). The declaration is still registered, so a test run
        # with StrictModeTest loaded re-checks it against AllocCheck.
        @test_logs (:warn,) match_mode = :any StrictMode._verify_strict_def(
            boxy, (typeof(het),), "boxy(::Tuple{Int,Float64,Float32})"
        )
    end

    @testset "the reporting API works and counts its findings" begin
        @test all(f -> f.status === :pass, findings(dot3, (typeof(A), typeof(A))))
        fs = findings(boxy, (typeof(het),); guarantees = (:noalloc,))
        @test only(fs).status === :fail
        @test nfailures(fs) == 1
        fsw = audit(
            StrictMode; sweep = true, guarantees = (:typestable,), format = :text, io = devnull
        )
        @test fsw isa Vector
    end

    @testset "the gating API is absent, not silently substituted" begin
        # Nothing here can gate a build, and the names that would are simply not defined — a
        # StrictMode that grew its own `test_*` fallback would be reporting a proof it never ran.
        for nm in (:test_signatures, :test_compiled, :test_registered, :proof_findings)
            @test !isdefined(StrictMode, nm)
        end
        for nm in (Symbol("@test_noalloc"), Symbol("@test_typestable"))
            @test !isdefined(StrictMode, nm)
        end
    end
end
