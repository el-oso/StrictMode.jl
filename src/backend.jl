# Heavy-analysis backend seam. AllocCheck and JET are big, so they are *weak* dependencies: a
# package can depend on StrictMode and ship neither. With checks disabled the guarantee macros
# expand to bare calls and nothing here is touched. When checks are enabled, add AllocCheck and
# JET to the environment — the `StrictModeAnalysisExt` extension then provides methods for the
# four functions below (this is the *only* place that touches AllocCheck / JET).
#
# Recommended setups:
#   - production  : depend on StrictMode only (lightweight; checks off).
#   - dev (human) : add Revise + AllocCheck + JET — live `watch()` loop with real checks.
#   - agent / CI  : add AllocCheck + JET — `audit(...)` with structured findings.

const _BACKEND_AVAILABLE = Ref(false)

"""
    StrictMode.backend_available() -> Bool

Whether the analysis backend (the `AllocCheck` + `JET` extension) is loaded. `false` means a
package depends on StrictMode without them — enabling checks then asks you to add them.
"""
backend_available() = _BACKEND_AVAILABLE[]

function _require_backend()
    _BACKEND_AVAILABLE[] && return nothing
    error(
        "StrictMode: checks are enabled but the analysis backend is not loaded. AllocCheck and " *
            "JET are optional (weak) dependencies — add BOTH to this environment to run the " *
            "checks (e.g. your test/ or dev project). Production builds that leave checks off " *
            "need neither."
    )
end

# The backend seam: the StrictModeAnalysisExt extension adds methods for these. They have no
# methods in the core package, so callers must go through `_require_backend()` first.
function _be_check_allocs end   # (f, types) -> Vector of AllocCheck allocation instances
function _be_is_boxing end      # (alloc_instance) -> Bool  (boxing / dynamic-dispatch subclass)
function _be_opt_result end     # (f, types) -> JET optimization-analysis result
function _be_opt_reports end    # (result)   -> the result's reports
