# Entry point: TestItemRunner discovers and runs every `@testitem` under test/. Items run in isolated
# modules and can be triggered individually by name:
#   julia --project=. -e 'using Pkg; Pkg.test(test_args=["F10"])'
using TestItemRunner
using StrictMode
# AllocCheck + JET are weak deps; loading them activates StrictModeAnalysisExt (the backend), so the
# checks actually run. (A real package does the same in its test/runtests.jl.) Loading them HERE is
# load-bearing: TestItemRunner is single-process, so the extension is live before any item runs.
using AllocCheck, JET, TrimCheck

# WHY TestItemRunner AND NOT ReTestItems (Julia 1.13.0-rc3; PureBLAS migrated 2026-08-16, this repo
# follows). ReTestItems 1.35.2 cannot run on 1.13 and there is no fixed release: it needs
# `Test.push_testset` / `Test.pop_testset` (both REMOVED in 1.13) and writes `Test.TESTSET_PRINT_ENABLE[]`
# (now a ScopedValue, no setindex!) at six sites on master — two of them on the COMMON path, so no
# `nworkers` setting avoids them. Not shimmable: 1.13 moved testset state from a mutable stack to dynamic
# scoping, keeping only the readers, and ReTestItems pushes/pops ACROSS function boundaries, which a
# ScopedValue (needing `with(...) do ... end` lexical nesting) cannot express. Upstream's only fix attempt
# (PR #235) has been open since 2025-12-18 and fails its own 1.12 CI.
#
# The migration is cheap because both packages consume the SAME `@testitem` macro from TestItems.jl: all
# 184 items and every `setup=[...]` call site are unchanged. Only the shared-setup blocks differ —
# `@testsetup module X ... end` became `@testmodule X begin ... end` (memsafe_test.jl, no_spill_test.jl).
# ONE-WAY: ReTestItems has no `@testmodule`.
#
# Tradeoff accepted: TestItemRunner is single-process and sequential — no `nworkers`, `worker_init_expr`,
# per-item timeouts or retries. This suite used `nworkers=0` (in-process) already, precisely so the
# AllocCheck+JET backend loaded above is visible to the items, so nothing is lost.

# Optional name filter via test args, e.g. `Pkg.test(test_args=["F10"])` runs only matching `@testitem`s.
# TestItemRunner has no `name=` kwarg (ReTestItems did), so the regex folds into a filter predicate —
# strictly more capable, since a filter composes with other predicates by `&&`.
const _NAME_RX = isempty(ARGS) ? nothing : Regex(join(ARGS, "|"))
_filter(ti) = isnothing(_NAME_RX) || occursin(_NAME_RX, ti.name)

@run_package_tests filter = _filter
