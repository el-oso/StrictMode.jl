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
    @test StrictMode.scalar_fp_loops(first_gt, (Vector{Int64}, Int64))

    # render check: int ops show up in sprint(show, r)
    s = sprint(show, r)
    @test occursin("integer", s)
end
