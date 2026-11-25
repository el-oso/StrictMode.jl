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
#
# `Pkg.test(; test_args = ["corpus"])` runs only the `:noalloc` corpus and `["rest"]` everything
# else, so the two halves can run as two processes at once; no argument runs both.
const PART = isempty(ARGS) ? "all" : only(ARGS)
PART in ("all", "corpus", "rest") || error("test argument must be \"corpus\" or \"rest\", got \"$PART\"")
const CORPUS = joinpath(@__DIR__, "corpus_test.jl")
in_part(file) = PART == "all" || (PART == "corpus") == (file == CORPUS)
@run_package_tests filter = ti -> startswith(ti.filename, joinpath(@__DIR__, "")) && in_part(ti.filename)
