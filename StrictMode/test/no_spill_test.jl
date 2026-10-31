@testmodule NoSpillFixtures begin
    using StrictMode
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
    # 80: past 16 ymm (AVX2) AND past 32 zmm (AVX-512) with real margin — 32 was found to land exactly
    # on the AVX-512 register count on some CI runners (zero margin, no spill observed).
    eval(_accum_kernel_expr(:spilly_accum_kernel!, 80))

    const CleanAccumKernel = clean_accum_kernel!
    const SpillyAccumKernel = spilly_accum_kernel!

    const KERNEL_TYPES = (Vector{Float64}, Vector{Float64}, Vector{Float64})

    # Whether the starved kernel spills is a property of the configuration, not of the checker: both
    # forced bounds checks and coverage instrumentation reshape the loop, and far enough that 80
    # accumulators no longer exhaust the register file. The two versions do NOT agree about it, so
    # no flag predicts the answer — measured spill lines for this kernel:
    #
    #   flags                                   1.12.7   1.13.3
    #   none                                       410      410
    #   --check-bounds=yes                           0      918
    #   --code-coverage=user                         0        0
    #   --check-bounds=yes --code-coverage=user      0      245
    #
    # So the guard asks for the spill directly rather than for a flag believed to imply one; a flag
    # proxy was already wrong once. CI runs the suite a second time with coverage off and bounds at
    # auto, which is the pass where these items are expected to run.
    spills_observable() =
        Sys.ARCH === :x86_64 && StrictMode.spill_report(spilly_accum_kernel!, KERNEL_TYPES).vec_spills > 0
end

@testitem "@assert_no_spill passes on a register-clean kernel" setup = [NoSpillFixtures] begin
    using StrictMode
    r = @assert_no_spill clean_accum_kernel!(zeros(4), zeros(3), zeros(3))
    @test isnothing(r)
end

@testitem "@assert_no_spill throws on a register-starved kernel" setup = [NoSpillFixtures] begin
    using StrictMode
    # Both branches assert. Where 80 accumulators really do exhaust the register file the guarantee
    # fails; where bounds-check or coverage instrumentation reshaped the loop until they do not, it
    # holds — and the guarantee must agree with the configuration it was given either way.
    if NoSpillFixtures.spills_observable()
        @test_throws StrictViolation (@assert_no_spill spilly_accum_kernel!(zeros(80), zeros(3), zeros(3)))
    else
        @test isnothing(@assert_no_spill spilly_accum_kernel!(zeros(80), zeros(3), zeros(3)))
    end
end

@testitem "spill_report and the :no_spill findings/check path agree" setup = [NoSpillFixtures] begin
    using StrictMode, StrictModeTest
    types = NoSpillFixtures.KERNEL_TYPES

    # True in every configuration: a kernel that fits the register file never spills, and the
    # findings path must agree with the report about it.
    @test iszero(StrictMode.spill_report(clean_accum_kernel!, types).vec_spills)
    @test only(findings(clean_accum_kernel!, types; guarantees = (:no_spill,))).status === :pass

    # The starved kernel, whose verdict follows the configuration. The report, the findings path and
    # the gate must agree with each other in both — three sources that could disagree, which is the
    # point of asserting them together rather than skipping where the kernel does not spill.
    if NoSpillFixtures.spills_observable()
        @test StrictMode.spill_report(spilly_accum_kernel!, types).vec_spills > 0
        @test only(findings(spilly_accum_kernel!, types; guarantees = (:no_spill,))).status === :fail
        @test_throws StrictViolation test_signatures([(spilly_accum_kernel!, types)]; guarantees = (:no_spill,))
    else
        @test iszero(StrictMode.spill_report(spilly_accum_kernel!, types).vec_spills)
        @test only(findings(spilly_accum_kernel!, types; guarantees = (:no_spill,))).status === :pass
        @test test_signatures([(spilly_accum_kernel!, types)]; guarantees = (:no_spill,)) isa
            Vector{StrictMode.StrictFinding}
    end
end
