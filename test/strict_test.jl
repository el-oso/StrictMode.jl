@testitem "@strict passes on a stable, non-allocating call and returns its value" begin
    using StrictMode
    weighted(a, b) = 0.5a + 0.5b
    @test (@strict weighted(2.0, 4.0)) === 3.0
end

@testitem "@strict fails when the call is type-unstable" begin
    using StrictMode
    heterogeneous = (1, 2.0, "three")
    pick(tup, i) = tup[i]
    @test_throws StrictViolation @strict pick(heterogeneous, rand(1:3))
end

@testitem "@strict fails when the call allocates" begin
    using StrictMode
    makevec(n) = collect(1:n)
    @test_throws StrictViolation @strict makevec(8)
end

@testitem "@strict accepts keyword arguments (issue #4)" begin
    using StrictMode, AllocCheck, JET
    weightedkw(a, b; w = 0.5) = w * a + (1 - w) * b
    @test (@strict weightedkw(2.0, 4.0; w = 0.5)) === 3.0
end
