@testitem "kernel_report noalias_missing_count field (F29)" begin
    using StrictMode

    # Any function with array (pointer) args
    @noinline dot_fn(a::Vector{Float64}, b::Vector{Float64}) = begin
        s = 0.0
        @inbounds for i in eachindex(a, b)
            s += a[i] * b[i]
        end
        s
    end

    r = kernel_report(dot_fn, (Vector{Float64}, Vector{Float64}))
    @test r.noalias_missing_count isa Int   # field exists
    @test sprint(show, r) isa String        # show renders without error
end
