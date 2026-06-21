@testitem "@assert_noboxing passes on a clean call and returns its value" begin
    using StrictMode
    dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    @test (@assert_noboxing dot3((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))) === 32.0
end

@testitem "@assert_noboxing fails on runtime tuple indexing (boxing)" begin
    using StrictMode
    heterogeneous = (1, 2.0, 3.0f0)
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    @test_throws StrictViolation @assert_noboxing boxy(heterogeneous)
end

@testitem "@assert_noboxing fails on dynamic dispatch" begin
    using StrictMode
    struct AnyBox
        x::Any
    end
    usebox(b) = b.x + 1
    @test_throws StrictViolation @assert_noboxing usebox(AnyBox(2))
end

@testitem "@assert_noboxing ALLOWS a legitimate buffer allocation (unlike @assert_noalloc)" begin
    using StrictMode
    # Allocates a Vector but never boxes — the whole reason @assert_noboxing exists.
    function fill_sum(n)
        v = Vector{Float64}(undef, n)
        for i in 1:n
            @inbounds v[i] = i
        end
        return sum(v)
    end
    @test_throws StrictViolation @assert_noalloc fill_sum(3)   # it does allocate
    @test (@assert_noboxing fill_sum(3)) == 6.0               # …but it does not box
end
