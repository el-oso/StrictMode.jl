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
