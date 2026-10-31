# F22: kernel_report and scalar_fp_loops extended to integer-SIMD kernels.

@testitem "kernel_report covers integer-SIMD kernels (F22)" begin
    using StrictMode
    using SIMD: Vec, vload

    # Integer SIMD: byte-compare kernel (memchr-style, <16 x i8>)
    @noinline function count_byte(v::Vector{UInt8}, b::UInt8)
        n = 0
        @inbounds for i in 1:16:(length(v) - 15)
            chunk = vload(Vec{16, UInt8}, v, i)
            n += Int(sum(chunk == Vec{16, UInt8}(b)))
        end
        n
    end

    r = kernel_report(count_byte, (Vector{UInt8}, UInt8))
    @test r.vectorized
    @test r.int_ops > 0          # integer vector ops must be counted
    @test r.fp_ops == 0          # purely integer kernel — no FP ops
    # with integer intensity, should not be forced into :scalar
    @test StrictMode._kr_bound(r) in (:compute, :balanced, :memory)  # any is valid, just not :scalar

    # scalar integer loop — early-exit search loop resists auto-vectorization
    # (loop-carried phi i64 index + shl/add for address arithmetic, no <N x> ops)
    @noinline function first_gt(x::Vector{Int64}, thresh::Int64)
        idx = Int64(0)
        for i in eachindex(x)
            if x[i] > thresh
                idx = Int64(i)
                break
            end
        end
        idx
    end
    # The scan is about vectorizable loop shape, so this only means anything where the surrounding
    # codegen can auto-vectorize at all. Ask the compiled output rather than a flag: forced bounds
    # checks and coverage instrumentation both suppress vectorization, and which of them is on by
    # default has already changed once between Julia versions. `count_byte` above cannot answer this
    # — explicit SIMD.jl vectors survive either setting — so probe with an ordinary `@simd` loop.
    @noinline function _autovec_probe(v::Vector{Float64})
        s = 0.0
        @inbounds @simd for i in eachindex(v)
            s += v[i]
        end
        return s
    end
    # F22's property is that the scan sees an INTEGER loop here, which an FP-only scan would miss:
    # a loop-carried index, and no floating-point work at all. Both hold in every configuration
    # measured — 1.12 and 1.13, bounds forced and auto, with and without coverage.
    rg = kernel_report(first_gt, (Vector{Int64}, Int64))
    @test rg.has_loop_phi
    @test iszero(rg.fp_ops)

    # `scalar_fp_loops` is deliberately NOT asserted on this kernel. Its epilogue-exclusion rule
    # depends on the surrounding codegen too: measured `true` in four of those configurations and
    # `false` on 1.12 under forced bounds checks, where the bounds branches leave a region that
    # looks like LLVM's own vectorized remainder. The detector is covered instead by the probe
    # below and by `scalar_loop_test.jl`, whose couplings hold everywhere.
    @test StrictMode.scalar_fp_loops(_autovec_probe, (Vector{Float64},)) ==
        !StrictMode._vectorized(_autovec_probe, (Vector{Float64},))

    # render check: int ops show up in sprint(show, r)
    s = sprint(show, r)
    @test occursin("integer", s)
end
