# The split's premise, checked in the only environment that can check it: StrictMode with NO
# analysis backend installed at all. Every other test in this repo runs with StrictModeTest loaded,
# so none of them can catch a guarantee that has quietly re-acquired a hard AllocCheck/JET/TrimCheck
# dependency — which is exactly the regression that would make `StrictMode` unusable as a plain
# `[deps]` entry in someone's `Project.toml`.
using StrictMode
using Test

@testset "StrictMode standalone (no analysis backend)" begin
    @test StrictMode.checks_enabled()
    @test !StrictMode.backend_available()
    @test !StrictMode.trimcheck_available()
    # The backends must not even be RESOLVABLE here. This needs an isolated LOAD_PATH
    # (`JULIA_LOAD_PATH="@:@stdlib"`): `--project=X` alone keeps the global `@v#.#` environment on
    # the path, so `identify_package` finds anything installed there and this suite would then be
    # testing the developer's machine rather than the repo. CI sets it; so does the CLAUDE.md recipe.
    @test Base.identify_package("AllocCheck") === nothing
    @test Base.identify_package("JET") === nothing
    @test Base.identify_package("StrictModeTest") === nothing

    dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    A = (1.0, 2.0, 3.0)
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    het = (1, 2.0, 3.0f0)

    @testset "call-site guarantees run on the heuristic" begin
        @test (@assert_noalloc dot3(A, A)) === 14.0
        @test (@assert_noboxing dot3(A, A)) === 14.0
        @test (@assert_typestable dot3(A, A)) === 14.0
        @test (@strict dot3(A, A)) === 14.0
    end

    @testset "and are not vacuous — they still catch bad code" begin
        @test_throws StrictViolation @assert_noalloc boxy(het)
        @test_throws StrictViolation @assert_noboxing boxy(het)
    end

    @testset "load-time enforcement (the reason src/ can depend on StrictMode alone)" begin
        # @strict_function runs at the annotated module's PRECOMPILE, where StrictModeTest is not
        # loadable by construction. It must therefore never require a backend...
        @strict_function sf_ok(x::Float64, y::Float64) = x * y + 1.0
        @test sf_ok(2.0, 3.0) === 7.0
        # ...and must WARN rather than throw on a heuristic verdict: under `fail_mode = :error` a
        # structural guess would otherwise abort a consumer's module load for code that may be
        # provably clean (issue #18 part 2, ~28% false positives per issue #17). The declaration is
        # still registered, so a test run with StrictModeTest loaded re-checks it against AllocCheck.
        @test_logs (:warn,) match_mode = :any StrictMode._verify_strict_def(
            boxy, (typeof(het),), "boxy(::Tuple{Int,Float64,Float32})"
        )
    end

    @testset "batch API defaults to :fast and works" begin
        @test all(f -> f.status === :pass, findings(dot3, (typeof(A), typeof(A))))
        # A `:fast` allocation verdict is `:suspect` — a structural guess — but it still counts:
        # `nfailures` includes it, so a sweep does not go green on a real regression.
        fs = findings(boxy, (typeof(het),); guarantees = (:noalloc,))
        @test only(fs).status === :suspect
        @test nfailures(fs) == 1
        fsw = audit(
            StrictMode; sweep = true, guarantees = (:typestable,), format = :text,
            io = devnull, exit_on_fail = false
        )
        @test fsw isa Vector
    end

    @testset "asking for :full without the backend fails loudly, not silently" begin
        # It must NOT quietly downgrade to the heuristic and report a pass.
        @test_throws StrictMode.BackendUnavailable findings(dot3, (typeof(A), typeof(A)); mode = :full)
        # …and that must hold for the BATCH drivers too. They swallow per-item analysis errors so one
        # unanalyzable method cannot sink a sweep, which used to eat the missing-backend error and
        # return a vacuous green: the same sweep reporting 53 findings at :fast returned 0 findings,
        # 0 failures, exit 0 at :full. `audit` is the driver the Stop hook and consumer gate scripts
        # run, so that silence landed exactly where it does the most damage.
        @test_throws StrictMode.BackendUnavailable audit(
            StrictMode; sweep = true, mode = :full,
            guarantees = (:typestable,), format = :text, io = devnull, exit_on_fail = false
        )
        @test_throws StrictMode.BackendUnavailable check_signatures(
            [(dot3, (typeof(A), typeof(A)))]; mode = :full, fail = :error
        )
    end
end
