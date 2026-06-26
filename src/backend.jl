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

# Trim backend — an *independent* weak dependency (separate from AllocCheck/JET): `TrimCheck` drives
# juliac's real `verify_typeinf_trim` verifier. The `:full` `trim_compatible` guarantee uses it; `:fast`
# (and the fallback when TrimCheck is absent) uses the TypeContracts static scan in `trimsafe.jl`.
const _TRIMCHECK_AVAILABLE = Ref(false)

"""
    StrictMode.trimcheck_available() -> Bool

Whether the `TrimCheck` extension is loaded. When `true`, the `:full` `trim_compatible` guarantee runs
juliac's authoritative `verify_typeinf_trim` verifier; when `false` it falls back to the TypeContracts
static scan (the same check `:fast` uses).
"""
trimcheck_available() = _TRIMCHECK_AVAILABLE[]

function _be_trim_validate end  # (f, types) -> (passed::Bool, findings::Vector{String})

# Whether the `:full` AllocCheck pass ignores allocations on never-taken throw branches (a
# `BoundsError` construction, etc.). `true` (default) = hot-path semantics: a runtime-zero-alloc
# kernel with bounds checks is *not* a false positive. Strict users can count them with
# `set_ignore_throw!(false)`. (The `:fast` heuristic is already throw-path clean.)
const _IGNORE_THROW = Ref(true)

"""
    StrictMode.ignore_throw() -> Bool

Whether `:full` AllocCheck analysis ignores allocations on never-taken throw branches (default
`true`). See [`set_ignore_throw!`](@ref).
"""
ignore_throw() = _IGNORE_THROW[]

"""
    StrictMode.set_ignore_throw!(b::Bool)

Set whether `:full` AllocCheck ignores throw-branch allocations. `true` (default) gives hot-path
semantics; `false` counts allocations on error branches that never execute. Clears the findings
cache, since it changes `:full` `noalloc`/`noboxing` results.
"""
function set_ignore_throw!(b::Bool)
    _IGNORE_THROW[] = b
    clear_cache!()
    return b
end
