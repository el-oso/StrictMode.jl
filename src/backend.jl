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

# Whether `:full` @assert_noalloc/@assert_noboxing exempt a detected one-time-init allocation
# barrier (see effects.jl) from AllocCheck's all-paths proof, substituting the already-correct
# `:fast` steady-state heuristic instead. `true` (default) = the exemption is active.
const _IGNORE_BARRIER = Ref(true)

"""
    StrictMode.ignore_barrier() -> Bool

Whether `:full` `@assert_noalloc`/`@assert_noboxing` (and `findings`/`check`) exempt a call
recognized as routing through a one-time-init allocation barrier
(`Base.OncePerProcess`/`OncePerThread`, or a function registered via
[`register_alloc_barrier!`](@ref)) from AllocCheck's all-paths proof. Default `true`. See
[`StrictMode.set_ignore_barrier!`](@ref).
"""
ignore_barrier() = _IGNORE_BARRIER[]

"""
    StrictMode.set_ignore_barrier!(b::Bool)

Set whether `:full` exempts a detected allocation barrier from AllocCheck's all-paths proof.
`false` disables the exemption — a barrier-containing call reds `:full` `@assert_noalloc` exactly
as it would without this feature (AllocCheck's static proof sees the barrier's one-time
allocation and has no way to know it is amortized). Clears the findings cache, since it changes
`:full` `:noalloc`/`:noboxing` results.
"""
function set_ignore_barrier!(b::Bool)
    _IGNORE_BARRIER[] = b
    clear_cache!()
    return b
end

# Barrier-aware wrapper around `_be_check_allocs`. Filtering AllocCheck's own per-instance
# backtraces to attribute allocations to a barrier does not work in practice — measured on a real
# `OncePerProcess`-memoized calibrator, 24 of 52 reported instances merge into generic Base
# scheduler/lock/task internals ("multiple call sites") with no single traceable origin, even
# under an exact type-based filter. So the exemption is granted at the STATIC-IR level instead
# (`_alloc_signals`'s `barrier` signal, effects.jl): when a call is recognized as routing through
# a barrier AND the barrier-aware `:fast` heuristic finds nothing else allocating/boxing/an
# abstract-eltype container, skip AllocCheck's per-instance proof entirely and report a clean,
# empty allocation list — this is deliberately scoped to the "clean except for a recognized
# barrier" case; a barrier call that ALSO has some other real allocation risk falls through to the
# normal (noisier, but honest) AllocCheck proof, since the heuristic alone can't produce
# AllocCheck-typed per-site instances for that case. The `abscontainer` check matters: without it
# a barrier call that ALSO reads an abstract-eltype container (e.g. a `Vector{Real}` field) would
# pass :full while :fast's own `_findings_fast` (`check.jl`) correctly fails it via
# `sig.abscontainer !== nothing` — :full must not become MORE permissive than :fast. Returns
# `(allocs, exempted::Bool)`.
function _checked_allocs(@nospecialize(f), @nospecialize(types::Tuple))
    if _IGNORE_BARRIER[]
        sig = _alloc_signals(f, types)
        if sig.barrier && !sig.alloc && !sig.boxing && sig.abscontainer === nothing
            @info "StrictMode: `$(f)` reaches a one-time-init allocation barrier — :full noalloc/noboxing exempted (steady-state :fast heuristic used instead of AllocCheck's all-paths proof for this call). Disable with StrictMode.set_ignore_barrier!(false)." maxlog = 1
            return (Any[], true)
        end
    end
    return (_be_check_allocs(f, types), false)
end
