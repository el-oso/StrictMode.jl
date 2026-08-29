@testitem "@assert_trim_compatible scans; @test_trim_compatible runs juliac's verifier" begin
    using StrictMode, StrictModeTest

    safe_fn(x::Int) = x * 2 + 1
    unsafe_fn(x::Int) = length(Base.return_types(sin, (Float64,)))  # reflection → trim-unsafe

    # Macro form
    @test (@assert_trim_compatible safe_fn(3)) == 7                 # passes → returns the value
    @test_logs (:warn,) match_mode = :any (@assert_trim_compatible unsafe_fn(3))
    @test_throws StrictViolation @test_trim_compatible unsafe_fn(3)

    # StrictMode'"'"'s engine: the TypeContracts static scan
    @test all(f -> f.status === :pass, findings(safe_fn, (Int,); guarantees = (:trim_compatible,)))
    @test any(f -> f.status === :fail, findings(unsafe_fn, (Int,); guarantees = (:trim_compatible,)))

    # :full = juliac's verify_typeinf_trim verifier via TrimCheck
    @test all(f -> f.status === :pass, proof_findings(safe_fn, (Int,); guarantees = (:trim_compatible,)))
    fr = proof_findings(unsafe_fn, (Int,); guarantees = (:trim_compatible,))
    @test fr[1].status === :fail
    @test occursin("juliac", fr[1].reason)                         # cites the real verifier, not the static heuristic

    # back-compat: the static-only @assert_trim_safe / :trimsafe still work
    @test (@assert_trim_safe safe_fn(3)) == 7
    @test any(f -> f.status === :fail, findings(unsafe_fn, (Int,); guarantees = (:trimsafe,)))
end
