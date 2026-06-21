using StrictMode
# AllocCheck + JET are weak deps; loading them activates StrictModeAnalysisExt (the backend), so
# the checks actually run. (A real package does the same in its test/runtests.jl.)
using AllocCheck, JET
using ReTestItems

# Tests run with checks_enabled=true (see test/Project.toml [preferences.StrictMode]) so the
# failing-path items exercise the guarantees. Default nworkers=0 → testitems run in this process,
# where the backend (AllocCheck+JET) is already loaded above.
runtests(StrictMode)
