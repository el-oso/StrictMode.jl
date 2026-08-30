# Time-tax benchmark: prove `:fast` triage and incremental caching make a whole-package re-check
# near-instant. Run with: julia --project=bench bench/timetax.jl
#
# This env is configured `analysis = "fast"` (bench/Project.toml). AllocCheck + JET are loaded so
# we can also time the `:full` per-method primitive for comparison.

using StrictMode
using AllocCheck, JET   # so StrictMode._be_check_allocs (the :full primitive) is available

const N = 500

# A module of N concrete methods (a representative mix: most clean, some allocating).
let blk = Expr(:block)
    for i in 1:N
        body = i % 7 == 0 ? :(collect(1:x)) : :(x * $i + 1)   # ~1/7 allocate, like cold helpers
        push!(blk.args, :($(Symbol("f", i))(x::Int) = $body))
    end
    @eval module Bench
    $blk
    end
end

fns = [(getfield(Bench, Symbol("f", i)), (Int,)) for i in 1:N]

# Warmup pass over EVERY method: pay Julia's one-time cold inference for both analysis paths up
# front, so the timed pass measures StrictMode's *marginal* per-method cost, not first-inference.
for (f, t) in fns
    StrictMode._alloc_signals(f, t)
    try
        StrictMode._be_check_allocs(f, t)
    catch
    end
end

# ---- per-method primitive cost (inference warm): :fast heuristic vs :full AllocCheck proof ---
t_fast = @elapsed for (f, t) in fns
    StrictMode._alloc_signals(f, t)
end
t_full = @elapsed for (f, t) in fns
    try
        StrictMode._be_check_allocs(f, t)
    catch
    end
end
println("Per-method allocation analysis over $N methods (inference warm):")
println("  :fast  (_alloc_signals, code_typed IR) : ", round(t_fast * 1.0e3; digits = 1), " ms")
println("  :full  (AllocCheck check_allocs)        : ", round(t_full * 1.0e3; digits = 1), " ms")
println("  speedup: ", round(t_full / max(t_fast, eps()); digits = 1), "×")

# ---- incremental cache: cold sweep, warm re-check, re-check after a 1-method edit ------------
clear_cache!()
mod_audit() = nfailures(audit(Bench; sweep = true, guarantees = (:typestable, :noalloc, :noboxing), io = devnull))

mod_audit()                                   # compile audit machinery (not timed)
clear_cache!()
t_cold = @elapsed mod_audit()
warm = cache_stats()
t_warm = @elapsed mod_audit()

@eval Bench f1(x::Int) = x * 1 + 2            # "edit" one method → its cache entry invalidates
t_edit = @elapsed mod_audit()
after = cache_stats()

println("\nWhole-module audit (sweep over ~$N method instances), :fast mode:")
println("  cold (all analyzed)       : ", round(t_cold * 1.0e3; digits = 1), " ms  (", warm.misses, " misses)")
println("  warm (all cached)         : ", round(t_warm * 1.0e3; digits = 1), " ms  (cache hits)")
println("  after editing 1 method    : ", round(t_edit * 1.0e3; digits = 1), " ms  (only the edit re-analyzed)")
println("  cache: ", after)
