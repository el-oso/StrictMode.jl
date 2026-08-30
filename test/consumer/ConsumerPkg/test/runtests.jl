# Runs in ConsumerPkg's TEST environment, where StrictModeTest is available. The `@strict_function`
# declarations in `src/` were registered at ConsumerPkg's own precompile; this re-proves them.
using ConsumerPkg, StrictMode, StrictModeTest, Test

@testset "the consumer layout, end to end" begin
    @test StrictMode.checks_enabled()
    @test StrictMode.proofs_loaded()

    # The fixture must still allocate, or the gate below would pass for the wrong reason.
    ConsumerPkg.leaky(4)
    @test @allocated(ConsumerPkg.leaky(4)) > 0

    # `@strict_function` registers at the DEFINING package's precompile. Whether that registration
    # survives into this process is the open question tracked as "the registry leg of checked
    # twice" — so this asserts what is true either way rather than pinning the bug's current side.
    reg = StrictMode.registered_strict()
    n_consumer = count(k -> StrictMode._mod_sym(k[1]) === :ConsumerPkg, keys(reg))

    if n_consumer > 0
        # Registration survived: the proof tier re-checks the same declarations and DOES fail,
        # where the precompile-time scan only warned.
        @test_throws StrictViolation test_registered(; modules = [ConsumerPkg])
    else
        @test_logs (:warn, r"registry is EMPTY") match_mode = :any test_registered(; modules = [ConsumerPkg])
    end

    # The path that does not depend on the registry surviving: name the signatures directly.
    @test_throws StrictViolation test_signatures(
        [(ConsumerPkg.leaky, (Int,))]; guarantees = (:noalloc,)
    )
    @test test_signatures([(ConsumerPkg.clean, (Float64,))]) isa Vector{StrictMode.StrictFinding}
end
