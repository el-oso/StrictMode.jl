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

@testitem "issue #29: a guard flag cannot be inherited from another process" begin
    using StrictMode
    # `_site_flag`'s `Ref` is inlined into the caller as a literal, so a flag set during a
    # consumer's precompile is serialized into the pkgimage with its stamp in it. World counters are
    # reproducible enough across processes that a fresh session can reach that exact value, at which
    # point the site reads as already-checked and its scan is skipped silently — the vacuous-green
    # shape the stamp exists to prevent. The per-process nonce makes a baked stamp unreachable.
    @test StrictMode._GENERATION[] != 0

    # And it is a real nonce, not a constant: a second process must not produce the same one.
    other = parse(UInt, readchomp(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e
        "using StrictMode; print(StrictMode._GENERATION[])"`))
    @test other != StrictMode._GENERATION[]
end

@testitem "issue #29: @strict still reports the union-phi box (F39)" begin
    using StrictMode
    # A union-typed local whose members do not all ride unboxed sets none of `alloc`, `boxing` or
    # `abscontainer`, so a scan testing only those three drops the signal entirely. `@assert_typestable`
    # reports it; `@strict` must not be quieter than the macro it bundles.
    @noinline function unionphi29(A::Matrix{Float64}, take::Bool)
        local x = take ? view(A, :, 1:1) : A
        s = 0.0
        for i in eachindex(x)
            s += @inbounds x[i]
        end
        return s
    end
    A = rand(4, 4)
    unionphi29(A, true)
    @test StrictMode._alloc_signals(unionphi29, (Matrix{Float64}, Bool)).unionphi
    @test_logs (:warn,) match_mode = :any (@strict unionphi29(A, true))
end

@testitem "issue #29: no assertion macro allocates" begin
    using StrictMode
    dotf(a::Vector{Float64}, b::Vector{Float64}) = (s = 0.0; @inbounds @simd for i in eachindex(a, b)
            s += a[i] * b[i]
        end; s)
    bare(a::Vector{Float64}, b::Vector{Float64}) = dotf(a, b)
    m_strict(a::Vector{Float64}, b::Vector{Float64}) = @strict dotf(a, b)
    m_noalloc(a::Vector{Float64}, b::Vector{Float64}) = @assert_noalloc dotf(a, b)
    m_stable(a::Vector{Float64}, b::Vector{Float64}) = @assert_typestable dotf(a, b)
    m_nobox(a::Vector{Float64}, b::Vector{Float64}) = @assert_noboxing dotf(a, b)
    m_owned(a::Vector{Float64}, b::Vector{Float64}) = @assert_owned dotf(a, b)
    m_inlined(a::Vector{Float64}, b::Vector{Float64}) = @assert_inlined dotf(a, b)

    a = rand(64); b = rand(64)
    macros = (bare, m_strict, m_noalloc, m_stable, m_nobox, m_owned, m_inlined)
    for f in macros
        f(a, b)                    # compile, and run this site's checks once
    end
    # A check that reads only the signature has the same answer at every call, so running it again
    # per call buys nothing and allocates into the CALLER's body — which is what made a guarded
    # kernel unmeasurable (issue #29). `@assert_inlined` was the worst at 140 KB per call.
    for f in macros
        @test iszero(@allocated f(a, b))
    end
    @test all(f -> f(a, b) ≈ bare(a, b), macros)
end

@testitem "issue #29: a value-dependent check still runs every call" begin
    using StrictMode
    # `static = false` measures the call it just made. That answer is about THIS run, not about the
    # shape of the code, so caching it would make it a lie — it must stay per call even though the
    # signature-reading checks no longer do.
    calls = Ref(0)
    counted(n::Int) = (calls[] += 1; n + 1)
    site(n::Int) = @assert_noalloc static = false counted(n)
    site(1)
    before = calls[]
    site(1); site(1); site(1)
    # Each execution runs the call for its value and again for the measurement: strictly more than
    # once per site, which is what proves it was not hoisted onto a one-shot branch.
    @test calls[] - before >= 3
end
