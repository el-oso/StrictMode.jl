@testitem "@assert_noalloc passes on an allocation-free call and returns its value" begin
    using StrictMode
    addone(x) = x + 1
    @test (@assert_noalloc addone(41)) === 42
end

@testitem "@assert_noalloc reports an allocating hot loop; @test_noalloc gates on it" begin
    using StrictMode, StrictModeTest
    # Intentionally bad: allocates a Vector and grows it in a loop.
    function grow_and_sum(n)
        v = Int[]
        for i in 1:n
            push!(v, i)
        end
        return sum(v)
    end
    # The scan's allocation verdicts are guesses, so the reporting macro warns…
    @test_logs (:warn,) match_mode = :any (@assert_noalloc grow_and_sum(10))
    # …and the AllocCheck-backed proof of the same property throws.
    @test_throws StrictViolation @test_noalloc grow_and_sum(10)
end

@testitem "@assert_noalloc empirical fallback (static=false) sees a real allocation" begin
    using StrictMode
    makevec(n) = collect(1:n)
    @test_logs (:warn,) match_mode = :any (@assert_noalloc static = false makevec(8))
end

@testitem "@assert_noalloc static=true points at the proof instead of guessing" begin
    using StrictMode
    # AllocCheck's static proof lives in StrictModeTest, so this macro cannot deliver it. Refusing
    # with a message that names `@test_noalloc` beats silently substituting the scan, which would
    # hand back a guess where a proof was asked for.
    addone(x) = x + 1
    err = try
        @assert_noalloc static = true addone(41)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("@test_noalloc", err.msg)
end

@testitem "the empirical path is value-dependent; the IR scan is signature-level (F38)" begin
    using StrictMode
    # A branch-dependent allocator: the branch actually taken for n=5 doesn't allocate, so a
    # value-dependent `@allocated` measurement passes for this input. But the function structurally
    # allocates in its n>100 branch, which `_alloc_signals` sees regardless of which branch a given
    # call happens to execute — matching what `findings` reports for the same signature.
    maybe_alloc(n::Int) = n > 100 ? sum(zeros(n)) : Float64(n)

    @test_logs (:warn,) match_mode = :any StrictMode._assert_noalloc(
        "maybe_alloc(5)", maybe_alloc, (Int,), () -> maybe_alloc(5); mode = :heuristic
    )

    # mode=:empirical (explicit static=false) doesn't see it for n=5.
    @test StrictMode._assert_noalloc(
        "maybe_alloc(5)", maybe_alloc, (Int,), () -> maybe_alloc(5); mode = :empirical
    ) == 5.0

    # The scan still catches a plain, unconditional allocator.
    grows(n::Int) = collect(1:n)
    @test_logs (:warn,) match_mode = :any StrictMode._assert_noalloc(
        "grows(5)", grows, (Int,), () -> grows(5); mode = :heuristic
    )

    # And still passes a genuinely clean call, silently.
    addone(x) = x + 1
    @test_logs StrictMode._assert_noalloc("addone(41)", addone, (Int,), () -> addone(41); mode = :heuristic)
end

@testitem "the noalloc macros accept keyword arguments (issue #4)" begin
    using StrictMode, StrictModeTest
    addkw(x; k = 1) = x + k
    @test (@assert_noalloc addkw(41; k = 1)) === 42
    @test (@test_noalloc addkw(41; k = 1)) === 42
    bad(n; k = 1) = collect(1:(n + k))
    @test_throws StrictViolation @test_noalloc bad(10; k = 2)
end

@testitem "the noalloc macros' types= override pins the inference signature (issue #5)" begin
    using StrictMode, StrictModeTest
    g(::Type{T}) where {T} = Vector{T}(undef, 1)
    # g allocates a Vector, so noalloc fails either way; the point is the override drives the signature.
    @test_throws StrictViolation @test_noalloc g(Float64) types = (Type{Float64},)
end
