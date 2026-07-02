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
