"""
    StrictViolation(kind, target, details) <: Exception

Thrown when a StrictMode guarantee fails.

- `kind::Symbol` — which guarantee (`:noalloc`, `:typestable`, `:strict_function`, ...).
- `target` — the call/definition the guarantee was attached to (an `Expr` or string).
- `details::String` — human-readable explanation (allocation sites, instability report, ...).
"""
struct StrictViolation <: Exception
    kind::Symbol
    target::Any
    details::String
end

function Base.showerror(io::IO, e::StrictViolation)
    print(io, "StrictViolation (@", e.kind, "): guarantee not satisfied")
    println(io)
    println(io, "  target:  ", e.target)
    details = isempty(e.details) ? "(no further detail)" : e.details
    print(io, "  reason:  ")
    # Indent multi-line detail blocks so they read as one section.
    print(io, replace(details, '\n' => "\n           "))
    return nothing
end

# Does StrictMode's own check for `kind` decide a build, or only report?
#
# It gates when the check OBSERVES something — a call present in the IR, a register spilled, a
# canary byte disturbed. It reports when the check INFERS something it cannot see, because a
# guarantee that guesses must not be able to abort a build:
#
# - `:noalloc`/`:noboxing` read typed IR, where an allocation LLVM will later elide is still
#   present. Measured ~28% false positives on a real consumer (issue #17).
# - `:no_scalar_loops` separates a hand-written scalar tail from LLVM's own `@simd` epilogue by
#   looking for `<N x …>` ops outside the loop-vectorizer's scaffolding, and LLVM's SLP vectorizer
#   emits exactly that shape for ordinary complex arithmetic.
# - `:trimsafe`/`:trim_compatible` use a static scan that does not model juliac's reachability
#   limit, so a PASS is incomplete and a FAIL is a guess about the same territory.
# - `:typestable` is split rather than listed: return-type concreteness gates, the depth-0 boxing
#   signal does not (see `_typestable_fast`), so a guarded `@warn` in a numeric function cannot
#   abort a build.
#
# The proofs gate unconditionally — that is what `StrictModeTest` is.
_guarantee_gates(kind::Symbol) =
    !(kind in (:noalloc, :noboxing, :no_scalar_loops, :trimsafe, :trim_compatible))

# The macro names for a guarantee, which are NOT derivable from its symbol: `:trimsafe` is spelled
# `@assert_trim_safe`, and only four guarantees have a proving counterpart at all. Interpolating
# `@$kind`/`@test_$kind` instead sends users to `@no_scalar_loops` and `@test_trimsafe`, neither of
# which exists.
function _macro_names(kind::Symbol)
    kind === :noalloc && return ("@assert_noalloc", "@test_noalloc")
    kind === :noboxing && return ("@assert_noboxing", "@test_noboxing")
    kind === :trim_compatible && return ("@assert_trim_compatible", "@test_trim_compatible")
    kind === :trimsafe && return ("@assert_trim_safe", "@test_trim_compatible")
    kind === :no_scalar_loops && return ("@assert_no_scalar_loops", nothing)
    return ("@assert_" * String(kind), nothing)
end

# Single choke point for every guarantee. `gates = false` reports instead of raising, for a check
# whose verdict is a structural guess.
function _fail(kind::Symbol, target, details::AbstractString; gates::Bool = _guarantee_gates(kind))
    v = StrictViolation(kind, target, String(details))
    gates && throw(v)
    own, proof = _macro_names(kind)
    @warn sprint(showerror, v) *
        "\n  note:    StrictMode's `$own` check is a heuristic, so it reports rather than gating. " *
        (
        isnothing(proof) ? "This guarantee has no proving counterpart — treat the verdict as a lead, not a fact." :
            "Add StrictModeTest and use `$proof` for the proof."
    )
    return nothing
end
