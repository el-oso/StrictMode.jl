# F16: @kernel bundles noalloc + vectorized + typestable

@testitem "@kernel pass: vectorized+noalloc+typestable SIMD kernel (F16)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore

    good!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in 1:8:length(x)
            vstore(vload(Vec{8, Float64}, x, i) * 2.0, y, i)
        end; y
    )
    x = rand(8); y = zeros(8)
    result = @kernel good!(y, x)
    @test result === y   # passes all three guarantees and returns the call's value
end

@testitem "@kernel fail: non-vectorized function throws StrictViolation (:vectorized) (F16)" begin
    using StrictMode

    # type-stable, alloc-free, but no vector ops → @kernel should fail at :vectorized
    scalar_add(a::Float64, b::Float64) = a + b

    err = try
        @kernel scalar_add(1.0, 2.0)
        nothing
    catch e
        e
    end
    @test err isa StrictViolation
    @test err.kind === :vectorized
end

@testitem "@kernel accepts keyword arguments (issue #4)" begin
    using StrictMode, AllocCheck, JET
    using SIMD: Vec, vload, vstore

    # `@inline` so the kwsorter body inlines into `Core.kwcall` (the kwarg inference/IR seam) —
    # otherwise @assert_vectorized sees only the thin kwcall dispatcher (its documented
    # non-inlined-callee limitation), same as any forwarding wrapper.
    @inline goodkw!(y::Vector{Float64}, x::Vector{Float64}; scale = 2.0) = (
        @inbounds for i in 1:8:length(x)
            vstore(vload(Vec{8, Float64}, x, i) * scale, y, i)
        end; y
    )
    x = rand(8); y = zeros(8)
    result = @kernel goodkw!(y, x; scale = 2.0)
    @test result === y
end
