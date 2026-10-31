# The `llvm-mca` live path. Two entry points share these assertions so the pair cannot drift:
# `mca_test.jl`'s live item, which runs them only when the extension happens to be loaded, and
# `test/mca/runtests.jl`, an environment that installs `LLVM_full_jll` so they always run. Without
# the second, nothing exercises this path at all — `LLVM_full_jll` is ~680MiB and deliberately
# absent from every other environment here.
using StrictMode
using Test

function mca_dotk(a::Vector{Float64}, b::Vector{Float64})
    s = 0.0
    @inbounds @simd for i in eachindex(a, b)
        s += a[i] * b[i]
    end
    return s
end

function mca_live_checks()
    tt = (Vector{Float64}, Vector{Float64})
    r = mca_report(mca_dotk, tt)
    @test r.iterations > 0
    @test !isnan(r.ipc)
    @test r.block_rthroughput > 0

    # No bound given, so the macro is informational and cannot fail.
    val = @assert_mca mca_dotk(rand(8), rand(8))
    @test val isa Float64

    # …and a bound no hardware can meet does fail, so the gate is not inert.
    @test_throws StrictMode.StrictViolation (
        @assert_mca min_ipc = 1.0e6 mca_dotk(rand(8), rand(8))
    )

    # llvm-mca's CLI hard-fails on an unrecognized `-mcpu`, unlike Julia's own codegen path, so an
    # unknown name must fall back to `generic` rather than error.
    r2 = mca_report(mca_dotk, tt; mcpu = "definitely_not_a_real_cpu")
    @test r2.mcpu == "generic"
    @test r2.mcpu_fellback
    return nothing
end
