# v0.2 roadmap — not yet exported.
#
# `@assert_inlined f(args...)` — fail unless the call to `f` is inlined into its caller.
# Planned implementation (best-effort, empirical): compile a wrapper that calls `f(args...)`,
# inspect its `code_typed` (optimize=true), and fail if the wrapper still contains an `:invoke`
# / dynamic `:call` to `f`'s MethodInstance (i.e. it was *not* absorbed). Inlining is a
# heuristic, so this is reported as a best-effort guarantee with a clear caveat, not a proof.
#
# Intentionally empty in v0.1 to keep the module layout stable.
