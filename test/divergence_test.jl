@testitem "divergence_report — flags fast↔full disagreement, IP-free" begin
    using StrictMode

    # Internal dynamic dispatch through an abstract eltype, but with a concrete (`Float64`) return,
    # buried two non-inlined hops below the entry point — deeper than `_FAST_ALLOC_DEPTH[]` (2)
    # follows by default. `:fast` misses it (concrete return + out-of-reach depth fools the boxing
    # heuristic) and `:full` (AllocCheck/JET) catches it regardless of depth.
    #
    # SIX concrete subtypes, deliberately: with only two, Julia 1.13's optimizer union-splits the
    # `area` call and devirtualizes the whole thing — measured 32 B on 1.12 vs 0 B on 1.13 — so
    # AllocCheck and JET both (correctly) report clean and there is no divergence left to detect.
    # Six is past any union-split budget on both, which keeps this fixture a genuine example.
    abstract type Shape end
    struct S1 <: Shape
        v::Float64
    end
    struct S2 <: Shape
        v::Float64
    end
    struct S3 <: Shape
        v::Float64
    end
    struct S4 <: Shape
        v::Float64
    end
    struct S5 <: Shape
        v::Float64
    end
    struct S6 <: Shape
        v::Float64
    end
    area(x::S1) = x.v
    area(x::S2) = 2x.v
    area(x::S3) = 3x.v
    area(x::S4) = 4x.v
    area(x::S5) = 5x.v
    area(x::S6) = 6x.v
    @noinline _total_inner(v) = sum(a -> area(a), v)
    @noinline _total_mid(v) = _total_inner(v)
    total(v::Vector{Shape}) = _total_mid(v)

    d = divergence_report(total, (Vector{Shape},))
    @test !isempty(d)
    # Which guarantee surfaces it is an optimizer detail (1.12 and 1.13 both report :noalloc and
    # :noboxing here, but that is not something to pin). What must hold is the
    # DIRECTION — some dispatch-driven guarantee where :fast passes and :full catches it.
    @test any(t -> t[1] in (:typestable, :noalloc, :noboxing) && t[2] == false && t[3] == true, d.diverged)

    s = sprint(show, d)
    # IP-free: the user's type names and source must NOT appear
    @test !occursin("Shape", s)
    @test !occursin("S1", s) && !occursin("S6", s)
    @test !occursin("area", s)
    @test !occursin("total", s)
    # but the anonymized shape, category labels, and versions must
    @test occursin("T1", s)
    @test occursin("full:", s)
    @test occursin("julia=", s) && occursin("StrictMode=", s)

    # An agreeing function → no divergence
    safe(x::Int) = x + 1
    @test isempty(divergence_report(safe, (Int,)))

    # save_divergence writes the same IP-free content to a file
    path = tempname()
    try
        StrictMode.save_divergence(d, path)
        txt = read(path, String)
        @test !occursin("Shape", txt)
        @test occursin("versions", txt)
    finally
        rm(path; force = true)
    end
end
