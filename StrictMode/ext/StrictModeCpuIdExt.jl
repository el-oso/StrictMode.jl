module StrictModeCpuIdExt
using StrictMode: _set_cache_bytes!
using CpuId: cachesize

# `cachesize()` returns () on CPUs CpuId can't parse (brand-new models like EPYC 9455/Zen5, or VMs that
# mask the deterministic-cache CPUID leaf). `_set_cache_bytes!` guards that — an empty/short tuple keeps
# the default `_CACHE_BYTES` instead of BoundsError-ing here and bricking `using CpuId` (and every package
# that transitively loads CpuId, e.g. PureBLAS). See StrictMode._set_cache_bytes! + its regression test.
__init__() = (_set_cache_bytes!(cachesize()); nothing)
end
