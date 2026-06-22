@testitem "@assert_vectorized flags a loop that cannot vectorize" begin
    using StrictMode
    # A plain float reduction can't reassociate → never vectorizes (robust across CPU targets).
    # Whether the `@simd` version *does* vectorize depends on the build's target features (a generic
    # CI runner has no AVX), so a portable test asserts only the negative + that the API returns a Bool.
    novec(a::Vector{Float64}) = (
        s = 0.0; for x in a
            s += x
        end; s
    )
    vec(a::Vector{Float64}) = (
        s = 0.0; @inbounds @simd for x in a
            s += x
        end; s
    )
    A = rand(64)

    @test StrictMode._vectorized(novec, (Vector{Float64},)) == false
    @test StrictMode._vectorized(vec, (Vector{Float64},)) isa Bool
    @test_throws StrictViolation @assert_vectorized novec(A)      # not vectorized → fails loudly
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

@testitem "scheduling asserts validate a real SIMD.jl Vec kernel (item 4)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore
    # Explicit SIMD.jl `Vec` ops emit `<N x double>` in the LLVM IR *regardless of CPU target*
    # (unlike `@simd` auto-vectorization, which is target-gated) — this mirrors PureFFT's
    # vload/vstore-over-preallocated-scratch hot kernels, the real pattern we validated against.
    function vscale!(dst::Vector{Float64}, src::Vector{Float64})
        @inbounds for i in 1:8:length(src)
            v = vload(Vec{8, Float64}, src, i)
            vstore(v * 2.0, dst, i)
        end
        return dst
    end
    D = zeros(64); S = rand(64); vscale!(D, S)

    @test StrictMode._vectorized(vscale!, (Vector{Float64}, Vector{Float64}))   # explicit Vec → vector IR
    @test (@assert_vectorized vscale!(D, S)) === D                             # passes on a real SIMD kernel
    @test (@assert_noalloc vscale!(D, S)) === D                                # and stays allocation-free
    # @assert_effects API works (we don't assert platform-specific effect *values*).
    eff = StrictMode.effects(vscale!, (Vector{Float64}, Vector{Float64}))
    @test StrictMode.effect_holds(eff, :terminates) isa Bool
end
