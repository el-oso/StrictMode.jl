# StrictModeTest owns the proofs — AllocCheck, JET, TrimCheck — and the `@test_*` / `test_*` API
# that gates on them. These tests cover exactly that: the primitives StrictMode itself cannot test,
# because StrictMode does not depend on those packages at all.
using StrictModeTest
using TrimCheck
using StrictMode
using Test

# Top level: `const` is not allowed inside a `@testset` (local scope). The sink is what makes the
# allocation below ESCAPE, so neither optimizer can elide it — see StrictMode's once_barrier fixtures.
const SINK = Ref{Any}(nothing)

@testset "StrictModeTest — the proof tier" begin

    @testset "loading requires checks to be enabled" begin
        # Anti-vacuity: with checks disabled every `@assert_*` is a bare call, nothing registers,
        # and `test_registered()` would sweep an empty registry and pass. `__init__` refuses to load
        # in that state, so reaching this line at all is the assertion — state it anyway.
        @test StrictMode.checks_enabled()
        @test StrictMode.proofs_loaded()
    end

    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    T3 = (NTuple{3, Float64}, NTuple{3, Float64})
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    Thet = (Tuple{Int, Float64, Float32},)

    allocs(n::Int) = (v = rand(n); SINK[] = v; length(v))

    @testset "the negative fixtures are still negative" begin
        # Every assertion in this file that says "the proof flags this" rests on these two fixtures
        # actually exhibiting the defect. An optimizer that elides `allocs`, or a `boxy` that stops
        # boxing, turns those assertions into tautologies while the suite stays green — the failure
        # mode that has recurred most often in this repo.
        allocs(4); boxy((1, 2.0, 3.0f0))                  # compile before measuring
        @test @allocated(allocs(4)) > 0
        @test StrictMode._alloc_signals(boxy, Thet).boxing
    end

    @testset "the AllocCheck primitive finds real allocations and clears clean code" begin
        @test isempty(StrictModeTest._raw_allocs(clean, T3))
        @test !isempty(StrictModeTest._raw_allocs(allocs, (Int,)))
    end

    @testset "_is_boxing separates boxing from a plain typed allocation" begin
        # Runtime-indexing a heterogeneous tuple boxes; allocating a Vector does not.
        boxing_insts = StrictModeTest._raw_allocs(boxy, Thet)
        @test !isempty(boxing_insts)
        @test any(StrictModeTest._is_boxing, boxing_insts)
        @test !any(StrictModeTest._is_boxing, StrictModeTest._raw_allocs(allocs, (Int,)))
    end

    @testset "the AllocCheck primitive honors ignore_throw" begin
        # A bounds-check throw branch is an allocation site AllocCheck can see; ignore_throw (the
        # default) must exclude it, since it is not on the hot path.
        sum_unchecked(a::Vector{Float64}, n::Int) = (
            s = 0.0; for i in 1:n
                s += a[i]
            end; s
        )
        A = rand(8)
        sum_unchecked(A, 8)
        old = StrictMode.ignore_throw()
        try
            StrictMode.set_ignore_throw!(true)
            @test isempty(StrictModeTest._raw_allocs(sum_unchecked, (Vector{Float64}, Int)))
            StrictMode.set_ignore_throw!(false)
            @test !isempty(StrictModeTest._raw_allocs(sum_unchecked, (Vector{Float64}, Int)))
        finally
            StrictMode.set_ignore_throw!(old)
            StrictMode.clear_cache!()
        end
    end

    @testset "the JET primitive reports internal dispatch" begin
        @test isempty(StrictModeTest._opt_reports("clean", clean, T3))
        dispatchy(x) = (v = Any[1, 2.0]; sum(a -> a + x, v))
        dispatchy(1)
        @test !isempty(StrictModeTest._opt_reports("dispatchy", dispatchy, (Int,)))
    end

    @testset "_trim_validate returns (passed, findings)" begin
        passed, findings = StrictModeTest._trim_validate(clean, Tuple{NTuple{3, Float64}, NTuple{3, Float64}})
        @test passed
        @test isempty(findings)
        # It also accepts a plain tuple of types, which is the other shape it is called with.
        p2, _ = StrictModeTest._trim_validate(clean, T3)
        @test p2 === passed
        # A non-inferrable signature is reported, not thrown.
        bad, why = StrictModeTest._trim_validate(identity, (Any,))
        @test bad isa Bool
        @test why isa Vector{String}
    end

    @testset "the @test_* macros gate where the @assert_* macros only report" begin
        # This is the split's whole premise: the same property, two macros, and only one of them
        # can break a build.
        @test_throws StrictViolation @test_noalloc allocs(4)
        @test (@test_noalloc clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
        @test_throws StrictViolation @test_noboxing boxy((1, 2.0, 3.0f0))
        @test (@test_typestable clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
        @test (@test_trim_compatible clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0

        # …while StrictMode's own macro warns on the very same call.
        @test_logs (:warn,) match_mode = :any (@assert_noalloc allocs(4))
    end

    @testset "the drivers collect every failure and raise once" begin
        err = try
            test_signatures([(clean, T3), (allocs, (Int,)), (boxy, Thet)]; guarantees = (:noalloc,))
            nothing
        catch e
            e
        end
        @test err isa StrictViolation
        # Both failing signatures must appear: a gate that stops at the first bad method leaves the
        # rest unevaluated, which is how a sweep reports less than it checked.
        @test occursin("allocs", err.details)
        @test occursin("boxy", err.details)
    end

    @testset "test_registered reports its count and re-proves the registry" begin
        old = copy(StrictMode.STRICT_REGISTRY)
        try
            empty!(StrictMode.STRICT_REGISTRY)
            StrictMode.register_strict!(clean, T3; guarantees = (:noalloc,))
            @test_logs (:info,) match_mode = :any test_registered()
            StrictMode.register_strict!(allocs, (Int,); guarantees = (:noalloc,))
            @test_throws StrictViolation test_registered()
        finally
            empty!(StrictMode.STRICT_REGISTRY)
            merge!(StrictMode.STRICT_REGISTRY, old)
        end
    end
end

include("divergence_test.jl")

@testset "the composite proving macros" begin
    clean2(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    T3b = (NTuple{3, Float64}, NTuple{3, Float64})
    SINK2 = Ref{Any}(nothing)
    allocs2(n::Int) = (v = rand(n); SINK2[] = v; length(v))
    allocs2(4)
    @test @allocated(allocs2(4)) > 0          # the fixture must still be bad

    @test (@test_strict clean2((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
    @test_throws StrictViolation @test_strict allocs2(4)
    # The exception names the COMPOSITE, not whichever bundled guarantee tripped first — otherwise
    # `@test_strict` failures would be indistinguishable from `@test_noalloc` ones in a log.
    err = try
        @test_strict allocs2(4)
        nothing
    catch e
        e
    end
    @test err.kind === :strict
end

module ProofAuditDemo
    hot(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    cold(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
end

@testset "proof_findings / proof_audit return proved verdicts as DATA" begin
    ProofAuditDemo.hot((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
    ProofAuditDemo.cold((1, 2.0, 3.0f0))

    # `test_compiled` throws on this module, so it cannot hand back findings for it — which is
    # exactly the case an agent wants them in. `proof_findings`/`proof_audit` are the data half.
    @test_throws StrictViolation test_compiled(ProofAuditDemo; guarantees = (:noboxing,))

    fs = proof_findings(ProofAuditDemo; guarantees = (:noboxing,))
    @test fs isa Vector{StrictMode.StrictFinding}
    @test any(f -> f.func == "cold" && StrictMode._failed(f), fs)
    @test any(f -> f.func == "hot" && f.status === :pass, fs)

    buf = IOBuffer()
    fa = proof_audit(ProofAuditDemo; sweep = true, guarantees = (:noboxing,), format = :json, io = buf)
    @test fa isa Vector{StrictMode.StrictFinding}
    @test StrictMode.nfailures(fa) >= 1
    @test occursin("\"status\":\"fail\"", String(take!(buf)))

    # …and it is genuinely the PROOF, not the scan: `:noboxing` is the guarantee where the two
    # engines are known to disagree — the scan calls an abstract-eltype container boxing, AllocCheck
    # does not — so a `proof_audit` that had quietly fallen back to the scan would differ here.
    abstract type _PA end
    struct _PA1 <: _PA
        x::Int
    end
    absc(n::Int) = (v = _PA[_PA1(n)]; length(v))
    absc(1)
    @test StrictMode._failed(only(StrictMode.findings(absc, (Int,); guarantees = (:noboxing,))))
    @test only(proof_findings(absc, (Int,); guarantees = (:noboxing,))).status === :pass
end

@testset "issue #20: juliac WARNINGS are not trim failures" begin
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
            C = TrimCheck.Compiler
            C.typeinf_ext_toplevel(
                Any[Core.svec(Int, Tuple{typeof(reflecty20), Int})], [Base.get_world_counter()], C.TRIM_SAFE
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

@testset "issue #19: the verifier checks the program juliac compiles" begin
    # juliac includes `juliac-trim-base.jl` / `juliac-trim-stdlib.jl` into the target before trim
    # inference. Without them the verifier rejects code juliac itself builds clean — a ≥4-argument
    # string interpolation on a reachable throw path despecializes to `Vararg{Any}` on 1.13.
    # OFF by default, and the reason is measured, not cautious: `juliac-trim-base.jl` stubs
    # `Base.CoreLogging.current_logger_for_env`, so applying it silences every @warn and @info for
    # the rest of the session — the whole of StrictMode's reporting tier, reporting nothing.
    @test !StrictModeTest.juliac_patches()
    @test !StrictModeTest._JULIAC_PATCHED[]
    patchsrc = read(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac-trim-base.jl"), String)
    @test occursin("current_logger_for_env", patchsrc)   # the reason the default is off

    # The patch files must actually exist for the default to mean anything: a silently missing
    # path would leave every verification running against stock Base while reporting normally.
    dir = joinpath(Sys.BINDIR, "..", "share", "julia", "juliac")
    for f in ("juliac-trim-base.jl", "juliac-trim-stdlib.jl")
        @test isfile(joinpath(dir, f))
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
@testset "issue #13: the union-split rule agrees with juliac's verifier" begin
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
            a === nothing || (s += a)
            b === nothing || (s -= b)
            c === nothing || (s *= 1.0 + c)
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

# F39 (StrictMode issue #27): the proof must not be weaker than the scan. JET cannot see a
# union-typed local that boxes a member on the way in — union splitting is not dynamic dispatch —
# so `@test_typestable` has to consult the scan's `unionphi` signal or it waves through exactly the
# class `@assert_typestable` catches.
@testset "issue #27: @test_typestable catches the union-phi box JET is blind to" begin
    @noinline function boxing_union_local(A::AbstractMatrix{Float64}, take::Bool)
        local x = take ? view(A, :, 1:1) : A
        s = 0.0
        for i in eachindex(x)
            s += @inbounds x[i]
        end
        return s
    end
    A = rand(4, 4)
    boxing_union_local(A, true)
    tt = (Matrix{Float64}, Bool)

    # The two layers the proof used to rely on both pass.
    @test only(Base.return_types(boxing_union_local, Tuple{tt...})) === Float64
    @test isempty(StrictModeTest._opt_reports("probe", boxing_union_local, tt))

    # The scan sees it, and now so does the proof.
    @test StrictMode._alloc_signals(boxing_union_local, tt; depth = 0).unionphi
    f = only(proof_findings(boxing_union_local, tt; guarantees = (:typestable,)))
    @test StrictMode._failed(f)
    @test occursin("union-typed local", f.reason)
end
