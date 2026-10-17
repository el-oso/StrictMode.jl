# Diagnostic codes: a stable name per KIND of finding, so a verdict can be looked up and matched
# across runs where a reason sentence cannot be.

@testitem "a finding carries a code, and the code names the cause where one is known" begin
    using StrictMode

    # The abstract element type is the recognizable CAUSE of the instability, and the code says so
    # rather than naming the guarantee generically.
    bad(x::Vector{AbstractFloat}) = sum(x)
    fs = StrictMode.findings(bad, (Vector{AbstractFloat},); guarantees = (:typestable, :noalloc))
    ts = only(f for f in fs if f.guarantee === :typestable)
    @test ts.code === :SM0104                       # typestable / abstract_eltype
    @test only(f for f in fs if f.guarantee === :noalloc).code === :SM0002

    # A guarantee with no narrowed cause falls back to its own code.
    plain(x::Float64) = x > 0 ? 1 : "s"
    pf = only(StrictMode.findings(plain, (Float64,); guarantees = (:typestable,)))
    @test pf.code === :SM0001

    # The code is in the serialized record, which is the point: a saved report stays lookup-able.
    @test occursin("\"code\":\"SM0104\"", format_findings(fs; format = :json))

    # It shows next to the guarantee for a verdict worth looking up, and not for a pass.
    @test occursin("SM0104", sprint(show, ts))
    ok(x::Float64) = x * 2.0
    @test !occursin("SM", sprint(show, only(StrictMode.findings(ok, (Float64,); guarantees = (:typestable,)))))
end

@testitem "explain(code) describes a code, and an unknown one is an error" begin
    using StrictMode

    s = StrictMode.explain(:SM0104)
    @test occursin("SM0104", s)
    @test occursin("abstract_eltype", s)            # the cause it was issued for
    @test occursin("Fix:", s)                       # the same remedy the finding carries
    @test occursin("tier", s)                       # …and what the verdict is worth
    @test StrictMode.explain("SM0104") == s         # a string spelling works too

    # Unknown codes are rejected rather than answered vaguely: a code is never reused, so one
    # missing from the table was never published.
    @test_throws ArgumentError StrictMode.explain(:SM9999)

    # Every code in the table is explainable, and every guarantee has one.
    for (code, _, _) in StrictMode.codes()
        @test StrictMode.explain(code) isa String
    end
    for g in StrictMode.guarantee_names()
        @test StrictMode._code(g) !== :SM0000
    end

    # Codes are unique: two kinds sharing one number would make a lookup ambiguous.
    all_codes = [c for (c, _, _) in StrictMode.codes()]
    @test length(unique(all_codes)) == length(all_codes)
end
