@testitem "formatters render findings for each sink" begin
    using StrictMode
    fail = StrictFinding(:M, "g", "(Tuple{Int,Float64})", :noboxing, :fail, "tuple.jl", 33, "boxing", "use @unroll")
    pass = StrictFinding(:M, "f", "(Float64,)", :noalloc, :pass, "", 0, "", "")
    fs = [pass, fail]

    text = sprint(io -> format_findings(io, fs; format = :text))
    @test occursin("✗ noboxing", text)
    @test occursin("use @unroll", text)

    json = sprint(io -> format_findings(io, fs; format = :json))
    @test startswith(strip(json), "[") && occursin("\"status\":\"fail\"", json)
    @test occursin("\"line\":33", json)

    jsonl = sprint(io -> format_findings(io, fs; format = :jsonlines))
    @test count(==('\n'), jsonl) == 2   # one line per finding

    gh = sprint(io -> format_findings(io, fs; format = :github))
    @test occursin("::error file=tuple.jl,line=33::", gh)
    @test !occursin("[✓", gh)   # only failures in :github
end

@testitem "unknown format errors" begin
    using StrictMode
    f = StrictFinding(:M, "f", "()", :noalloc, :pass, "", 0, "", "")
    @test_throws ArgumentError format_findings(IOBuffer(), [f]; format = :nope)
end

@testitem "every guarantee has a fix hint" begin
    using StrictMode
    # `suggestion` is the machine-readable hint agents act on, so a finding must never ship with an
    # empty one. Enumerated from `_GUARANTEES` so a new guarantee fails here until it has a hint.
    for g in StrictMode._GUARANTEES
        @test StrictMode._suggestion(g) != ""
    end
    # A guarantee `_suggestion` does not cover still returns "": the loop above must be checking
    # per-guarantee branches, not a blanket fallback string.
    @test StrictMode._suggestion(:not_a_guarantee) == ""

    # The hint reaches the finding: `_mkfinding` copies it in on failure.
    for g in StrictMode._GUARANTEES
        f = StrictMode._mkfinding(:M, "f", "()", g, true, "why", "", 0)
        @test f.suggestion == StrictMode._suggestion(g)
    end
end
