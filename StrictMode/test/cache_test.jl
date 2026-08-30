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
