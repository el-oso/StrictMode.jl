using StrictMode
# AllocCheck + JET are weak deps; loading them activates StrictModeAnalysisExt (the backend), so
# the checks actually run. (A real package does the same in its test/runtests.jl.)
using AllocCheck, JET, TrimCheck
using TestItemRunner

# WHY TestItemRunner AND NOT ReTestItems (migrated 2026-08-26, Julia 1.13.0-rc3 — see issue #23):
# ReTestItems 1.35.2 (the current release) cannot run on 1.13. It assigns to
# `Test.TESTSET_PRINT_ENABLE[]`, which 1.13 turned into a `Base.ScopedValues.ScopedValue{Bool}` with
# no `setindex!`, so `runtests` dies in its own `finally` block before a single item executes:
#     MethodError: no method matching setindex!(::ScopedValue{Bool}, ::Bool)   ReTestItems.jl:510
# That is not a version bound to relax — it reproduces on the newest release against a freshly
# resolved environment.
#
# The migration is cheap because BOTH runners consume the same `@testitem` macro from TestItems.jl:
# all 186 items here are unchanged, and `setup = [Fixtures]` works identically. Only the shared-setup
# blocks differ — `@testsetup module X ... end` became `@testmodule X begin ... end` in two files
# (memsafe_test.jl, no_spill_test.jl). This is ONE-WAY: ReTestItems has no `@testmodule`.
#
# Tradeoff accepted deliberately: TestItemRunner is single-process and sequential — no `nworkers`,
# `worker_init_expr`, per-item timeouts or retries. This suite used none of them; it ran with the
# default `nworkers=0` (in-process) precisely so the weak-dep backend loaded above stays visible to
# every item, which is exactly TestItemRunner's only mode. So nothing is lost.

# Tests run with checks_enabled=true (see test/Project.toml [preferences.StrictMode]) so the
# failing-path items exercise the guarantees.

# Optional name filter, preserving what `runtests(StrictMode; name=...)` offered:
#   julia --project=. -e 'using Pkg; Pkg.test("StrictMode"; test_args=["scalar loop"])'
# No args → the whole suite.
const _NAME_RX = isempty(ARGS) ? nothing : Regex(join(ARGS, "|"))
_filter(ti) = isnothing(_NAME_RX) || occursin(_NAME_RX, ti.name)

@run_package_tests filter = _filter
