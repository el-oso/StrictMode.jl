# Entry point for the one environment that installs `LLVM_full_jll`, and therefore the only place
# `mca_report` actually runs `llvm-mca`. Everywhere else the weak dependency is absent on purpose —
# it is ~680MiB — so `mca_available()` is false and `mca_test.jl`'s live item skips, which left this
# feature untested rather than merely unexercised.
#
# The environment is built by the CI step that calls this, not committed: a tracked `[deps]` naming
# `LLVM_full_jll` would pull 680MiB into any checkout that instantiated it.
using LLVM_full_jll
using StrictMode
using Test

@testset "llvm-mca live path" begin
    # Asserted first, not guarded on. If the extension is not loaded then `mca_report` raises and
    # every assertion below would report a broken environment as a failing feature — or, if they
    # were guarded, report an empty run as a pass.
    @test StrictMode.mca_available()
    include(joinpath(@__DIR__, "mca_live.jl"))
    mca_live_checks()
end
