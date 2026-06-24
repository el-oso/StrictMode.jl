# F20: scalar_fp_loops / @assert_no_scalar_loops

@testitem "F20 scalar loop scan — positive and negative" tags = [:f20] begin
    using StrictMode

    # Positive case: a scalar FP accumulator loop. The loop-carried `phi double` survives
    # even after unrolling, and no `<N x double>` vector ops are emitted (no @simd, no Vec).
    # @noinline keeps the function body from being absorbed into a caller's IR.
    @noinline function scalar_sum(x::Vector{Float64}, n::Int)
        s = 0.0
        i = 1
        while i <= n          # while + explicit index: harder for LLVM to auto-vectorize
            s += x[i]
            i += 1
        end
        return s
    end

    # Negative case: explicit Vec SIMD emits <N x double> regardless of CPU target.
    using SIMD: Vec, vload, vstore
    @noinline function vec_scale!(y::Vector{Float64}, x::Vector{Float64})
        @inbounds for i in 1:8:length(x)
            vstore(vload(Vec{8, Float64}, x, i) * 2.0, y, i)
        end
        return y
    end

    # Warm both so IR is compiled.
    A = rand(64)
    scalar_sum(A, 64)
    vec_scale!(zeros(64), A)

    # scalar_sum: loop-carried phi double + scalar fadd → true.
    @test scalar_fp_loops(scalar_sum, (Vector{Float64}, Int)) == true

    # vec_scale!: explicit Vec → vectorized → false.
    @test scalar_fp_loops(vec_scale!, (Vector{Float64}, Vector{Float64})) == false

    # @assert_no_scalar_loops throws on the scalar case.
    @test_throws StrictViolation @assert_no_scalar_loops scalar_sum(A, 64)

    # @assert_no_scalar_loops passes on the vectorized case.
    y = zeros(64)
    @test (@assert_no_scalar_loops vec_scale!(y, A)) === y
end
