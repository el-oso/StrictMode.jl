# Round 5 (BlazingPorts faer Cholesky port): F10 kernel_report, F11 callee-aware @assert_vectorized,
# F12 empty-sweep warning + the :vectorized guarantee.

@testitem "kernel_report reads arithmetic intensity (F10)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore
    # Explicit SIMD.jl Vec → vector IR regardless of CPU target (robust on any CI runner).
    # memory-bound: one multiply per load+store.
    mem!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in 1:8:length(x)
            vstore(vload(Vec{8, Float64}, x, i) * 2.0, y, i)
        end; y
    )
    # compute-bound: a Horner polynomial on the loaded vector — many FMAs per load+store.
    comp!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in 1:8:length(x)
            v = vload(Vec{8, Float64}, x, i)
            vstore((((v * 0.1 + 0.2) * v + 0.3) * v + 0.4) * v + 0.5, y, i)
        end; y
    )
    rm = kernel_report(mem!, (Vector{Float64}, Vector{Float64}))
    rc = kernel_report(comp!, (Vector{Float64}, Vector{Float64}))

    @test rm.vectorized && rc.vectorized                # both have <N x> ops
    @test rm.intensity < rc.intensity                   # compute-bound has higher FP:mem (robust ordering)
    @test StrictMode._kr_bound(rc) === :compute         # many FMAs per access → compute-bound
    @test occursin("intensity", sprint(show, rm))       # the report renders the diagnostic
end

@testitem "@assert_vectorized names non-inlined callees (F11)" begin
    using StrictMode
    @noinline leaf!(y, x) = (
        @inbounds @simd for i in eachindex(y)
            y[i] = x[i] * 2.0
        end; y
    )
    wrapper!(y, x) = leaf!(y, x)            # thin dispatcher: SIMD lives in the non-inlined leaf
    err = try
        @assert_vectorized wrapper!(zeros(8), rand(8))
        nothing
    catch e
        e
    end
    @test err isa StrictViolation
    @test occursin("leaf!", err.details)   # the message points at the leaf kernel
end

@testitem "check_compiled warns on an empty sweep; :vectorized is a guarantee (F12)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore
    module EmptyMod end
    @test_logs (:warn, r"no compiled method specializations") check_compiled(EmptyMod; mode = :fast)

    # :vectorized is now a valid engine guarantee (what F12's audit invocation passed).
    vk!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in 1:8:length(x)
            vstore(vload(Vec{8, Float64}, x, i) * 2.0, y, i)
        end; y
    )
    fs = check(vk!, (Vector{Float64}, Vector{Float64}); guarantees = (:vectorized,), fail = :none, mode = :fast)
    @test first(fs).status === :pass
end
