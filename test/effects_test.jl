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
    @test all(StrictMode._failed, bf)              # boxes → both noalloc and noboxing fail
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

@testitem "the callee walk stops on a saturated signal set, leaving `barrier` one-sided" begin
    using StrictMode
    # `barrier` is exhaustive only while the walk is still running: the `:invoke` recursion stops
    # once alloc, boxing and dictlookup are all set, so a barrier reachable only below that point
    # is never recorded. Pinned because it is load-bearing for every reader of `barrier` — acting
    # on it grants an allocation exemption (StrictModeTest's `_checked_allocs` skips AllocCheck),
    # and each reader first demands `!alloc && !boxing`, a state this one can never reach. Widening
    # the condition to keep walking for `barrier`'s sake would pay the recursion cost on exactly
    # the signal-saturated functions the stop exists for, and buy no verdict.
    _measure_sat() = length(rand(4))
    const _SAT_ONCE = Base.OncePerProcess{Int}(_measure_sat)
    @noinline _below(x::Int) = x + _SAT_ONCE()

    # Control: with nothing else flagged the walk reaches `_below` and does see the barrier one
    # level down. Without this, the assertion at the end would pass for the wrong reason.
    clean(x::Int) = _below(x)
    cs = StrictMode._alloc_signals(clean, (Int,))
    @test cs.barrier
    @test !cs.alloc && !cs.boxing && !cs.dictlookup

    const _SINK = Ref{Any}(nothing)
    const _WS = Dict{Symbol, Int}(:a => 1)
    function saturated(t::Tuple{Int, Float64, Float32})
        a = rand(4)             # alloc — escaped into a sink so no optimizer elides it
        _SINK[] = a
        s = 0.0
        for i in 1:3            # boxing — runtime index into a heterogeneous tuple
            s += t[i]
        end
        delete!(_WS, :a)        # dictlookup
        return s + _below(length(a))
    end

    ss = StrictMode._alloc_signals(saturated, (Tuple{Int, Float64, Float32},))
    @test ss.alloc && ss.boxing && ss.dictlookup   # the frontier really is saturated ...
    @test !ss.barrier                              # ... so the walk stopped short of the barrier
end
