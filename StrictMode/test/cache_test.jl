@testitem "findings cache: hit on unchanged method, miss after redefinition" begin
    using StrictMode
    clear_cache!()
    g(x::Int) = x + 1
    findings(g, (Int,); guarantees = (:typestable,))    # miss → fills cache
    findings(g, (Int,); guarantees = (:typestable,))    # hit
    s = cache_stats()
    @test s.hits ≥ 1
    @test s.misses ≥ 1

    @eval g(x::Int) = x + 2                              # "edit" → fresh Method identity
    findings(g, (Int,); guarantees = (:typestable,))    # miss again (auto-invalidated)
    @test cache_stats().misses ≥ 2

    clear_cache!()
    @test cache_stats() == (; entries = 0, hits = 0, misses = 0)
end

@testitem "clear_cache! empties the cache" begin
    using StrictMode
    h(x::Int) = 2x
    findings(h, (Int,); guarantees = (:typestable,))
    @test cache_stats().entries ≥ 1
    clear_cache!()
    @test cache_stats().entries == 0
end

@testitem "a cached verdict is invalidated when a CALLEE changes" begin
    using StrictMode

    # The cache key names the checked method, which an edit one level down leaves identical: the
    # `Method` object and its `primary_world` are untouched. Before, that returned a stale `:pass`
    # for a caller whose callee had started allocating — a cache that lies in the quiet direction.
    cb_callee(x::Int) = x + 1
    cb_caller(x::Int) = cb_callee(x) * 2
    cb_caller(1)
    StrictMode.clear_cache!()

    @test only(StrictMode.findings(cb_caller, (Int,); guarantees = (:noalloc,))).status === :pass
    before = StrictMode.cache_stats()
    @test only(StrictMode.findings(cb_caller, (Int,); guarantees = (:noalloc,))).status === :pass
    @test StrictMode.cache_stats().hits == before.hits + 1      # caching still works

    @eval cb_callee(x::Int) = [x][1] + 1                        # only the callee changes
    Base.@invokelatest cb_caller(1)
    cached = only(Base.@invokelatest StrictMode.findings(cb_caller, (Int,); guarantees = (:noalloc,)))

    StrictMode.clear_cache!()
    fresh = only(Base.@invokelatest StrictMode.findings(cb_caller, (Int,); guarantees = (:noalloc,)))

    # The cached answer must agree with the uncached one. Asserting agreement rather than `:fail`
    # keeps the test honest if the scan's verdict for this shape ever changes.
    @test cached.status === fresh.status
    @test cached.status === :fail

    StrictMode.clear_cache!()
end
