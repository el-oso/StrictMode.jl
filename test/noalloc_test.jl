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

@testitem "@assert_noalloc empirical path escalates to AllocCheck, not @allocated alone (F33)" begin
    using StrictMode, AllocCheck, JET   # backend loaded ⇒ escalation active
    # `@allocated` is a `gc_num` delta that can be nonzero with NO real allocation (a SIMD / GC.@preserve
    # accounting artifact — see FEEDBACK F33, found via PureFFT's Butterfly256/512 kernels). So the
    # empirical (static=false) path must not fail on a nonzero `@allocated` alone: when the analysis
    # backend is loaded it escalates to AllocCheck (the authoritative oracle). A REAL allocation still
    # fails *through* that escalation; an alloc-free call passes. (The artifact→pass branch can't be
    # triggered deterministically — the artifact is flaky — so it's documented rather than asserted.)
    realloc(n) = collect(1:n)                  # genuinely allocates ⇒ AllocCheck confirms ⇒ still fails
    @test_throws StrictViolation @assert_noalloc static = false realloc(8)
    addone(x) = x + 1                          # alloc-free ⇒ passes
    @test (@assert_noalloc static = false addone(41)) === 42
end
