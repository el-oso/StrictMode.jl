# Incremental cache for `findings`, keyed by method identity + world + signature + guarantees.
# A re-run of `audit` only re-analyzes methods that actually changed: a redefined method (a Revise
# edit) gets a fresh `Method` identity → cache miss → re-analyzed; everything unchanged hits. This
# is what makes a whole-package re-check near-instant.
#
# Limitation (documented): the key is the *checked* method, not its callees — editing a callee
# without touching the caller can leave the caller's cached finding stale until `clear_cache!()`.

const _CACHE = Dict{Any, Vector{StrictFinding}}()
const _CACHE_LOCK = ReentrantLock()
const _CACHE_HITS = Ref(0)
const _CACHE_MISSES = Ref(0)

# `_FAST_ALLOC_DEPTH[]` is part of the key: it is a user-facing knob, and a deeper walk finds
# STRICTLY MORE than a shallower one. Omitting it hands back the shallow verdict to a caller who
# asked to look deeper — staleness that can only ever lose findings, which is the direction that
# goes quiet. (`_SIGNAL_MEMO` in effects.jl already keys on depth; this is the outer layer.)
function _cache_key(@nospecialize(f), @nospecialize(types::Tuple), guarantees)
    m = try
        which(f, types)
    catch
        return nothing   # no/ambiguous method → don't cache
    end
    return (objectid(m), m.primary_world, types, Tuple(guarantees), _FAST_ALLOC_DEPTH[])
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
    @lock _SIGNAL_MEMO_LOCK begin                  # the scan memos share the staleness contract
        empty!(_SIGNAL_MEMO)
        empty!(_TOP_SIGNAL_MEMO)
    end
    @lock _ESCAPE_MEMO_LOCK empty!(_ESCAPE_MEMO)   # …as does the escape-analysis memo
    return nothing
end

"""
    StrictMode.cache_stats() -> (; entries, hits, misses)

Counters for the incremental `findings` cache.
"""
cache_stats() = (; entries = length(_CACHE), hits = _CACHE_HITS[], misses = _CACHE_MISSES[])
