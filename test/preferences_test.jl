@testitem "checks are enabled in the test environment" begin
    using StrictMode
    @test StrictMode.checks_enabled() === true
    @test StrictMode.fail_mode() === :error
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
