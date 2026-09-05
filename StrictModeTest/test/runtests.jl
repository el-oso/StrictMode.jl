# StrictModeTest owns the proofs — AllocCheck, JET, TrimCheck — and the `@test_*` / `test_*` API
# that gates on them. These tests cover exactly that: the primitives StrictMode itself cannot test,
# because StrictMode does not depend on those packages at all.
using StrictMode
using StrictModeTest
using TestItemRunner

# `StrictModeTest.__init__` refuses to load unless checks are enabled, so reaching this line already
# proves the tier is armed; `proofs_test.jl` asserts it anyway rather than leaving it implicit.
#
# TestItemRunner rather than ReTestItems, for the same reason StrictMode's suite uses it:
# ReTestItems assigns `Test.TESTSET_PRINT_ENABLE[] = true` in its runner's `finally`, and that
# binding became a `ScopedValue` in Julia 1.13, so the suite dies before a single item runs.
#
# Filter to one item by name:
#   @run_package_tests filter = ti -> occursin(r"#27", ti.name)
@run_package_tests filter = ti -> startswith(ti.filename, joinpath(@__DIR__, ""))
