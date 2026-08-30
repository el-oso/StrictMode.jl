# F24/F28: branch_count and serial_dep_count signals in kernel_report.

@testitem "kernel_report branch and serial-dep signals (F24/F28)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore

    # F24: a vectorized kernel with a data-dependent branch
    @noinline function format_sign!(buf::Vector{UInt8}, xs::Vector{Int64})
        @inbounds for i in eachindex(xs)
            buf[i] = xs[i] < 0 ? UInt8('-') : UInt8('+')   # data-dependent branch
        end
        buf
    end
    r24 = kernel_report(format_sign!, (Vector{UInt8}, Vector{Int64}))
    @test r24.branch_count isa Int   # field exists

    # F28: a loop-carried integer phi fed through div
    @noinline function digit_count(x::Int64)
        n = Int64(0)
        while x > 0
            x = div(x, 10)   # serial dep: next x depends on current x through div
            n += 1
        end
        n
    end
    r28 = kernel_report(digit_count, (Int64,))
    @test r28.serial_dep_count isa Int   # field exists

    # show renders without error
    @test occursin("KernelReport", sprint(show, r24))
    @test occursin("KernelReport", sprint(show, r28))
end
