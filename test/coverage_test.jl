# Coverage gate: audit(mod; require = :public) fails for public functions with no registered
# guarantee, so "every kernel declares its guarantees" is a red test, not a convention.

@testitem "coverage gate flags unregistered public functions" begin
    using StrictMode

    module CovPkg
        export covered, uncovered, coldpub
        covered(x::Float64) = x + 1.0
        uncovered(x::Float64) = x * 2.0
        coldpub(x::Float64) = [x]          # cold by design — exempted below
        _private(x::Float64) = x - 1.0     # not public: never flagged
    end

    empty!(StrictMode.registered_strict())
    empty!(StrictMode.exempt_strict())
    StrictMode.register_strict!(CovPkg.covered, (Float64,); guarantees = (:typestable,))

    # uncovered + coldpub flagged; covered (registered) and _private (not public) are not.
    fs = audit(CovPkg; require = :public, io = devnull)
    @test nfailures(fs) == 2
    @test Set(f.func for f in fs if f.guarantee === :coverage) == Set(["uncovered", "coldpub"])
    @test all(f.status === :fail for f in fs if f.guarantee === :coverage)
    @test all(f.line > 0 for f in fs if f.guarantee === :coverage)

    # The exempt kwarg is a visible opt-out.
    fs = audit(CovPkg; require = :public, exempt = (:coldpub,), io = devnull)
    @test nfailures(fs) == 1
    @test only(f for f in fs if f.guarantee === :coverage).func == "uncovered"

    # @strict_exempt is honored too.
    StrictMode._exempt!(:coldpub)
    fs = audit(CovPkg; require = :public, io = devnull)
    @test [f.func for f in fs if f.guarantee === :coverage] == ["uncovered"]

    # JSON output carries the gate for agents.
    io = IOBuffer()
    audit(CovPkg; require = :public, format = :json, io)
    s = String(take!(io))
    @test occursin("\"coverage\"", s) && occursin("register_strict!", s)

    empty!(StrictMode.registered_strict())
    empty!(StrictMode.exempt_strict())
end

@testitem "coverage gate: clean module passes; bad kwargs throw" begin
    using StrictMode

    module CovClean
        export k
        k(x::Int) = x + 1
    end

    empty!(StrictMode.registered_strict())
    StrictMode.register_strict!(CovClean.k, (Int,); guarantees = (:typestable,))
    @test nfailures(audit(CovClean; require = :public, io = devnull)) == 0

    @test_throws ArgumentError audit(CovClean; require = :exported, io = devnull)
    @test_throws ArgumentError audit(:registered; require = :public, io = devnull)
    empty!(StrictMode.registered_strict())
end
