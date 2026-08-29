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

@testitem "the throw-vs-warn partition is exhaustive and each guarantee lands on the right side" begin
    using StrictMode
    # `_guarantee_gates` is a hand-typed tuple in src/report.jl. Appending one symbol to it converts
    # a gate into a warning package-wide, and nothing else in the suite observes throw-vs-warn at
    # the macro boundary — so this pins the partition itself.
    #
    # The rule it encodes: a check that OBSERVES compiled output gates; one that INFERS something it
    # cannot see reports. Both lists are spelled out here rather than derived, precisely so that
    # moving a guarantee between them has to be a deliberate edit in two places.
    reports = (:noalloc, :noboxing, :no_scalar_loops, :trimsafe, :trim_compatible)
    gates = (:typestable, :owned, :inlined, :vectorized, :no_spill)
    for g in reports
        @test !StrictMode._guarantee_gates(g)
    end
    for g in gates
        @test StrictMode._guarantee_gates(g)
    end
    # Exhaustive over the guarantee list: a new `_GUARANTEES` entry must be classified, not
    # defaulted in by the blacklist's `!(kind in …)` without anyone noticing.
    @test Set(reports) ∪ Set(gates) == Set(StrictMode._GUARANTEES)

    # The value-based guarantees are not in `_GUARANTEES` (they never reach the findings pipeline),
    # but they still route through `_fail`, and they gate.
    for g in (:memsafe, :concurrency_safe, :no_threadid_state)
        @test StrictMode._guarantee_gates(g)
    end
end

@testitem "the warn path names macros that exist" begin
    using StrictMode
    # `_fail`'s note used to interpolate `@$kind` / `@test_$kind`, which sends a user to
    # `@no_scalar_loops` and `@test_trimsafe` — neither of which exists. Only four guarantees have a
    # proving counterpart at all, and `:trimsafe` is spelled `@assert_trim_safe`.
    macro_exists(name) = isdefined(StrictMode, Symbol(name)) || isdefined(Main, Symbol(name))
    for g in StrictMode._GUARANTEES
        own, proof = StrictMode._macro_names(g)
        @test isdefined(StrictMode, Symbol(own))
        isnothing(proof) && continue
        # The proving macros live in StrictModeTest; assert the NAME is one of the four that exist
        # rather than reaching across the package boundary from here.
        @test proof in ("@test_noalloc", "@test_noboxing", "@test_typestable", "@test_trim_compatible")
    end
    @test StrictMode._macro_names(:trimsafe)[1] == "@assert_trim_safe"
    @test isnothing(StrictMode._macro_names(:no_scalar_loops)[2])
end
