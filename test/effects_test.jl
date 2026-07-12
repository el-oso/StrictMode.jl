@testitem "_alloc_signals heuristic matches allocation reality" begin
    using StrictMode
    clean(a, b) = a * b + 1.0
    buf(n) = (
        v = Vector{Float64}(undef, n); @inbounds for i in 1:n
            v[i] = i
        end; sum(v)
    )
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )

    cs = StrictMode._alloc_signals(clean, (Float64, Float64))
    @test !cs.alloc && !cs.boxing                       # clean kernel: no signal

    bs = StrictMode._alloc_signals(buf, (Int,))
    @test bs.alloc && !bs.boxing                        # explicit buffer alloc, no boxing

    xs = StrictMode._alloc_signals(boxy, (Tuple{Int, Float64, Float32},))
    @test xs.boxing                                     # runtime tuple index → boxing
end

@testitem "effects layer wraps Base.infer_effects" begin
    using StrictMode
    pure(x) = x * 2 + 1
    eff = StrictMode.effects(pure, (Int,))
    # The API returns a Bool per effect, and rejects unknown effects. (We don't assert specific
    # effect *values* — those are the compiler's call and vary across platforms.)
    @test StrictMode.effect_holds(eff, :nothrow) isa Bool
    @test StrictMode.effect_holds(eff, :effect_free) isa Bool
    @test_throws ArgumentError StrictMode.effect_holds(eff, :bogus)
    # A function that can `throw` is never `:nothrow` — robust everywhere.
    thrower(x) = x > 0 ? x : error("negative")
    @test StrictMode.effect_holds(StrictMode.effects(thrower, (Int,)), :nothrow) == false
end

@testitem "_findings_fast gives correct verdicts with no backend needed" begin
    using StrictMode
    clean(a, b) = a * b + 1.0
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )

    cf = StrictMode._findings_fast(clean, (Float64, Float64), (:typestable, :noalloc, :noboxing), :M, "clean", "()")
    @test all(f -> f.status === :pass, cf)

    bf = StrictMode._findings_fast(boxy, (Tuple{Int, Float64, Float32},), (:noalloc, :noboxing), :M, "boxy", "()")
    @test all(f -> f.status === :fail, bf)              # boxes → both noalloc and noboxing fail
end

@testitem "_alloc_signals catches an escaping non-isbits immutable :new (F38)" begin
    using StrictMode
    # `Some{Any}(x)` heap-allocates (it's not isbits) but is neither mutable nor an
    # Array/Memory/Box — the old :new rule (mutable || Array || Memory || Box) missed it
    # entirely. Verified against a real corpus (PureFFT.jl): the old rule false-negatived on
    # `apply_rfft!`/`pfft!`, which both build escaping non-isbits immutables.
    mkany(x::Int) = Some{Any}(x)
    sig = StrictMode._alloc_signals(mkany, (Int,))
    @test sig.alloc
end

@testitem "_alloc_signals doesn't flag union-split :invoke as boxing (F9)" begin
    using StrictMode
    @noinline g(x::Int) = x > 0 ? 1.0 : 1        # resolved call returning a small Union
    f(x::Int) = (y = g(x); y + 1.0)              # type-stable union-split use → no heap box
    f(2)                                          # warm
    sig = StrictMode._alloc_signals(f, (Int,))
    @test !sig.boxing && !sig.alloc              # not a false positive (was flagged before the fix)
    @test @allocated(f(2)) == 0                  # genuinely zero-alloc
end
