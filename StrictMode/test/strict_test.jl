@testitem "@strict passes on a stable, non-allocating call and returns its value" begin
    using StrictMode
    weighted(a, b) = 0.5a + 0.5b
    @test (@strict weighted(2.0, 4.0)) === 3.0
end

@testitem "@strict fails when the call is type-unstable" begin
    using StrictMode
    heterogeneous = (1, 2.0, "three")
    pick(tup, i) = tup[i]
    @test_throws StrictViolation @strict pick(heterogeneous, rand(1:3))
end

@testitem "@strict reports when the call allocates" begin
    using StrictMode
    makevec(n) = collect(1:n)
    @test_logs (:warn,) match_mode = :any (@strict makevec(8))
end

@testitem "@strict accepts keyword arguments (issue #4)" begin
    using StrictMode, StrictModeTest
    weightedkw(a, b; w = 0.5) = w * a + (1 - w) * b
    @test (@strict weightedkw(2.0, 4.0; w = 0.5)) === 3.0
end

@testitem "issue #29: a guarded call site costs no allocation" begin
    using StrictMode
    dot29(a::Vector{Float64}, b::Vector{Float64}) = (s = 0.0; @inbounds @simd for i in eachindex(a, b)
            s += a[i] * b[i]
        end; s)
    guarded29(a::Vector{Float64}, b::Vector{Float64}) = @strict dot29(a, b)
    bare29(a::Vector{Float64}, b::Vector{Float64}) = dot29(a, b)

    a = rand(64); b = rand(64)
    guarded29(a, b); bare29(a, b)          # compile both, and run the site's checks once

    # The point of the issue: the guard's own allocation landed in the CALLER's body, so a consumer
    # measuring the enclosing function measured the guard instead of the kernel. The checks now sit
    # on a cold branch that runs once per (site, specialization).
    @test iszero(@allocated bare29(a, b))
    @test iszero(@allocated guarded29(a, b))
    @test guarded29(a, b) ≈ bare29(a, b)   # and it still returns the call's value
end

@testitem "issue #29: hoisting the checks did not stop them happening" begin
    using StrictMode
    # The whole risk of moving a check off the hot path is that it quietly stops running. A
    # non-concrete return must still throw, and an allocating body must still be reported.
    unstable29(x::Int) = x > 0 ? x : "not a number"
    unstable29(1)
    @test_throws StrictViolation (@strict unstable29(1))

    SINK29 = Ref{Any}(nothing)
    leaky29(n::Int) = (v = Vector{Float64}(undef, n); SINK29[] = v; length(v))
    leaky29(4)
    @test_logs (:warn,) match_mode = :any (@strict leaky29(4))
end

@testitem "issue #29: a site re-arms after the world changes" begin
    using StrictMode
    # A flag that stayed set against code that has since changed is a silent skip — the failure this
    # package exists to remove. The stamp carries the world counter, so defining ANY method re-arms
    # every site with no help from `clear_cache!` or Revise.
    probe29(x::Float64) = x * 2
    probe29(1.0)
    site29(x::Float64) = @strict probe29(x)
    site29(1.0)

    before = StrictMode._guard_stamp()
    @eval unrelated29(x) = x + 1           # any new method moves the world counter
    @test StrictMode._guard_stamp() != before

    # clear_cache! is the explicit lever on top of that, and must also change the stamp.
    s = StrictMode._guard_stamp()
    StrictMode.clear_cache!()
    @test StrictMode._guard_stamp() != s
end
