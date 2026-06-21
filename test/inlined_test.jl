@testitem "@assert_inlined passes on an inlined call and returns its value" begin
    using StrictMode
    @inline hot(x) = x * x + 1
    @test (@assert_inlined hot(3.0)) === 10.0
end

@testitem "@assert_inlined fails when the call is not inlined" begin
    using StrictMode
    @noinline cold(x) = x * x + 1
    @test_throws StrictViolation @assert_inlined cold(3.0)
end

@testitem "@assert_inlined treats builtins as inlined" begin
    using StrictMode
    # `which(+, (Float64, Float64))` resolves, but the lowered + is absorbed — no surviving
    # :invoke — so this passes.
    @test (@assert_inlined 1.0 + 2.0) === 3.0
end
