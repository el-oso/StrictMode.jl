module StrictModeCpuIdExt
using StrictMode: _CACHE_BYTES
using CpuId: cachesize

function __init__()
    l1, l2, l3 = cachesize()
    return l1 > 0 && l2 > 0 && (_CACHE_BYTES[] = (l1 = l1, l2 = l2, l3 = l3))
end
end
