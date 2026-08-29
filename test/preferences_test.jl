@testitem "checks are enabled in the test environment" begin
    using StrictMode, StrictModeTest
    @test StrictMode.checks_enabled() === true
end

@testitem "assert_enabled: errors under CI when disabled, skippable locally" begin
    using StrictMode
    # Pure-core truth table.
    @test StrictMode._assert_enabled(true, false) === true
    @test StrictMode._assert_enabled(true, true) === true
    @test StrictMode._assert_enabled(false, false) === false
    @test_throws ErrorException StrictMode._assert_enabled(false, true)
    # Public entry point in this env (checks baked on): true regardless of CI.
    @test assert_enabled() === true
end

@testitem "_gate selects the branch by compile-time flag" begin
    using StrictMode
    expected = StrictMode.checks_enabled() ? :checked : :bare
    @test StrictMode._gate(:checked, :bare) === expected
end

@testitem "enabled macros wrap the call (not the bare expression)" begin
    using StrictMode
    ex = @macroexpand @assert_noalloc identity(1)
    # With checks on, the expansion must be more than just `identity(1)`.
    @test !(ex isa Expr && ex.head === :call && ex.args[1] === :identity)
end

@testitem "assert_enabled is loud when StrictModeTest is declared but never loaded" begin
    using StrictMode
    # A package can be LISTED as a dependency and never `using`ed. Then every guarantee runs on the
    # value-free scan while the environment advertises the proofs, and none of the `test_*` gates
    # exist to be called. The pure core is tested directly so this needs no filesystem or
    # environment fixture.

    @test StrictMode._assert_enabled(true, false, false) === true      # checks on, nothing declared
    @test StrictMode._assert_enabled(true, true, false) === true       # …same under CI
    @test_throws ErrorException StrictMode._assert_enabled(true, false, true)
    @test_throws ErrorException StrictMode._assert_enabled(true, true, true)
    # Checks OFF short-circuits first: there is no point complaining about which engine would run
    # when no engine runs at all.
    @test StrictMode._assert_enabled(false, false, true) === false
    @test_throws ErrorException StrictMode._assert_enabled(false, true, true)   # the CI rule still wins

    # And the detector itself must be quiet in this environment, where StrictModeTest IS loaded.
    @test StrictMode.proofs_loaded()
    @test !StrictMode._backend_declared_but_unloaded()
    @test StrictMode.assert_enabled()
end
