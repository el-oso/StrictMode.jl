# Incremental cache for `findings`, keyed by method identity + world + signature + guarantees.
# A re-run of `audit` only re-analyzes methods that actually changed: a redefined method (a Revise
# edit) gets a fresh `Method` identity → cache miss → re-analyzed; everything unchanged hits. This
# is what makes a whole-package re-check near-instant.
#
# The key names the *checked* method, not its callees, so an edit one level down leaves it
# identical. That is covered separately: each entry also holds the `CodeInstance`s the verdict was
# read from, and Julia caps their `max_world` when a callee changes. A method that has never been
# compiled has no instance to watch, and neither has a verdict that read the body of a task the
# method spawns (that code holds no edge to what the task calls), so such an entry answers only in
# the world it was made in.
#
# A registration a verdict reads (a scoped type, a trust boundary, a barrier, an exemption) is also
# read from the stores of the loaded packages, and loading a package that holds one calls no
# registration function to clear the cache. So an entry also records how many packages were loaded.

# The findings, the `CodeInstance`s they were read from (see `_watch_instances`), the world, and
# the number of loaded packages.
const _CACHE = Dict{Any, Tuple{Vector{StrictFinding}, Vector{Core.CodeInstance}, UInt, Int}}()
const _CACHE_LOCK = ReentrantLock()
const _CACHE_HITS = Ref(0)
const _CACHE_MISSES = Ref(0)

# `_FAST_ALLOC_DEPTH[]` is part of the key: it is a user-facing knob, and a deeper walk finds
# STRICTLY MORE than a shallower one. Omitting it hands back the shallow verdict to a caller who
# asked to look deeper — staleness that can only ever lose findings, which is the direction that
# goes quiet. (`_SIGNAL_MEMO` in effects.jl already keys on depth; this is the outer layer.)
#
# Whether a package overrides `getproperty` on an `Untrusted` is part of it too, for `:trusted`. An
# untyped `p.x` is a dynamic call, and the compiler records no edge for one, so defining that method
# caps no instance the entry watches.
function _cache_key(@nospecialize(f), @nospecialize(types::Tuple), guarantees)
    m = try
        which(f, types)
    catch
        return nothing   # no/ambiguous method → don't cache
    end
    overridden = :trusted in guarantees ?
        (_untrusted_getproperty_overridden(2), _untrusted_getproperty_overridden(3)) : nothing
    return (objectid(m), m.primary_world, types, Tuple(guarantees), _FAST_ALLOC_DEPTH[], overridden)
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
# invalidated this way, and `_entry_valid` keeps it for its own world only.
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

# Packages are never unloaded, so a count that moved means a package was loaded since.
_loaded_count() = length(Base.loaded_modules)

# Whether a cache entry made in `world` with `watched`, while `loaded` packages were loaded, still
# answers. With nothing to watch, any definition since may be an edit to a callee, so only the same
# world does. A package loaded since may hold a registration the verdict did not read.
_entry_valid(watched, world::UInt, loaded::Int) = loaded == _loaded_count() &&
    (isempty(watched) ? world == Base.get_world_counter() : _instances_valid(watched))

# What the scan keeps is worth keeping in a session, where the next check reuses it, and not at a
# precompile, where nothing asks again and a process that is about to write a package image holds
# it as live heap: 282 MB after a module check of 300 methods.
_release_after_load_check() = ccall(:jl_generating_output, Cint, ()) == 1 ? clear_cache!() : nothing

"""
    StrictMode.clear_cache!()

Drop the incremental `findings` cache.

A cached verdict is dropped on its own when the method it names or a callee is edited: the compiled
code it was read from is invalidated, and a verdict on a method with no compiled code, or one that
read the body of a task the method spawns, is kept only until the next definition. This is for what no definition announces, such as a changed setting a
verdict depends on.
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
        empty!(_BODY_MEMO)
        empty!(_ORIGIN_MEMO)
        empty!(_SIG_STRING_MEMO)
        empty!(_SCAN_CODE_CACHE)
        empty!(_RETTYPE_MEMO)
        empty!(_MATCH_MEMO)
    end
    @lock _ESCAPE_MEMO_LOCK empty!(_ESCAPE_MEMO)   # …as does the escape-analysis memo
    @lock _OWNED_DEEP_LOCK begin                   # …and the walk behind `:owned`
        empty!(_OWNED_NODE_MEMO)
        empty!(_OWNED_DEEP_MEMO)
    end
    return nothing
end

"""
    StrictMode.cache_stats() -> (; entries, hits, misses)

Counters for the incremental `findings` cache.
"""
cache_stats() = (; entries = length(_CACHE), hits = _CACHE_HITS[], misses = _CACHE_MISSES[])
