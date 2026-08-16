using StrictMode
# StrictModeTest supplies the AllocCheck/JET/TrimCheck proofs. StrictMode alone analyzes with the
# value-free heuristic; loading StrictModeTest flips `backend_available()` on, and every guarantee
# escalates to the proof at CALL time. A real package does the same in its test/runtests.jl: depend
# on StrictMode in Project.toml, StrictModeTest in test/Project.toml.
using StrictModeTest   # supplies the AllocCheck/JET/TrimCheck proofs; StrictMode alone is the heuristic
using TestItemRunner

# Tests run with checks_enabled=true (see test/Project.toml [preferences.StrictMode]) so the
# failing-path items exercise the guarantees. TestItemRunner runs items in THIS process, where the
# backend (AllocCheck+JET) is already loaded above.
#
# TestItemRunner rather than ReTestItems: ReTestItems assigns `Test.TESTSET_PRINT_ENABLE[] = true`
# in its runner's `finally`, and that binding became a `ScopedValue` in Julia 1.13, so the whole
# suite dies before a single item runs. TestItemRunner depends only on TestItems/Test/TOML/Pkg.
#
# Filter to one item by name (the `runtests(StrictMode; name=r"F10")` equivalent):
#   @run_package_tests filter = ti -> occursin(r"F10", ti.name)
@run_package_tests filter = ti -> startswith(ti.filename, joinpath(@__DIR__, ""))
