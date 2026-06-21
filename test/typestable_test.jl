@testitem "@assert_typestable passes on a type-stable call and returns its value" begin
    using StrictMode
    affine(x) = 2x + 1
    @test (@assert_typestable affine(3.0)) === 7.0
end

@testitem "@assert_typestable fails on runtime tuple indexing (boxing class)" begin
    using StrictMode
    # The canonical trap: indexing a heterogeneous tuple with a runtime value yields a Union
    # return type and silently boxes — measured a 135x slowdown in the FFT work.
    heterogeneous = (1, 2.0, "three")
    pick(tup, i) = tup[i]
    @test_throws StrictViolation @assert_typestable pick(heterogeneous, rand(1:3))
end
