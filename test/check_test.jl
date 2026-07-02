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
    @test all(f -> f.status === :pass, check(boxy, T; guarantees = (:typestable,), fail = :none))
    @test any(f -> f.status === :fail, check(boxy, T; guarantees = (:noalloc,), fail = :none))
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
        StrictMode._callinfo(:(begin
            x + 1
        end))
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
    # Force :fast regardless of the precompile-baked ANALYSIS_MODE; the heuristic still catches boxing.
    fs = findings(boxy, T; guarantees = (:noboxing,), mode = :fast)
    @test any(f -> f.status === :fail, fs)
    # check honors the override too.
    @test_throws StrictViolation check(boxy, T; guarantees = (:noboxing,), mode = :fast)
end
