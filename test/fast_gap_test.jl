# Fast↔full gap regressions (2026-07-02 corpus study, bench/mode_gap.jl): every class of
# false-negative the study found gets a minimal reproducer asserting the :fast verdict, plus
# guards that the fixes did not reintroduce the F8/F9 false-positive classes.

@testitem "fast catches internal dynamic dispatch with a concrete return" begin
    # The `_bcast32` shape: un-`Val`ed ntuple → Tuple{Vararg} feeding a concrete-result call.
    # Old fast passed (return concrete, dynamic :call result concrete); JET-full flags it.
    using StrictMode
    mkshape(x::UInt8, n::Int) = sum(ntuple(i -> x + UInt8(i), n))
    fs = StrictMode.findings(mkshape, (UInt8, Int); guarantees = (:typestable, :noboxing), mode = :fast)
    @test all(f.status === :fail for f in fs)
end

@testitem "fast follows non-inlined callees for allocations" begin
    # The SwissDict-grow shape: the caller's own body is clean, the allocation lives in a
    # @noinline helper. Old fast scanned one body and passed; AllocCheck sees through.
    using StrictMode
    @noinline hidden_alloc(n::Int) = zeros(n)
    outer(n::Int) = length(hidden_alloc(n))
    fs = StrictMode.findings(outer, (Int,); guarantees = (:noalloc,), mode = :fast)
    @test only(fs).status === :fail
end

@testitem "fast flags Memory allocation (Core.memorynew builtin)" begin
    # 1.12 `Memory{T}(undef, n)` lowers to the `memorynew` builtin :call — neither :new nor
    # :foreigncall, so the old scan missed direct Memory allocation entirely.
    using StrictMode
    memv(n::Int) = Memory{Int}(undef, n)
    fs = StrictMode.findings(memv, (Int,); guarantees = (:noalloc,), mode = :fast)
    @test only(fs).status === :fail
end

@testitem "fast ignores throw-path allocations (F8 semantics)" begin
    # Error branches build exceptions/messages — real allocations, never taken on the success
    # path. :full excludes them (ignore_throw); the callee-recursion must too, or every guarded
    # kernel false-positives (pfft! did, during development).
    using StrictMode
    guarded(x::Float64) = (x < 0 && throw(ArgumentError("negative")); 2x)
    fs = StrictMode.findings(guarded, (Float64,); guarantees = (:noalloc, :typestable), mode = :fast)
    @test all(f.status === :pass for f in fs)
end

@testitem "fast still exempts union-split callees (F9 guard)" begin
    # A small all-concrete Union return is union-split, not boxing — including heap members
    # (Union{Nothing, Vector{Int}}). Flagging these was the F9 over-report.
    using StrictMode
    @noinline maybe(x::Int) = x > 0 ? x : nothing
    usplit(x::Int) = (y = maybe(x); y === nothing ? 0 : y)
    @noinline maybevec(x::Int) = x > 0 ? Int[] : nothing
    usplitheap(x::Int) = maybevec(x) === nothing
    fs = StrictMode.findings(usplit, (Int,); guarantees = (:typestable, :noboxing), mode = :fast)
    @test all(f.status === :pass for f in fs)
    fs = StrictMode.findings(usplitheap, (Int,); guarantees = (:noboxing,), mode = :fast)
    @test only(fs).status === :pass
end

@testitem "fast follows non-inlined callees 2 levels deep for allocations (F36, GH #8)" begin
    # The BLAS/LAPACK driver shape (PureBLAS.jl): `driver! -> prep-helper -> similar/Array` puts
    # the real allocation 2 non-inlined hops below the entry point. F35's depth-1 default only
    # sees the direct callee; this regressed to `fast=pass` on 7 real driver functions.
    using StrictMode
    @noinline hidden_alloc(n::Int) = zeros(n)
    @noinline workspace(n::Int) = hidden_alloc(n)
    driver(n::Int) = length(workspace(n))
    fs = StrictMode.findings(driver, (Int,); guarantees = (:noalloc,), mode = :fast)
    @test only(fs).status === :fail
end

@testitem "fast propagates a non-inlined callee's own boxing signal (F36, GH #8)" begin
    # Distinct from F9: F9 was about flagging an `:invoke` merely for having an abstract
    # *recorded result type* (mutating helpers with unused returns). This is the callee's own
    # body genuinely dispatching dynamically, one level down — the caller's own body is clean.
    using StrictMode
    abstract type Shape end
    struct Circ <: Shape
        r::Float64
    end
    struct Sq <: Shape
        s::Float64
    end
    area(c::Circ) = 3.14 * c.r^2
    area(s::Sq) = s.s^2
    @noinline dispatch_sum(v::Vector{Shape}) = sum(a -> area(a), v)
    caller(v::Vector{Shape}) = dispatch_sum(v)
    fs = StrictMode.findings(caller, (Vector{Shape},); guarantees = (:noboxing,), mode = :fast)
    @test only(fs).status === :fail
end
