# Runs in ConsumerPkg's TEST environment, where StrictModeTest is available. The `@strict_function`
# declarations in `src/` were registered at ConsumerPkg's own precompile; this re-proves them.
using ConsumerPkg, StrictMode, StrictModeTest, Test

@testset "the consumer layout, end to end" begin
    @test StrictMode.checks_enabled()
    @test StrictMode.proofs_loaded()

    # The fixture must still allocate, or the gate below would pass for the wrong reason.
    ConsumerPkg.leaky(4)
    @test @allocated(ConsumerPkg.leaky(4)) > 0

    # `@strict_function` declares at the DEFINING package's precompile, and the declaration is
    # stored in ConsumerPkg itself — which is why it is still here after this process loaded
    # ConsumerPkg from its pkgimage. Stored in StrictMode instead, it would be gone: StrictMode is
    # loaded from its own cache by then, so the mutation does not survive.
    @test isempty(StrictMode.registered_strict())      # nothing registered in THIS session
    d = StrictMode.declarations()
    @test count(k -> StrictMode._mod_sym(k[1]) === :ConsumerPkg, keys(d)) == 2

    # The proof tier re-checks those declarations and DOES fail, where the precompile-time scan
    # only warned.
    @test_throws StrictViolation test_registered(; modules = [ConsumerPkg])

    # And the coverage gate counts them as declared: a package that annotates its `src/` must not
    # be told its own methods are undeclared.
    ConsumerPkg.clean(1.0)
    cov = audit(ConsumerPkg; require = :all)
    undeclared = Set(
        f.func * f.signature for f in cov
            if f.guarantee === :coverage && StrictMode._failed(f)
    )
    @test !("clean(Float64)" in undeclared)
    @test !("leaky(Int64)" in undeclared)

    # The path that does not depend on the registry surviving: name the signatures directly.
    @test_throws StrictViolation test_signatures(
        [(ConsumerPkg.leaky, (Int,))]; guarantees = (:noalloc,)
    )
    @test test_signatures([(ConsumerPkg.clean, (Float64,))]) isa Vector{StrictMode.StrictFinding}
end
