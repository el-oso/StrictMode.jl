@testsetup module NoSpillFixtures
export CleanAccumKernel, SpillyAccumKernel, clean_accum_kernel!, spilly_accum_kernel!

# A manually unrolled kernel with N independent SIMD accumulators — each `acc[k] += a[i]*b[i]+k`
# promotes to its own live vector register under `@simd`. With N below the target's vector
# register count the kernel is clean; well past it, LLVM's allocator has no choice but to spill
# to the stack. Generated (via `eval` at THIS module's top level, not inside a `@testitem` body —
# doing it there hits Julia 1.12's stricter world-age rules the moment the definition is used
# through a nested macro like `@test_throws`) rather than hand-unrolled, since the whole point is
# varying N.
function _accum_kernel_expr(name::Symbol, n::Int)
    accs = [Symbol(:acc, k) for k in 1:n]
    inits = [:($(accs[k]) = 0.0) for k in 1:n]
    updates = [:($(accs[k]) += a[i] * b[i] + $(Float64(k))) for k in 1:n]
    stores = [:(out[$k] = $(accs[k])) for k in 1:n]
    return quote
        function $name(out::Vector{Float64}, a::Vector{Float64}, b::Vector{Float64})
            $(inits...)
            @inbounds @simd for i in eachindex(a, b)
                $(updates...)
            end
            @inbounds begin
                $(stores...)
            end
            return nothing
        end
    end
end

eval(_accum_kernel_expr(:clean_accum_kernel!, 4))     # well under any x86-64 vector register file
eval(_accum_kernel_expr(:spilly_accum_kernel!, 32))   # past 16 ymm (AVX2); at/past 32 zmm (AVX-512)

const CleanAccumKernel = clean_accum_kernel!
const SpillyAccumKernel = spilly_accum_kernel!
end

@testitem "@assert_no_spill passes on a register-clean kernel" setup = [NoSpillFixtures] begin
    using StrictMode
    r = @assert_no_spill clean_accum_kernel!(zeros(4), zeros(3), zeros(3))
    @test r === nothing
end

@testitem "@assert_no_spill throws on a register-starved kernel" setup = [NoSpillFixtures] begin
    using StrictMode
    if Sys.ARCH === :x86_64
        @test_throws StrictViolation (@assert_no_spill spilly_accum_kernel!(zeros(32), zeros(3), zeros(3)))
    else
        @test_skip false   # spill/register-count shape is x86-64-specific (ymm/zmm)
    end
end

@testitem "spill_report and the :no_spill findings/check path agree" setup = [NoSpillFixtures] begin
    using StrictMode
    if Sys.ARCH === :x86_64
        types = (Vector{Float64}, Vector{Float64}, Vector{Float64})

        clean = StrictMode.spill_report(clean_accum_kernel!, types)
        @test clean.vec_spills == 0

        spilly = StrictMode.spill_report(spilly_accum_kernel!, types)
        @test spilly.vec_spills > 0

        fs_clean = findings(clean_accum_kernel!, types; guarantees = (:no_spill,))
        @test only(fs_clean).status === :pass

        fs_spilly = findings(spilly_accum_kernel!, types; guarantees = (:no_spill,))
        @test only(fs_spilly).status === :fail
        @test_throws StrictViolation check(spilly_accum_kernel!, types; guarantees = (:no_spill,))
    else
        @test_skip false
    end
end

@testitem "spill_report reports zero on unavailable code_native" begin
    using StrictMode
    # No native codegen for an abstractly-typed signature — matches `scalar_fp_loops`'s
    # can't-analyze-so-don't-fail convention rather than a spurious hard failure.
    r = StrictMode.spill_report(identity, (Any,))
    @test r.vec_spills == 0
end
