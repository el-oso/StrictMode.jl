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

@testitem "@assert_noalloc's :fast default is the value-free heuristic, not @allocated (F38)" begin
    using StrictMode
    # A branch-dependent allocator: the branch actually taken for n=5 doesn't allocate, so the
    # value-dependent @allocated(thunk) measurement — the OLD :fast default — passes for this
    # input. But the function's code structurally allocates in its n>100 branch, which
    # _alloc_signals (the NEW :fast default, mode=:heuristic) sees regardless of which branch a
    # given call happens to execute — matching what findings(...; mode=:fast) already reported.
    maybe_alloc(n::Int) = n > 100 ? sum(zeros(n)) : Float64(n)

    @test_throws StrictViolation StrictMode._assert_noalloc(
        "maybe_alloc(5)", maybe_alloc, (Int,), () -> maybe_alloc(5); mode = :heuristic
    )

    # mode=:empirical (explicit static=false) is unchanged: value-dependent, doesn't see it for n=5.
    @test StrictMode._assert_noalloc(
        "maybe_alloc(5)", maybe_alloc, (Int,), () -> maybe_alloc(5); mode = :empirical
    ) == 5.0

    # The heuristic path still catches a plain, unconditional allocator.
    grows(n::Int) = collect(1:n)
    @test_throws StrictViolation StrictMode._assert_noalloc(
        "grows(5)", grows, (Int,), () -> grows(5); mode = :heuristic
    )

    # And still passes a genuinely clean call.
    addone(x) = x + 1
    @test StrictMode._assert_noalloc("addone(41)", addone, (Int,), () -> addone(41); mode = :heuristic) === 42
end

@testitem "@assert_noalloc accepts keyword arguments (issue #4)" begin
    using StrictMode, AllocCheck, JET
    addkw(x; k = 1) = x + k
    @test (@assert_noalloc addkw(41; k = 1)) === 42
    bad(n; k = 1) = collect(1:(n + k))
    @test_throws StrictViolation @assert_noalloc bad(10; k = 2)
end

@testitem "@assert_noalloc types= override pins the inference signature (issue #5)" begin
    using StrictMode, AllocCheck, JET
    g(::Type{T}) where {T} = Vector{T}(undef, 1)
    # g allocates a Vector, so noalloc fails either way; the point is the override drives the signature.
    @test_throws StrictViolation @assert_noalloc g(Float64) types = (Type{Float64},)
end
