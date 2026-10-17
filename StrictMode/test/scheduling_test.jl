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

@testitem "F31 register_report returns a RegisterReport (shape; counts are machine-dependent)" begin
    using StrictMode
    # Any concrete function works — register counts depend on the target CPU, so we only assert
    # on shape (isa, field invariants) rather than specific values.
    dot3(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    rr = register_report(dot3, (NTuple{3, Float64}, NTuple{3, Float64}))
    @test rr isa StrictMode.RegisterReport
    @test iszero(rr.vec_regs_total) || rr.vec_regs_total == 32   # either no zmm or AVX-512
    @test rr.vec_spills >= 0

    # A positive control, because a count cannot be negative and `used >= 0` therefore passes even
    # when nothing was read: a vectorized loop must report registers in USE. `dot3` is the wrong
    # subject for that — measured here, it uses no vector registers at all (total 0, used 0), while
    # this loop reports 5 of 32. On a target with no vector registers both are 0, and the two
    # branches keep the assertion honest either way.
    function _axpy!(y::Vector{Float64}, a::Float64, x::Vector{Float64})
        @inbounds @simd for i in eachindex(y, x)
            y[i] += a * x[i]
        end
        return y
    end
    _axpy!(zeros(8), 2.0, ones(8))
    vr = register_report(_axpy!, (Vector{Float64}, Float64, Vector{Float64}))
    if vr.vec_regs_total > 0
        @test vr.vec_regs_used > 0
    else
        @test iszero(vr.vec_regs_used)
    end
    @test rr.vec_regs_used <= rr.vec_regs_total || rr.vec_regs_total == 0
    # show must not error
    @test sprint(show, rr) isa String
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
