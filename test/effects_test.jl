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

@testitem "effects layer reads Base.infer_effects" begin
    using StrictMode
    pure(x) = x * 2 + 1
    eff = StrictMode.effects(pure, (Int,))
    @test StrictMode.effect_holds(eff, :nothrow)
    @test StrictMode.effect_holds(eff, :effect_free)
    @test_throws ArgumentError StrictMode.effect_holds(eff, :bogus)
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
