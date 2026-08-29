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

    # Batch path: :no_scalar_loops is a first-class guarantee in findings/check (value-free,
    # so identical in :fast and :full).
    for m in (:fast, :full)
        fs = findings(scalar_sum, (Vector{Float64}, Int); guarantees = (:no_scalar_loops,), mode = m)
        @test only(fs).status === :fail
        gs = findings(vec_scale!, (Vector{Float64}, Vector{Float64}); guarantees = (:no_scalar_loops,), mode = m)
        @test only(gs).status === :pass
    end
    @test_throws StrictViolation check(scalar_sum, (Vector{Float64}, Int); guarantees = (:no_scalar_loops,), fail = :error)
end

@testitem "F20 scalar loop scan — hand-written tail vs. LLVM epilogue (issue #22)" tags = [:f20] begin
    using StrictMode
    using SIMD: Vec, vload, vstore

    # A hand-vectorized SIMD.jl main loop followed by a hand-written *scalar* cleanup loop for
    # the n % 8 remainder — the defect this check exists to catch: the scalar tail runs at
    # native speed for at most 7 elements, but nothing stops it from running unbounded scalar
    # work if the width assumption is wrong elsewhere.
    @noinline function body_plus_scalar_tail!(p::Ptr{Float64}, n::Int, a::Float64)
        V = Vec{8, Float64}
        i = 0
        while i + 8 <= n
            vstore(muladd(vload(V, p + i * 8), V(a), vload(V, p + i * 8)), p + i * 8)
            i += 8
        end
        while i < n
            unsafe_store!(p, muladd(a, unsafe_load(p, i + 1), unsafe_load(p, i + 1)), i + 1)
            i += 1
        end
        nothing
    end

    # Same kernel, but the remainder is a masked SIMD store instead of a scalar loop — the fix
    # for the case above. No scalar loop should be reported.
    @noinline function body_plus_masked_tail!(p::Ptr{Float64}, n::Int, a::Float64)
        V = Vec{8, Float64}
        i = 0
        while i + 8 <= n
            vstore(muladd(vload(V, p + i * 8), V(a), vload(V, p + i * 8)), p + i * 8)
            i += 8
        end
        if i < n
            m = Vec((1, 2, 3, 4, 5, 6, 7, 8)) <= (n - i)
            vstore(muladd(vload(V, p + i * 8, m), V(a), vload(V, p + i * 8, m)), p + i * 8, m)
        end
        nothing
    end

    # A plain `@simd` loop with no hand-vectorized code anywhere in the function. LLVM's own
    # vectorizer wraps it in a scalar remainder loop (bounded to under one vector width); that
    # remainder is not a defect and firing on it would make `true` carry no information, since
    # essentially every `@simd` loop gets one.
    @noinline function vector_kernel!(y::Vector{Float64}, a::Float64)
        @inbounds @simd for i in eachindex(y)
            y[i] = muladd(a, y[i], 1.0)
        end
        nothing
    end

    p = Base.unsafe_convert(Ptr{Float64}, Libc.malloc(64 * sizeof(Float64)))
    body_plus_scalar_tail!(p, 64, 2.0)
    body_plus_masked_tail!(p, 64, 2.0)
    Libc.free(p)
    vector_kernel!(zeros(64), 2.0)

    # False negative (issue #22): a hand-written scalar tail alongside a hand-vectorized main
    # loop must now be flagged, even though the function also contains vector ops.
    @test scalar_fp_loops(body_plus_scalar_tail!, (Ptr{Float64}, Int, Float64)) == true

    # The masked-tail fix must not be flagged.
    @test scalar_fp_loops(body_plus_masked_tail!, (Ptr{Float64}, Int, Float64)) == false

    # False positive (issue #22): LLVM's own `@simd` scalar epilogue must not be flagged.
    @test scalar_fp_loops(vector_kernel!, (Vector{Float64}, Float64)) == false
end
