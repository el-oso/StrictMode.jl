@testitem "throw_report lists what a body raises itself" begin
    using StrictMode

    module ThrowSubject
    picky(x::Int) = x > 0 ? x : throw(ArgumentError("must be positive"))
    two(x::Int) = x > 0 ? (x > 10 ? throw(DomainError(x, "too big")) : x) : throw(ArgumentError("neg"))
    quiet(v::Vector{Float64}) = sum(v)
    indexes(v::Vector{Float64}) = v[1]
    end
    S = ThrowSubject

    @test throw_report(S.picky, (Int,)) == [ArgumentError]
    @test throw_report(S.two, (Int,)) == [ArgumentError, DomainError]   # sorted by name
    @test isempty(throw_report(S.quiet, (Vector{Float64},)))
    @test throw_report(S.picky, (Int,)) isa Vector{Type}

    # The scope decision, pinned: `v[1]` can raise a `BoundsError`, and it is NOT listed, because
    # the raise is inside `getindex`. Listing everything reachable would converge on "nearly
    # everything" for nearly every function and tell a reader nothing.
    @test isempty(throw_report(S.indexes, (Vector{Float64},)))

    # A throw on a branch no call reaches is still listed — that is the point of reading IR.
    @test ArgumentError in throw_report(S.picky, (Int,))
end

@testitem "throw_report sweeps a module and says what it leaves out" begin
    using StrictMode

    module ThrowMod
    raises(x::Int) = x > 0 ? x : throw(ArgumentError("no"))
    silent(x::Int) = x + 1
    end
    ThrowMod.raises(1); ThrowMod.silent(1)

    fs = throw_report(ThrowMod)
    f = only(fs)
    @test f.func == "raises"                      # `silent` contributes nothing
    @test f.status === :info && f.code === :SM0307
    @test occursin("`ArgumentError`", f.reason)
    @test occursin("callees are not listed", f.suggestion)
    @test isempty(throw_report(ThrowMod; only = r"^silent$"))
end
