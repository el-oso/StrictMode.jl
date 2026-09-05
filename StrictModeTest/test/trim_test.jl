# Trim verification: how juliac's verdict is classified, what Base it verifies against, and whether
# StrictMode's own static rule agrees with it.

@testitem "issue #20: juliac WARNINGS are not trim failures" begin
    using StrictMode, StrictModeTest, TrimCheck
    # `TrimVerificationErrors.errors` is a `Vector{Pair{Bool, Any}}` whose Bool is `warn`, and
    # juliac's own gate fails only on the non-warning entries. Counting warnings as failures reds
    # signatures juliac itself would build. A warnings-only raise cannot be provoked deterministically
    # from a real signature, so the classifier is driven directly.
    # Capture a REAL raise first and reuse its `parents`, so the fixtures differ from the genuine
    # article only in the field under test.
    reflecty20(x::Int) = length(Base.return_types(sin, (Float64,)))
    reflecty20(1)
    realerr = try
        TrimCheck.hook_verify_typeinf_trim() do
            # Through the same shim the source uses: `typeinf_ext_toplevel` takes a fourth argument
            # from Julia 1.13.0-rc4 onward, and a raw three-argument call here would MethodError on
            # the very release this fixture exists to characterise.
            StrictModeTest._typeinf_toplevel(
                TrimCheck.Compiler,
                Any[Core.svec(Int, Tuple{typeof(reflecty20), Int})],
                [Base.get_world_counter()],
            )
        end
        nothing
    catch e
        e
    end
    @test realerr isa TrimCheck.TrimVerificationErrors
    @test any(p -> !first(p), realerr.errors)          # it really is an ERROR set, not warnings
    mk(pairs) = TrimCheck.TrimVerificationErrors(pairs, realerr.parents)

    # Warnings only → PASS, with a note rather than silence.
    passed, findings = @test_logs (:info,) match_mode = :any StrictModeTest._trim_verdict(
        mk(Pair{Bool, Any}[true => "a warning", true => "another warning"])
    )
    @test passed
    @test isempty(findings)

    # A single real error among warnings → FAIL. The anti-vacuity half: without it, a classifier
    # that always returned `passed` would satisfy the assertion above.
    p2, f2 = StrictModeTest._trim_verdict(
        mk(Pair{Bool, Any}[true => "a warning", false => "a real error"])
    )
    @test !p2
    @test !isempty(f2)

    # No entries at all is not a failure either.
    @test first(StrictModeTest._trim_verdict(mk(Pair{Bool, Any}[])))

    # …and the real end-to-end path still fails on genuine reflection, so the filter did not
    # accidentally let everything through.
    ok, why = StrictModeTest._trim_validate(reflecty20, (Int,))
    @test !ok
    @test !isempty(why)
end

@testitem "issue #19: the verifier checks the program juliac compiles" begin
    using StrictModeTest
    # juliac includes `juliac-trim-base.jl` / `juliac-trim-stdlib.jl` into the target before trim
    # inference. Without them the verifier rejects code juliac itself builds clean — a ≥4-argument
    # string interpolation on a reachable throw path despecializes to `Vararg{Any}` on 1.13.
    # OFF by default, and the reason is measured, not cautious: `juliac-trim-base.jl` stubs
    # `Base.CoreLogging.current_logger_for_env`, so applying it silences every @warn and @info for
    # the rest of the session — the whole of StrictMode's reporting tier, reporting nothing.
    @test !StrictModeTest.juliac_patches()
    @test !StrictModeTest._JULIAC_PATCHED[]

    # juliac does not ship these at the same path on every Julia: they are under
    # `share/julia/juliac` on 1.12 and 1.13.0-rc3, and absent there on rc4. Where they exist, check
    # that the stub naming the reason for the default is still in them; where they do not, check the
    # behaviour that actually protects a user — `_apply_juliac_patches` warns rather than throwing,
    # so enabling the option on such a Julia degrades to stock-Base verification instead of breaking
    # the caller.
    dir = joinpath(Sys.BINDIR, "..", "share", "julia", "juliac")
    base_patch = joinpath(dir, "juliac-trim-base.jl")
    if isfile(base_patch)
        @test occursin("current_logger_for_env", read(base_patch, String))   # the reason the default is off
        @test isfile(joinpath(dir, "juliac-trim-stdlib.jl"))
    else
        old = StrictModeTest.juliac_patches()
        patched = StrictModeTest._JULIAC_PATCHED[]
        try
            StrictModeTest.set_juliac_patches!(true)
            StrictModeTest._JULIAC_PATCHED[] = false
            @test_logs (:warn,) match_mode = :any StrictModeTest._apply_juliac_patches()
        finally
            StrictModeTest.set_juliac_patches!(old)
            StrictModeTest._JULIAC_PATCHED[] = patched
        end
    end

    # The shape from the issue: an ordinary argument-validation throw with a 4-piece interpolation.
    # It PASSES on 1.12 with or without the patches, and this is what regresses on 1.13 without
    # them — so the assertion is the verdict, not the mechanism.
    function tzrzf_shape(m::Int, n::Int)
        m <= n || throw(ArgumentError("requires m ≤ n (got $m×$n)"))
        return m + n
    end
    tzrzf_shape(1, 2)
    ok, why = StrictModeTest._trim_validate(tzrzf_shape, (Int, Int))
    @test ok || !isempty(why)          # either verdict is legitimate; a silent empty FAIL is not

    old = StrictModeTest.juliac_patches()
    try
        StrictModeTest.set_juliac_patches!(false)
        @test !StrictModeTest.juliac_patches()
    finally
        StrictModeTest.set_juliac_patches!(old)
    end
end

# The union-split rule (StrictMode issue #13) is a heuristic that claims to agree with juliac's
# verifier on a class the dispatch rule cannot see. Only this package can check that claim, since
# only this package has TrimCheck.
@testitem "issue #13: the union-split rule agrees with juliac's verifier" begin
    using StrictMode, StrictModeTest
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

    # The `Union{Nothing,Int}` idiom reaches the same arithmetic as three `Val`s.
    @noinline function consume(a::Union{Nothing, Int}, b::Union{Nothing, Int}, c::Union{Nothing, Int}, x::Vector{Float64})
        s = 0.0
        for i in eachindex(x)
            s = muladd(s, 1.0000001, x[i])
            isnothing(a) || (s += a)
            isnothing(b) || (s -= b)
            isnothing(c) || (s *= 1.0 + c)
        end
        return s
    end
    maybe(v::Int, on::Bool) = on ? v : nothing
    three_isbits(x::Vector{Float64}, p::Bool, q::Bool, r::Bool) = consume(maybe(1, p), maybe(2, q), maybe(3, r), x)
    two_isbits(x::Vector{Float64}, p::Bool, q::Bool) = consume(maybe(1, p), maybe(2, q), nothing, x)

    four_trivial(a::Bool, b::Bool, c::Bool, d::Bool) = trivial(vv(a), vv(b), vv(c), vv(d))
    two(x::Vector{Float64}, a::Bool, b::Bool) = opaque(vv(a), vv(b), Val(true), Val(false), x)
    three(x::Vector{Float64}, a::Bool, b::Bool, c::Bool) = opaque(vv(a), vv(b), vv(c), Val(false), x)
    four(x::Vector{Float64}, a::Bool, b::Bool, c::Bool, d::Bool) = opaque(vv(a), vv(b), vv(c), vv(d), x)

    cases = (
        ("four_trivial", four_trivial, (Bool, Bool, Bool, Bool)),
        ("two", two, (Vector{Float64}, Bool, Bool)),
        ("three", three, (Vector{Float64}, Bool, Bool, Bool)),
        ("four", four, (Vector{Float64}, Bool, Bool, Bool, Bool)),
        ("two_isbits", two_isbits, (Vector{Float64}, Bool, Bool)),
        ("three_isbits", three_isbits, (Vector{Float64}, Bool, Bool, Bool)),
    )
    for (name, f, tt) in cases
        @testset "$name" begin
            verifier_passed, _ = StrictModeTest._trim_validate(f, tt)
            @test StrictMode._trim_report(f, tt).passed == verifier_passed
        end
    end
end
