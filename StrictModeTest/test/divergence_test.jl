@testitem "divergence_report — flags scan-vs-proof disagreement, IP-free" begin
    using StrictMode, StrictModeTest

    # A store into a `Dict` can grow its table, several calls down in Base. The scan reads Base to
    # a fixed depth and finds nothing; the AllocCheck proof reads all of it. So the two disagree
    # in the direction a divergence report exists to surface: the scan passes and the proof fails.
    module Quux
    struct QuuxBox
        n::Int
    end
    quux_top(b::QuuxBox, d::Dict{Int, Float64}) = (d[b.n] = 1.0; nothing)
    end
    Quux.quux_top(Quux.QuuxBox(1), Dict{Int, Float64}())

    d = divergence_report(Quux.quux_top, (Quux.QuuxBox, Dict{Int, Float64}))
    @test !isempty(d)
    @test any(t -> t[1] === :noalloc && t[2] == false && t[3] == true, d.diverged)

    s = sprint(show, d)
    # IP-free: the user's type names and source must NOT appear
    @test !occursin("QuuxBox", s)
    @test !occursin("quux", s)
    # but the anonymized shape, category labels, and versions must
    @test occursin("T1", s)
    @test occursin("proof:", s)
    @test occursin("julia=", s) && occursin("StrictMode=", s)

    # An agreeing function → no divergence
    safe(x::Int) = x + 1
    @test isempty(divergence_report(safe, (Int,)))

    # save_divergence writes the same IP-free content to a file
    path = tempname()
    try
        StrictModeTest.save_divergence(d, path)
        txt = read(path, String)
        @test !occursin("QuuxBox", txt)
        @test occursin("versions", txt)
    finally
        rm(path; force = true)
    end
end

@testitem "divergence is about FLAGGED-ness, not the status symbol" begin
    using StrictMode, StrictModeTest
    # Regression guard: this map must be built from `_failed`, the one predicate that decides what
    # counts. A hand-written status comparison here recorded findings as "the scan did not flag", so
    # a call BOTH engines flag reported as a divergence — the exact inverse of what
    # divergence_report is for.
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    T = (Tuple{Int, Float64, Float32},)
    ff = findings(boxy, T; guarantees = (:noalloc, :noboxing))
    fl = proof_findings(boxy, T; guarantees = (:noalloc, :noboxing))
    @test all(StrictMode._failed, vcat(ff, fl))    # BOTH engines flagged the call
    @test isempty(divergence_report(boxy, T; guarantees = (:noalloc, :noboxing)).diverged)
end

@testitem "a factorization stored into a concretely typed field agrees between the engines" begin
    using StrictMode, StrictModeTest, LinearAlgebra
    # The `:new` of the `Cholesky` wrapper is an immutable holding a heap reference, and it is
    # written straight into a concretely typed mutable field — an inline store, so nothing is
    # heap-allocated and AllocCheck proves it. The scan has to reach the same verdict: a rule that
    # counts every store builtin as a box reds this shape while the proof passes it.
    mutable struct Core2{T}
        cap::Matrix{T}
        rho::Vector{T}
        fact::Cholesky{T, Matrix{T}}
    end
    function refresh!(c::Core2{T}) where {T}
        for i in eachindex(c.rho)
            c.cap[i, i] += inv(c.rho[i])
        end
        c.fact = cholesky!(Symmetric(c.cap); check = false)
        return issuccess(c.fact)
    end

    k = 4
    c = Core2(Matrix{Float64}(I, k, k), fill(2.0, k), cholesky(Matrix{Float64}(I, k, k)))
    refresh!(c)
    T = (typeof(c),)
    @test !StrictMode._alloc_signals(refresh!, T).alloc
    @test isempty(divergence_report(refresh!, T; guarantees = (:noalloc, :noboxing)).diverged)
end
