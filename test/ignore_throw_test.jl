@testitem "noalloc ignores never-taken throw branches by default (F8)" begin
    using StrictMode
    @test StrictMode.ignore_throw() === true

    # Runtime zero-alloc, but has a bounds-check throw branch (no @inbounds) — AllocCheck with
    # ignore_throw=false would count the BoundsError construction as an allocation.
    f(a::Vector{Float64}, n::Int) = (
        s = 0.0; for i in 1:n
            s += a[i]
        end; s
    )
    A = rand(8)

    @test (@assert_noalloc f(A, 8)) isa Float64          # default: throw branch ignored → clean

    StrictMode.set_ignore_throw!(false)
    try
        @test_throws StrictViolation @assert_noalloc f(A, 8)   # now the throw branch is counted
    finally
        StrictMode.set_ignore_throw!(true)                # restore the default
    end
    @test StrictMode.ignore_throw() === true
end
