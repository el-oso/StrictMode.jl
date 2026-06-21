# v0.2 roadmap — not yet exported.
#
# Idiom-encoding helpers that make the fast path the *easy* path, so users never hand-write the
# avoid-boxing pattern:
#
# `@unroll for i in 1:N ... end` — `@generated`-backed loop unrolling that emits straight-line
# code with *literal* indices (driven by `Val(i)`), eliminating the runtime-tuple-indexing
# boxing class entirely (the trap that cost a measured 135x in the FFT work).
#
# `staticval(n) = Val(n)` and friends — thin helpers to push counts/sizes into the type domain
# for full compile-time specialization, without users learning the `Val{N}` ceremony.
#
# Intentionally empty in v0.1 to keep the module layout stable.
