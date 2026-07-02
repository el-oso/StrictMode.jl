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

@testitem "_typestable_fast (the :fast-mode check) passes/fails correctly" begin
    using StrictMode
    stable(x) = 2x + 1
    @test StrictMode._typestable_fast("t", stable, (Float64,)) === nothing   # concrete return

    heterogeneous = (1, 2.0, "three")
    pick(tup, i) = tup[i]
    @test_throws StrictViolation StrictMode._typestable_fast("t", pick, (typeof(heterogeneous), Int))
end

@testitem "@assert_typestable accepts keyword arguments (issue #4)" begin
    using StrictMode
    scaled(x; scale = 2) = x .* scale
    @test (@assert_typestable scaled([1.0, 2.0]; scale = 3)) == [3.0, 6.0]
end

@testitem "@assert_typestable fails on an unstable keyword-argument call (issue #4)" begin
    using StrictMode
    heterogeneous = (1, 2.0, "three")
    pickkw(tup; i = 1) = tup[i]
    @test_throws StrictViolation @assert_typestable pickkw(heterogeneous; i = rand(1:3))
end

@testitem "@assert_typestable types= override pins the inference signature (issue #5)" begin
    using StrictMode
    g(::Type{T}) where {T} = Vector{T}(undef, 1)
    # typeof(Float64) === DataType widens the inferred return to non-concrete → false positive.
    @test_throws StrictViolation @assert_typestable g(Float64)
    # Pinning Type{Float64} restores concreteness.
    @test (@assert_typestable g(Float64) types = (Type{Float64},)) isa Vector{Float64}
end

@testitem "analysis_mode defaults to :full in the test environment" begin
    using StrictMode
    @test analysis_mode() === :full
end
