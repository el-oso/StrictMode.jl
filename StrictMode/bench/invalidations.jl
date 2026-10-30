# Invalidation probe: how much already-compiled code loading StrictMode throws away.
#
# Run with:  julia --project=bench bench/invalidations.jl [max_invalidations]
# With an argument it exits non-zero when the count is above it, so CI can hold a threshold.
#
# Why this is separate from `StrictModeTest.test_latency`, which measures load and first-call time
# directly: those are what a user of THIS package feels, and invalidations are paid by DOWNSTREAM
# code. This package can load in 130 ms and still discard precompiled Base or dependency code that
# a consumer then rebuilds. No measurement of this package alone can see that.
#
# Why SnoopCompile lives here and not in StrictModeTest: it pulls 61 packages, nearly all of them
# for flame graphs (FlameGraphs, Colors, FileIO) and LLVM snooping (YAML) that this never calls,
# and Julia cannot load part of a package — so every consumer's test environment would carry them.
#
# Why its `uinvalidated` is used rather than a count of our own: `@snoop_invalidations` returns a
# flat, interleaved sequence in which an item's meaning depends on its position and a depth
# integer. A true count has to drop the entries tagged `invalidate_mt_cache` (a transient dispatch
# cache clear, no compiled code lost) and `verify_methods` (superseded, still reachable by
# `invoke`), and Core.Compiler's own internals. Counting `MethodInstance`s without that filter
# reports 32 for this package where the answer is 0.

using SnoopCompileCore
invs = @snoop_invalidations using StrictMode
using SnoopCompile          # the analysis half, loaded AFTER the snoop so its own load is excluded

const LIMIT = isempty(ARGS) ? nothing : tryparse(Int, first(ARGS))
isnothing(LIMIT) && !isempty(ARGS) &&
    error("bench/invalidations.jl: expected an integer threshold, got $(repr(first(ARGS)))")

umis = uinvalidated(invs)
trees = invalidation_trees(invs)
n = length(umis)

println("StrictMode invalidations: ", n, " unique MethodInstance(s)")
println("  method-level log entries: ", length(invs.logmeths), ", edge-level: ", length(invs.logedges))
println("  attributed trees: ", length(trees))

if !isempty(trees)
    println()
    println("Worst offenders (the method whose definition invalidated the most):")
    scored = [(t, sum(SnoopCompile.countchildren, t.backedges; init = 0) + sum(SnoopCompile.countchildren, t.mt_backedges; init = 0)) for t in trees]
    sort!(scored; by = last, rev = true)
    for (t, score) in first(scored, 5)
        println("  ", rpad(string(score), 6), t.reason, "  ", t.method)
    end
end

# One JSONL record per run, like the other probes here, so a later run can be compared against
# this one rather than against a remembered number.
mkpath(joinpath(@__DIR__, "results"))
open(joinpath(@__DIR__, "results", "invalidations.jsonl"), "a") do io
    println(
        io, "{\"package\":\"StrictMode\",\"version\":\"", pkgversion(StrictMode),
        "\",\"julia\":\"", VERSION, "\",\"invalidations\":", n,
        ",\"trees\":", length(trees), ",\"logmeths\":", length(invs.logmeths),
        ",\"logedges\":", length(invs.logedges), "}"
    )
end

if !isnothing(LIMIT)
    println()
    if n > LIMIT
        println("OVER THRESHOLD: ", n, " invalidation(s) against a limit of ", LIMIT)
        exit(1)
    end
    println("within threshold: ", n, " <= ", LIMIT)
end
