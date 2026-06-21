@testitem "@assert_noalloc passes on an allocation-free call and returns its value" begin
    using StrictMode
    addone(x) = x + 1
    @test (@assert_noalloc addone(41)) === 42
end

@testitem "@assert_noalloc fails on an allocating hot loop" begin
    using StrictMode
    # Intentionally bad: allocates a Vector and grows it in a loop.
    function grow_and_sum(n)
        v = Int[]
        for i in 1:n
            push!(v, i)
        end
        return sum(v)
    end
    @test_throws StrictViolation @assert_noalloc grow_and_sum(10)
end

@testitem "@assert_noalloc empirical fallback (static=false) catches allocation" begin
    using StrictMode
    makevec(n) = collect(1:n)
    @test_throws StrictViolation @assert_noalloc static = false makevec(8)
end
