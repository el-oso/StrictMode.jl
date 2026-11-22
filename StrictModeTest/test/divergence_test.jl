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

@testitem "divergence_report lists a different cause apart from a different verdict" begin
    using StrictMode, StrictModeTest, Test

    # Both engines fail every one of these on :noalloc. `diverged` stays empty for all of them;
    # `cause_diverged` names the guarantee only when the two codes differ.
    module Causes
    using StrictMode
    mutable struct W
        io::IOStream
        a::Vector{Float64}
        m::Matrix{Float64}
    end
    @noinline wra(w::W) = (write(w.io, w.a); 0.0)
    @noinline wrb(w::W) = (write(w.io, w.m); 0.0)
    const POOL = Ref(Float64[])
    @noinline function grow!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    @strict_exempt :noalloc reason = "pool" grow!
    @noinline drive(f::F, n::Int) where {F} = (
        s = 0.0; for i in 1:n
            s += f(i)
        end; s
    )
    # Both engines set the exempt pool aside and report what is left, the wait.
    c_two_ex(w::W, n::Int) = drive(i -> wra(w) + wrb(w) + grow!(i)[1], n)
    plain(n::Int) = sum(zeros(n))
    const TW = W(open(tempname(), "w"), zeros(4), zeros(2, 2))
    end
    C = Causes
    C.c_two_ex(C.TW, 2)
    C.plain(2)

    d = divergence_report(C.plain, (Int,); guarantees = (:noalloc,))
    @test isempty(d)
    @test isempty(d.cause_diverged)

    d = divergence_report(C.c_two_ex, (C.W, Int); guarantees = (:noalloc,))
    @test isempty(d)
    @test isempty(d.cause_diverged)
    @test only(StrictMode.findings(C.c_two_ex, (C.W, Int); guarantees = (:noalloc,))).code === :SM0017
    @test only(StrictModeTest.proof_findings(C.c_two_ex, (C.W, Int); guarantees = (:noalloc,))).code === :SM0017

    # A report whose engines both fail with different codes says so, and stays empty.
    d = StrictModeTest.StrictDivergence(
        d.diverged, [(:noalloc, :SM0017, :SM0002)], d.signature, d.return_category,
        d.scan_signals, d.proof_signals, d.versions,
    )
    @test isempty(d)
    s = sprint(show, d)
    @test occursin("different cause", s) && occursin("SM0017", s) && occursin("SM0002", s)
    @test !occursin("c_two_ex", s) && !occursin("grow", s)
end
