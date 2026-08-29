@testitem "check (function API) returns findings; throws on failure" begin
    using StrictMode
    dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )

    fs = check(dot3, (NTuple{3, Float64}, NTuple{3, Float64}); fail = :none)
    @test all(f -> f.status === :pass, fs)

    @test_throws StrictViolation check(boxy, (Tuple{Int, Float64, Float32},); guarantees = (:noboxing,))
end

@testitem "check honors guarantee selection" begin
    using StrictMode
    # Type-stable (concrete Float64 return) but allocates via boxing.
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    T = (Tuple{Int, Float64, Float32},)
    # Full tier: the :fast typestable signal also flags boxy's runtime tuple index (this-level
    # boxing), so only :full separates "stable return" from "allocates". Moves to StrictModeTest.
    @test all(f -> f.status === :pass, check(boxy, T; guarantees = (:typestable,), fail = :none, mode = :full))
    @test any(f -> f.status === :fail, check(boxy, T; guarantees = (:noalloc,), fail = :none, mode = :full))
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
    # (a) kwargs are now accepted — _callinfo pulls them out of both `:parameters` and `:kw`.
    fexpr, argexprs, kwexprs = StrictMode._callinfo(:(solve(a, b; tol = 1)))
    @test fexpr === :solve
    @test argexprs == Any[:a, :b]
    @test kwexprs == Any[(:tol, 1)]

    # (b) a still-unsupported form (a bare block) still errors, pointing at StrictMode.check.
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
    @test occursin("StrictMode.check", sprint(showerror, err))
end

@testitem "mode override forces the analysis mode at runtime (sidesteps the baked const)" begin
    using StrictMode
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    T = (Tuple{Int, Float64, Float32},)
    # :fast is the default engine; the heuristic still catches boxing.
    fs = findings(boxy, T; guarantees = (:noboxing,), mode = :fast)
    @test any(StrictMode._failed, fs)
    # check honors the override too.
    @test_throws StrictViolation check(boxy, T; guarantees = (:noboxing,), mode = :fast)
end

@testitem ":fast allocation verdicts are :suspect, and :suspect still gates" begin
    using StrictMode
    # The `:fast` engine reads typed IR, where an allocation site LLVM will later elide is still
    # present, so its allocation verdicts are structural GUESSES rather than the proof AllocCheck
    # gives — measured ~28% false on a real consumer (issue #17: 19 of 68, every one 0 bytes). They
    # therefore carry `:suspect` rather than `:fail`, which does three things: they render
    # distinctly, `nsuspect` counts them separately, and — the part that matters — `@strict_function`
    # WARNS instead of aborting a consumer's precompile, where the proof is unreachable by
    # construction (issue #18 part 2).
    #
    # What it deliberately does NOT do is stop gating. `nfailures` still counts `:suspect`, because a
    # sweep that reports green while sitting on a real allocation regression is the vacuous-green
    # shape this package exists to remove. Opting out is per-call, not the default.
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    T = (Tuple{Int, Float64, Float32},)

    fs = findings(boxy, T; guarantees = (:noalloc,), mode = :fast)
    @test only(fs).status === :suspect          # a guess, labelled as one...
    @test nsuspect(fs) == 1
    @test nfailures(fs) == 1                    # ...but it still counts against you
    @test StrictMode._failed(only(fs))
    @test_throws StrictViolation check(boxy, T; guarantees = (:noalloc,))

    # :typestable is NOT downgraded — return-type concreteness is exact, not a guess.
    ts = findings(boxy, T; guarantees = (:typestable,), mode = :fast)
    @test all(f -> f.status in (:pass, :fail), ts)
    @test nsuspect(ts) == 0
end

@testitem "a crashed :full backend reports :skip, never :pass" begin
    using StrictMode, StrictModeTest
    # The sixth vacuous-green bug on this branch. `would_fail_noalloc` returns false when AllocCheck
    # errored, and a swallowed JET error leaves `opt_reports` empty — so `findings(...; mode=:full)`
    # reported `:pass` for every method whose analysis CRASHED. In a sweep that is the CI gate
    # reporting success for code it never checked, and the vacuous `:pass` was cached besides.
    # "Could not check" and "is fine" must never render the same.
    boom(x::Int) = x + 1
    boom(1)
    StrictMode._be_opt_result(::typeof(boom), types) = throw(AssertionError("JET crashed"))
    StrictMode._be_check_allocs(::typeof(boom), types) = throw(AssertionError("AllocCheck crashed"))
    StrictMode.clear_cache!()
    try
        for g in (:typestable, :noalloc, :noboxing)
            f = only(findings(boom, (Int,); guarantees = (g,), mode = :full))
            @test f.status === :skip
            @test f.reason != ""
        end
        # …and @explain must not affirmatively claim the check passed.
        rep = StrictMode._strict_report("boom(Int64)", boom, (Int,))
        @test !occursin("✓ no issues (JET", sprint(io -> show(io, MIME"text/plain"(), rep)))
        @test occursin("did not run", sprint(io -> show(io, MIME"text/plain"(), rep)))
        s = sprint(io -> show(io, rep))
        @test occursin("stable?", s)      # compact form must not assert "stable" either
    finally
        StrictMode.clear_cache!()
    end
end
