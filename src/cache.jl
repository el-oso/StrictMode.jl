# Incremental cache for `findings`, keyed by method identity + world + signature + guarantees +
# mode. A re-run of `audit`/`check_all` only re-analyzes methods that actually changed: a
# redefined method (a Revise edit) gets a fresh `Method` identity → cache miss → re-analyzed;
# everything unchanged hits. This is what makes a whole-package re-check near-instant.
#
# Limitation (documented): the key is the *checked* method, not its callees — editing a callee
# without touching the caller can leave the caller's cached finding stale until `clear_cache!()`.

const _CACHE = Dict{Any, Vector{StrictFinding}}()
const _CACHE_LOCK = ReentrantLock()
const _CACHE_HITS = Ref(0)
const _CACHE_MISSES = Ref(0)

function _cache_key(@nospecialize(f), @nospecialize(types::Tuple), guarantees, mode::Symbol)
    m = try
        which(f, types)
    catch
        return nothing   # no/ambiguous method → don't cache
    end
    return (objectid(m), m.primary_world, types, Tuple(guarantees), mode, _IGNORE_THROW[])
end

"""
    StrictMode.clear_cache!()

Drop the incremental `findings` cache. Use it if you edited a *callee* of a checked method (the
cache keys on the checked method, so such an edit may not invalidate the caller automatically).
"""
function clear_cache!()
    @lock _CACHE_LOCK begin
        empty!(_CACHE)
        _CACHE_HITS[] = 0
        _CACHE_MISSES[] = 0
    end
    @lock _SIGNAL_MEMO_LOCK empty!(_SIGNAL_MEMO)   # the fast-scan memo shares the staleness contract
    return nothing
end

"""
    StrictMode.cache_stats() -> (; entries, hits, misses)

Counters for the incremental `findings` cache.
"""
cache_stats() = (; entries = length(_CACHE), hits = _CACHE_HITS[], misses = _CACHE_MISSES[])
