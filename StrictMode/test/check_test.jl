@testitem "findings returns per-guarantee results and never throws" begin
    using StrictMode
    dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )

    fs = findings(dot3, (NTuple{3, Float64}, NTuple{3, Float64}))
    @test all(f -> f.status === :pass, fs)

    # A violation is data, not an exception: `findings` is the data half of the API and the caller
    # decides what a finding is worth.
    bad = findings(boxy, (Tuple{Int, Float64, Float32},); guarantees = (:noboxing,))
    @test any(StrictMode._failed, bad)
end

@testitem "test_signatures gates on what findings only reports" begin
    using StrictMode, StrictModeTest
    dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    @test all(f -> f.status === :pass, test_signatures([(dot3, (NTuple{3, Float64}, NTuple{3, Float64}))]))
    @test_throws StrictViolation test_signatures(
        [(boxy, (Tuple{Int, Float64, Float32},))]; guarantees = (:noboxing,)
    )
end

@testitem "the proof separates a stable return from an allocating body; the scan does not" begin
    using StrictMode, StrictModeTest
    # `boxy` returns a concrete `Float64` but indexes a heterogeneous tuple at runtime. StrictMode's
    # own `:typestable` also flags that (its second layer is a this-level IR boxing signal), so only
    # the JET-backed proof answers "is the RETURN stable?" separately from "does it allocate?".
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    T = (Tuple{Int, Float64, Float32},)
    @test all(f -> f.status === :pass, proof_findings(boxy, T; guarantees = (:typestable,)))
    @test any(StrictMode._failed, proof_findings(boxy, T; guarantees = (:noalloc,)))
end

@testitem "macro hardening: broadcasting parses and runs" begin
    using StrictMode
    t = (1.0, 2.0, 3.0)
    @test (@assert_typestable sqrt.(t)) == map(sqrt, t)   # broadcast over a tuple → stable, no alloc
    @test (@assert_noalloc sqrt.(t)) == map(sqrt, t)
    # _callinfo rewrites f.(x) to broadcast(f, x)
    @test StrictMode._callinfo(:(f.(x))) == (:broadcast, Any[:f, :x], Any[])
end

@testitem "macro hardening: keyword args are extracted; unsupported forms still error" begin
    using StrictMode
    # (a) kwargs are accepted — _callinfo pulls them out of both `:parameters` and `:kw`.
    fexpr, argexprs, kwexprs = StrictMode._callinfo(:(solve(a, b; tol = 1)))
    @test fexpr === :solve
    @test argexprs == Any[:a, :b]
    @test kwexprs == Any[(:tol, 1)]

    # (b) a still-unsupported form (a bare block) still errors, pointing at the function API.
    err = try
        StrictMode._callinfo(
            :(
                begin
                    x + 1
                end
            )
        )
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("StrictMode.findings", sprint(showerror, err))
end

@testitem "an allocation verdict from the scan reports; the proof gates" begin
    using StrictMode, StrictModeTest
    # The value-free engine reads typed IR, where an allocation site LLVM will later elide is still
    # present, so its allocation verdicts are structural GUESSES rather than the proof AllocCheck
    # gives — measured ~28% false on a real consumer (issue #17: 19 of 68, every one 0 bytes).
    # A check that guesses must not be able to abort a build, so `@assert_noalloc` warns…
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    T = (Tuple{Int, Float64, Float32},)
    tup = (1, 2.0, 3.0f0)
    @test_logs (:warn,) match_mode = :any (@assert_noalloc boxy(tup))

    # …while the guarantee whose scan layer is exact still throws.
    unstable(x::Int) = x > 0 ? 1 : "negative"
    @test_throws StrictViolation (@assert_typestable unstable(1))

    # A finding is a finding either way: the status carries no confidence grading, because nothing
    # downstream of StrictMode acts on it automatically.
    fs = findings(boxy, T; guarantees = (:noalloc,))
    @test only(fs).status === :fail
    @test nfailures(fs) == 1

    # And the proof of the same property does gate.
    @test_throws StrictViolation (@test_noalloc boxy(tup))
end

@testitem "an analysis that cannot run reports :fail, never :pass" begin
    using StrictMode, StrictModeTest
    # "Could not check" and "is fine" must never render the same. AllocCheck refuses a non-dispatch
    # signature outright, which is the natural shape of a backend that cannot answer.
    f(x) = x + 1
    for g in (:noalloc, :noboxing)
        r = only(proof_findings(f, (Any,); guarantees = (g,)))
        @test r.status === :fail
        @test occursin("could not analyze", r.reason)
    end

    # …and the same rule holds per item inside a sweep: one method whose analysis throws becomes a
    # failing finding naming the error, and does not silently vanish or sink the other items.
    items = Any[(f, (Int,), (:noalloc,)), (f, (Float64,), (:noalloc,))]
    n = Ref(0)
    fs = StrictMode._map_findings(items) do fn, types, gs
        n[] += 1
        n[] == 1 ? error("backend crashed") : StrictMode.findings(fn, types; guarantees = gs)
    end
    @test length(fs) == 2
    @test count(StrictMode._failed, fs) == 1
    @test occursin("backend crashed", fs[1].reason)
end

@testitem "the function position is evaluated exactly once" begin
    using StrictMode, StrictModeTest
    # `_call_parts` used to splice `esc(fexpr)` into both the executed call and the analyzed
    # `checkfn`, so a function position with a side effect ran twice — and a factory (`make_f()(x)`)
    # was PROVED on a different closure than the one that ran, which is a proof about code the user
    # never executed.
    calls = Ref(0)
    plain(x) = 2x + 1
    makef() = (calls[] += 1; plain)

    calls[] = 0
    @test (@assert_typestable (makef())(3.0)) === 7.0
    @test calls[] == 1

    calls[] = 0
    @test (@test_noalloc (makef())(3.0)) === 7.0
    @test calls[] == 1
end

@testitem "types= keeps a keyword call on its real kwcall signature" begin
    using StrictMode, StrictModeTest
    # With `types = (…)` AND keyword arguments, the override used to take the plain-positional
    # branch: it analyzed `g(Int)` while the call actually dispatched through `Core.kwcall`. The
    # proof then covered a method the call never reaches.
    g(x::Int; k::Int = 1) = x + k
    p = StrictMode._call_parts(:(g(1; k = 2)); types = :((Int,)))
    @test p.checkfn === Core.kwcall

    # End to end: the override still pins the positional types, and the call is proved as-is.
    @test (@test_noalloc g(1; k = 2) types = (Int,)) === 3
end

@testitem "a signature that always throws is a note in a sweep and a failure where it is listed" begin
    using StrictMode

    module AlwaysThrows
    using StrictMode
    bad(x::Int) = x + "a"                               # no `+(::Int, ::String)`
    kwreq(x::Int; n::Int) = x + n                       # `n` is required
    wrongsig(v::AbstractVector, k) = v[k] = "s"         # a `String` into a `Vector{Float64}`
    need(::Nothing, f::Symbol) = throw(ArgumentError("no $f"))
    ok(x::Int) = x + 1
    end
    A = AlwaysThrows
    gs = (:typestable, :noalloc, :noboxing)

    # Nothing on a returning path exists to check, so no guarantee passes: each is the note.
    for (f, types) in ((A.bad, (Int,)), (A.kwreq, (Int,)), (A.wrongsig, (Vector{Float64}, Int)), (A.need, (Nothing, Symbol)))
        @test only(Base.return_types(f, types)) === Union{}
        fs = findings(f, types; guarantees = gs)
        @test all(x -> x.status === :info && x.code === :SM0208, fs)
        @test all(x -> occursin("always throws", x.reason), fs)
        @test !any(StrictMode._failed, fs)
    end
    @test all(x -> x.status === :pass, findings(A.ok, (Int,); guarantees = gs))
    @test occursin("throws", StrictMode.explain(:SM0208))

    # A sweep reports the note and does not fail on it: an error helper is not a defect (#36).
    try
        A.need(nothing, :a)
    catch
    end
    A.ok(1)
    swept = audit(A; sweep = true, guarantees = gs)
    @test any(x -> x.func == "need" && x.code === :SM0208, swept)
    @test nfailures(swept) == 0
    @test_nowarn @eval module AlwaysThrowsPolicy
    using StrictMode
    need(::Nothing, f::Symbol) = throw(ArgumentError("no $f"))
    plus(x::Int) = x + 1
    @strict_policy :default
    end
    # So does a declaration on the definition itself.
    @test_nowarn @eval module AlwaysThrowsDecl
    using StrictMode
    @strict_function need(::Nothing, f::Symbol) = throw(ArgumentError("no $f"))
    end

    # A listed signature is one its author expects to return, and none of these forms performs
    # the call, so the failure is the only thing that says it cannot.
    struct Impl end
    @test_throws "always throws" @eval @verify_strict Impl begin
        AlwaysThrows.kwreq(::Int)                       # the required keyword is left out
    end
    @test_throws "always throws" @eval @verify_strict Impl guarantees = (:noalloc,) begin
        AlwaysThrows.kwreq(::Int)
    end
    @test_throws "always throws" @eval @strict_function AlwaysThrows.bad signatures = [(Int,)]
    @test_throws "always throws" @eval @strict_function AlwaysThrows.bad signatures = [(Int,)] guarantees = (:noalloc,)
    @test_nowarn @eval @verify_strict Impl begin
        AlwaysThrows.kwreq(::Int; n::Int)
        AlwaysThrows.ok(::Int)
    end

    # A macro that performs its call raises the call's own error, so it gives no verdict to trust.
    @test_throws MethodError @assert_typestable A.bad(1)
end

@testitem "a signature that never returns is described as that, not only as throwing" begin
    using StrictMode

    # A worker loop infers `Union{}` as an error helper does: no path returns. It throws nothing.
    feed_forever(ch::Channel{Int}) =
        while true
            put!(ch, 1)
        end
    f = only(findings(feed_forever, (Channel{Int},); guarantees = (:typestable,)))
    @test f.code === :SM0208
    @test f.status === :info
    @test occursin("always throws or never returns", f.reason)
    @test occursin("a loop that is meant to run until its task ends", f.suggestion)
    # The advice for the other two readings is still there.
    @test occursin("matches no method", f.suggestion)
    @test occursin("never returns", StrictMode.explain(:SM0208))
end

@testitem "a signature no method matches is unevaluated in both tiers" begin
    using StrictMode, StrictModeTest
    h(x::Float64) = x + 1
    gs = (:owned, :no_threadid_state)
    # The compiler's effects for a signature with no match start from "every effect holds", and the
    # scan of no body finds nothing, so either would read as a pass.
    for fs in (findings(h, (Int,); guarantees = gs), proof_findings(h, (Int,); guarantees = gs))
        @test length(fs) == 2
        @test all(StrictMode._failed, fs)
        @test all(x -> x.code === :SM0203, fs)
        @test all(x -> occursin("no typed body", x.reason), fs)
    end
    @test_throws "no typed body" test_signatures([(h, (Int,))]; guarantees = gs)
end

@testitem "a signature that is not concrete is not read as one of its methods" begin
    using StrictMode, StrictModeTest
    k(x::Real, y::Real) = x + y
    k(x::Int, y::Int) = Dict(x => y)[x]
    # A call with concrete types reaches the specific method, and the scan sees what it does.
    @test StrictMode._failed(only(findings(k, (Int, Int); guarantees = (:owned,))))
    # The abstract signature matches both methods, and the scan reads one body.
    for fs in (
            findings(k, (Real, Real); guarantees = (:noalloc, :noboxing, :owned)),
            proof_findings(k, (Real, Real); guarantees = (:owned,)),
        )
        @test all(StrictMode._failed, fs)
        @test all(x -> x.code === :SM0203, fs)
        @test all(x -> occursin("not concrete", x.reason), fs)
    end
    # :typestable infers the return over every matching method, so it fails as itself.
    u(x::Int) = 1
    u(x::Float64) = "s"
    f = only(findings(u, (Union{Int, Float64},); guarantees = (:typestable,)))
    @test StrictMode._failed(f)
    @test f.code !== :SM0203
end
