@testitem "divergence_report — flags fast↔full disagreement, IP-free" begin
    using StrictMode

    # Internal dynamic dispatch through an abstract eltype, but with a concrete (`Float64`) return —
    # the canonical case `:fast` misses (concrete return fools the boxing heuristic) and `:full`
    # (AllocCheck) catches.
    abstract type Shape end
    struct Circ <: Shape
        r::Float64
    end
    struct Sq <: Shape
        s::Float64
    end
    area(c::Circ) = 3.14 * c.r^2
    area(s::Sq) = s.s^2
    total(v::Vector{Shape}) = sum(a -> area(a), v)

    d = divergence_report(total, (Vector{Shape},))
    @test !isempty(d)
    # fast says pass, full says fail on the dispatch-driven guarantees
    @test any(t -> t[1] === :noboxing && t[2] == false && t[3] == true, d.diverged)

    s = sprint(show, d)
    # IP-free: the user's type names and source must NOT appear
    @test !occursin("Shape", s)
    @test !occursin("Circ", s)
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
