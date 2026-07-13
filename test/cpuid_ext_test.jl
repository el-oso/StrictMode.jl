# Regression: `_set_cache_bytes!` must never throw on a degenerate `CpuId.cachesize()` result. On CPUs
# CpuId can't parse (EPYC 9455/Zen5, VMs masking the cache CPUID leaf) `cachesize()` returns () — the
# StrictModeCpuIdExt __init__ used to blindly destructure it (`l1,l2,l3 = cachesize()` → BoundsError),
# which crashed the extension load and took `using CpuId` (and downstream packages like PureBLAS) down.

@testitem "CpuId cache ingest is robust to empty/short/zero tuples" begin
    using StrictMode
    saved = StrictMode._CACHE_BYTES[]
    try
        # degenerate results CpuId can return on unrecognized CPUs / VMs — must NOT throw, must NOT apply
        for bad in ((), (0,), (32_768,), (32_768, 524_288), (0, 0, 0), (32_768, 0, 16_777_216))
            @test StrictMode._set_cache_bytes!(bad) == false
            @test StrictMode._CACHE_BYTES[] == saved           # default untouched
        end
        # a valid 3-tuple applies
        @test StrictMode._set_cache_bytes!((49_152, 1_310_720, 268_435_456)) == true
        @test StrictMode._CACHE_BYTES[] == (l1 = 49_152, l2 = 1_310_720, l3 = 268_435_456)
    finally
        StrictMode._CACHE_BYTES[] = saved
    end
end
