# Incremental cache for `findings`, keyed by method identity + world + signature + guarantees.
# A re-run of `audit` only re-analyzes methods that actually changed: a redefined method (a Revise
# edit) gets a fresh `Method` identity → cache miss → re-analyzed; everything unchanged hits. This
# is what makes a whole-package re-check near-instant.
#
# The key names the *checked* method, not its callees, so an edit one level down leaves it
# identical. That is covered separately: each entry also holds the `CodeInstance`s the verdict was
# read from, and Julia caps their `max_world` when a callee changes. A method that has never been
# compiled has no instance to watch, and only there is `clear_cache!()` still needed.

# The findings, plus the `CodeInstance`s they were read from — see `_watch_instances`.
const _CACHE = Dict{Any, Tuple{Vector{StrictFinding}, Vector{Core.CodeInstance}}}()
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

# What a cached verdict depends on, beyond its key: the compiled code the analysis read. A verdict
# comes from the method's typed IR, which is the compiled form of its whole call graph, so editing a
# CALLEE changes the answer while leaving the key identical — the `Method` object and its
# `primary_world` are untouched by an edit one level down.
#
# Julia does record it, on the compiled code rather than on the method: when a callee changes, the
# caller's `CodeInstance` has its `max_world` capped. Holding a reference to the instance the
# analysis read is therefore enough to notice. Measured: a `CodeInstance` reported valid before a
# callee edit and capped after it, while `objectid(which(...))` and `primary_world` were unchanged.
#
# A method nothing has compiled yet has no instance to watch, so a verdict for it cannot be
# invalidated this way — `clear_cache!()` remains the answer there.
function _watch_instances(@nospecialize(f), @nospecialize(types::Tuple))
    out = Core.CodeInstance[]
    m = try
        which(f, types)
    catch
        return out
    end
    # Only the instance compiled for THIS signature. A method's other specializations are other
    # verdicts, and one of them going stale says nothing about this one — watching them all turned
    # a 14 ms warm re-audit into 489 ms by invalidating entries that were still good.
    want = Tuple{typeof(f), types...}
    for mi in Base.specializations(m)
        isnothing(mi) && continue
        mi isa Core.MethodInstance || continue
        mi.specTypes === want || continue
        isdefined(mi, :cache) || continue
        ci = mi.cache
        ci isa Core.CodeInstance && push!(out, ci)
    end
    return out
end

_instances_valid(cis) = all(ci -> ci.max_world == typemax(UInt), cis)

"""
    StrictMode.clear_cache!()

Drop the incremental `findings` cache.

A cached verdict is dropped on its own when the compiled code it was read from is invalidated, which
covers editing a *callee* of a checked method. A method that has not been compiled at all has no
compiled code to watch, so reach for this after editing a callee of one of those.
"""
function clear_cache!()
    @lock _CACHE_LOCK begin
        empty!(_CACHE)
        _CACHE_HITS[] = 0
        _CACHE_MISSES[] = 0
    end
    _GENERATION[] += 1                            # re-arm every per-site guard (issue #29)
    @lock _SIGNAL_MEMO_LOCK begin                  # the scan memos share the staleness contract
        empty!(_SIGNAL_MEMO)
        empty!(_TOP_SIGNAL_MEMO)
        empty!(_RETTYPE_MEMO)
        empty!(_MATCH_MEMO)
    end
    @lock _ESCAPE_MEMO_LOCK empty!(_ESCAPE_MEMO)   # …as does the escape-analysis memo
    return nothing
end

"""
    StrictMode.cache_stats() -> (; entries, hits, misses)

Counters for the incremental `findings` cache.
"""
cache_stats() = (; entries = length(_CACHE), hits = _CACHE_HITS[], misses = _CACHE_MISSES[])
