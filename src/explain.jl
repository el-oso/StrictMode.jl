# v0.2 roadmap — not yet exported.
#
# `@explain f(args...)` — diagnostics mode. Instead of just failing, aggregate `@code_warntype`,
# JET (`@report_opt` / `@report_call`) and AllocCheck (`check_allocs`) output into one digestible
# `StrictReport`, with a human-readable `Base.show` that pinpoints *why* a guarantee failed
# (e.g. "allocates at line X due to type instability in variable y::Union{...}").
#
# This is the "tell me why" companion to the "fail loudly" assert macros.
#
# Intentionally empty in v0.1 to keep the module layout stable.
