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

# Regression: `CpuId.cachesize()` does not only RETURN a degenerate tuple — on a host with no cache
# leaves it THROWS, and the extension's `__init__` used to let that escape. Interactively that is
# just "extension failed to load"; during PRECOMPILATION it is fatal and aborts the whole package,
# so StrictMode+CpuId dependents (PureBLAS) were uninstallable on Apple Silicon. Reported 2026-09-01
# against 0.3.10 / CpuId 0.3.1 / Julia 1.12.7 on an M4 Pro.
#
# This cannot be reached through a REAL `cachesize()` on x86 CI — the throw only happens on non-x86,
# where CpuId's `cpuid` is an all-zeros stub. Hence `_init_cache_bytes` takes the probe as a function
# so the throwing case can be injected here, on any architecture.
@testitem "CpuId cache ingest survives a THROWING probe (aarch64 / Apple Silicon)" begin
    using StrictMode
    saved = StrictMode._CACHE_BYTES[]
    try
        # exactly what CpuId does on aarch64: _throw_unsupported_leaf(0x00000004)
        @test StrictMode._init_cache_bytes(() -> error("This CPU does not provide information on cpuid leaf 0x00000004.")) == false
        @test StrictMode._CACHE_BYTES[] == saved       # defaults kept, nothing bricked

        # other throw flavours a stub/VM could produce
        @test StrictMode._init_cache_bytes(() -> throw(BoundsError((), 3))) == false
        @test StrictMode._init_cache_bytes(() -> throw(ArgumentError("no leaf"))) == false
        @test StrictMode._CACHE_BYTES[] == saved

        # the non-throwing paths still behave: degenerate declines, valid applies
        @test StrictMode._init_cache_bytes(() -> ()) == false
        @test StrictMode._init_cache_bytes(() -> (49_152, 1_310_720, 268_435_456)) == true
        @test StrictMode._CACHE_BYTES[] == (l1 = 49_152, l2 = 1_310_720, l3 = 268_435_456)
    finally
        StrictMode._CACHE_BYTES[] = saved
    end
end
