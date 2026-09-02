module StrictModeCpuIdExt
using StrictMode: _init_cache_bytes
using CpuId: cachesize

# `cachesize()` has TWO failure modes on CPUs CpuId cannot describe, and only one of them is a value:
#
#   * it RETURNS `()` on x86 parts CpuId can't parse — brand-new models (EPYC 9455/Zen5) or VMs that
#     mask the deterministic-cache CPUID leaf. `_set_cache_bytes!` guards that: an empty/short tuple
#     keeps the default `_CACHE_BYTES` instead of BoundsError-ing.
#
#   * it THROWS on a host with no cache leaves AT ALL. CpuId's non-x86 `cpuid` is an all-zeros stub
#     (CpuInstructions.jl), so `hasleaf` is false for both 0x0000_0004 and 0x8000_001d and
#     `cachesize()` falls through to `_throw_unsupported_leaf(0x0000_0004)`. That is every aarch64
#     host, Apple Silicon included — the tuple guard never gets the chance to run.
#
# The second case needs a try/catch, not just the guard. An exception escaping `__init__` is only
# "extension failed to load" interactively, but during PRECOMPILATION it is fatal — it aborts the
# whole package. So any package depending on both StrictMode and CpuId (PureBLAS hard-depends on
# both) could not be installed on Apple Silicon at all. Reported 2026-09-01 against StrictMode 0.3.10
# / CpuId 0.3.1 / Julia 1.12.7 on an M4 Pro.
#
# The handling lives in `StrictMode._init_cache_bytes` so it can be exercised from x86 CI with an
# injected throwing probe; a real `cachesize()` only throws on hardware no CI runner here has.
__init__() = (_init_cache_bytes(cachesize); nothing)
end
