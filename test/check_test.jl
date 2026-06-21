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
    @test StrictMode._callinfo(:(f.(x))) == (:broadcast, Any[:f, :x])
end

@testitem "macro hardening: keyword args give a clear error pointing at check" begin
    using StrictMode
    err = try
        StrictMode._callinfo(:(solve(a, b; tol = 1)))
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("StrictMode.check", sprint(showerror, err))
end
