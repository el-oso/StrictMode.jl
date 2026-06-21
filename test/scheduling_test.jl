@testitem "@assert_vectorized distinguishes SIMD from scalar loops" begin
    using StrictMode
    # `@simd` lets the float reduction reassociate → vectorizes; the plain loop cannot.
    vec(a::Vector{Float64}) = (
        s = 0.0; @inbounds @simd for x in a
            s += x
        end; s
    )
    novec(a::Vector{Float64}) = (
        s = 0.0; for x in a
            s += x
        end; s
    )
    A = rand(64)

    @test StrictMode._vectorized(vec, (Vector{Float64},)) isa Bool
    @test (@assert_vectorized vec(A)) isa Float64                  # vectorized → passes
    @test_throws StrictViolation @assert_vectorized novec(A)      # not vectorized → fails
end

@testitem "@assert_effects checks inferred effects" begin
    using StrictMode
    add(a::Float64, b::Float64) = a + b
    @test (@assert_effects add(1.0, 2.0) (:nothrow,)) === 3.0      # float add is nothrow

    thrower(x::Int) = x > 0 ? x : error("neg")
    @test_throws StrictViolation @assert_effects thrower(2) (:nothrow,)   # can throw → not :nothrow
end

@testitem "descend asks for Cthulhu when it isn't loaded" begin
    using StrictMode
    f(x) = x + 1
    # Cthulhu is not in the test environment → descend logs an @info and returns (never throws).
    @test descend(f, (Int,)) === nothing
end

@testitem "llvmcall escape hatch round-trips and stays verifiable" begin
    using StrictMode
    # The escape hatch for scheduling-bound kernels: hand-written LLVM IR. StrictMode's role is to
    # keep it *verifiable* — you can still assert it's on the fast path.
    addllvm(x::Int64, y::Int64) = Base.llvmcall("%z = add i64 %0, %1\nret i64 %z", Int64, Tuple{Int64, Int64}, x, y)
    @test addllvm(2, 3) == 5
    @test (@assert_noalloc addllvm(2, 3)) == 5      # the hand-written kernel is allocation-free
end
