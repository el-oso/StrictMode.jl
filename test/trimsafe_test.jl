@testitem "@assert_trim_safe + :trimsafe guarantee (proactive, TypeContracts.trim_report)" begin
    using StrictMode
    safe_fn(x::Int) = x * 2 + 1
    unsafe_fn(x::Int) = length(Base.return_types(sin, (Float64,)))   # reflection → trim-unsafe

    @test (@assert_trim_safe safe_fn(3)) == 7                        # passes → returns the value
    @test_logs (:warn,) match_mode = :any (@assert_trim_safe unsafe_fn(3))   # reflection → reported

    # As an engine guarantee — value-free, no backend needed.
    @test all(f -> f.status === :pass, findings(safe_fn, (Int,); guarantees = (:trimsafe,)))
    @test any(f -> f.status === :fail, findings(unsafe_fn, (Int,); guarantees = (:trimsafe,)))
end

@testitem ":trimsafe flows through the compiled sweep" begin
    using StrictMode
    module TrimMix
    hotk(x::Int) = x + 1
    reflecty(x::Int) = length(Base.return_types(sin, (Float64,)))   # trim-unsafe
    end
    TrimMix.hotk(1); TrimMix.reflecty(1)                                # compile both

    fs = StrictMode._findings_compiled(TrimMix; guarantees = (:trimsafe,))
    @test any(f -> f.func == "reflecty" && f.status === :fail, fs)
    @test any(f -> f.func == "hotk" && f.status === :pass, fs)
end

@testitem "explain_trim translates juliac output (reactive)" begin
    using StrictMode
    tf = explain_trim("not a real verifier dump")    # unrecognized → still returns a TrimFailure
    @test tf isa Exception                           # TrimFailure <: Exception
    @test tf.recognized == false
end

@testitem "issue #13: a heuristic PASS stays :pass/empty-reason (back-compat) and notes the coverage gap" begin
    using StrictMode
    # status/reason on the structured StrictFinding are deliberately untouched by the issue #13
    # caveat — this pins the back-compat contract explicitly (a heuristic PASS is not distinguishable
    # from an authoritative one via `findings`; the caveat is macro-path-only visibility).
    safe_fn(x::Int) = x * 2 + 1
    fs = only(findings(safe_fn, (Int,); guarantees = (:trimsafe,)))
    @test fs.status === :pass
    @test fs.reason == ""

    # The macro's own PASS is unaffected functionally (returns the call's value as before).
    @test (@assert_trim_safe safe_fn(3)) == 7
    @test (@assert_trim_compatible safe_fn(3)) == 7

    # The one-time session note actually fires. `@test_logs` installs its own fresh logger for the
    # duration of the block, so it captures this `maxlog=1` (this repo's standing convention for a
    # hot-path advisory, same as _assert_noalloc's gc_num note) note independently of whatever else
    # ran earlier against the DEFAULT logger in this shared test worker — verified directly: a
    # maxlog=1 message already fired once against Base's default logger is still captured by a
    # subsequent `@test_logs` on the same call, since maxlog counting lives on the active logger
    # instance, not globally per call site.
    @test_logs (:info, r"not juliac's authoritative") match_mode = :any (@assert_trim_safe safe_fn(3))
end

# Fixtures for the union-split rule. `StrictModeTest`'s own suite defines the same four shapes and
# checks the rule's verdicts against juliac's real verifier; these pin the verdicts themselves, with
# no backend needed.
@testmodule UnionSplit begin
    # Large enough that inference will not inline it away — an inlined callee leaves no call to
    # resolve, which is why the issue's own trivial repro passes.
    @noinline function opaque(::Val{A}, ::Val{B}, ::Val{C}, ::Val{D}, x::Vector{Float64}) where {A, B, C, D}
        s = 0.0
        for i in eachindex(x)
            s = muladd(s, A ? 1.0000001 : 1.0000002, B ? x[i] : -x[i])
            C && (s += 1.0)
            D && (s -= 1.0)
        end
        return s
    end
    trivial(::Val, ::Val, ::Val, ::Val) = 0

    vv(b::Bool) = b ? Val(true) : Val(false)

    # Four runtime `Val`s into a callee small enough to inline: no call survives. The issue's repro.
    four_trivial(a::Bool, b::Bool, c::Bool, d::Bool) = trivial(vv(a), vv(b), vv(c), vv(d))
    # Two: 2^2 = 4, within `max_union_splitting`, so inference splits it. "The real gemm gets away
    # with 2" — from the PureBLAS commit that fixed the reported case.
    two(x::Vector{Float64}, a::Bool, b::Bool) = opaque(vv(a), vv(b), Val(true), Val(false), x)
    three(x::Vector{Float64}, a::Bool, b::Bool, c::Bool) = opaque(vv(a), vv(b), vv(c), Val(false), x)
    four(x::Vector{Float64}, a::Bool, b::Bool, c::Bool, d::Bool) = opaque(vv(a), vv(b), vv(c), vv(d), x)

    # Three isbits-union arguments at one call site: the common `Union{Nothing,Int}` idiom reaches
    # the same 8 > 4 arithmetic as three `Val`s, and juliac rejects it for the same reason.
    @noinline function consume(a::Union{Nothing, Int}, b::Union{Nothing, Int}, c::Union{Nothing, Int}, x::Vector{Float64})
        s = 0.0
        for i in eachindex(x)
            s = muladd(s, 1.0000001, x[i])
            a === nothing || (s += a)
            b === nothing || (s -= b)
            c === nothing || (s *= 1.0 + c)
        end
        return s
    end
    maybe(v::Int, on::Bool) = on ? v : nothing
    three_isbits(x::Vector{Float64}, p::Bool, q::Bool, r::Bool) = consume(maybe(1, p), maybe(2, q), maybe(3, r), x)
    two_isbits(x::Vector{Float64}, p::Bool, q::Bool) = consume(maybe(1, p), maybe(2, q), nothing, x)

    # (name, f, argument types, must the scan report it?)
    const CASES = (
        ("four_trivial", four_trivial, (Bool, Bool, Bool, Bool), false),
        ("two", two, (Vector{Float64}, Bool, Bool), false),
        ("three", three, (Vector{Float64}, Bool, Bool, Bool), true),
        ("four", four, (Vector{Float64}, Bool, Bool, Bool, Bool), true),
        ("two_isbits", two_isbits, (Vector{Float64}, Bool, Bool), false),
        ("three_isbits", three_isbits, (Vector{Float64}, Bool, Bool, Bool), true),
    )
end

@testitem "issue #13: a call that union-splits past the limit is reported" setup = [UnionSplit] begin
    using StrictMode
    for (name, f, tt, wantfail) in UnionSplit.CASES
        @testset "$name" begin
            r = StrictMode._trim_report(f, tt)
            @test r.passed == !wantfail
            wantfail && @test any(contains("max_union_splitting"), r.findings)
        end
    end

    # The report names the callee and the specialization count, not just "trim-unsafe".
    r = StrictMode._trim_report(UnionSplit.four, (Vector{Float64}, Bool, Bool, Bool, Bool))
    msg = only(filter(contains("max_union_splitting"), r.findings))
    @test contains(msg, "opaque")
    @test contains(msg, "16 specializations")

    # The limit is read from the compiler, not hardcoded: three union args is 8, still over 4.
    r3 = StrictMode._trim_report(UnionSplit.three, (Vector{Float64}, Bool, Bool, Bool))
    @test contains(only(filter(contains("max_union_splitting"), r3.findings)), "8 specializations")
end
