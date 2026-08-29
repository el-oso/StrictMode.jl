using StrictMode
# `StrictMode` alone analyzes with a value-free engine and reports; `StrictModeTest` supplies the
# AllocCheck/JET/TrimCheck proofs and the `@test_*` / `test_*` surface that gates. A real package
# does the same: depend on StrictMode in Project.toml, StrictModeTest in test/Project.toml.
using StrictModeTest
using TestItemRunner

# `checks_enabled` defaults to true, so the failing-path items exercise the guarantees — and
# `StrictModeTest.__init__` refuses to load if something turned it off. TestItemRunner runs items in
# THIS process, where the proofs are already loaded above.
#
# TestItemRunner rather than ReTestItems: ReTestItems assigns `Test.TESTSET_PRINT_ENABLE[] = true`
# in its runner's `finally`, and that binding became a `ScopedValue` in Julia 1.13, so the whole
# suite dies before a single item runs. TestItemRunner depends only on TestItems/Test/TOML/Pkg.
#
# Filter to one item by name (the `runtests(StrictMode; name=r"F10")` equivalent):
#   @run_package_tests filter = ti -> occursin(r"F10", ti.name)
@run_package_tests filter = ti -> startswith(ti.filename, joinpath(@__DIR__, ""))
