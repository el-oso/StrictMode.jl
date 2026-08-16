"""
    StrictModeTest

The rigorous half of StrictMode. `StrictMode` itself analyzes with a value-free, Base-inference-only
engine that needs no backend and is cheap enough to run at load time; `StrictModeTest` adds the
proofs — AllocCheck's static no-allocation proof, JET's optimization analysis, and TrimCheck's
`juliac --trim=safe` verifier — and is meant for a package's `test/` environment only.

There is no preference to switch between them: **the tier is the dependency graph.** Depend on
`StrictMode` and you get the heuristic; add `StrictModeTest` to your test environment and the same
declarations are re-checked against the proofs.

Write `using StrictModeTest` **alone** in a test file. It re-exports StrictMode's surface, and
importing both packages is a hard `UndefVarError` at macro expansion rather than a silent
downgrade — the tier cannot be selected by accident.
"""
module StrictModeTest

using StrictMode
using AllocCheck
using JET
using TrimCheck
using TypeContracts   # its TrimDiagnostics parses the trim verifier's output
using PrecompileTools: @setup_workload, @compile_workload

# ── AllocCheck / JET backend ─────────────────────────────────────────────────────────────────────
# These fill the seam functions declared in StrictMode's src/backend.jl. They used to live in a
# package extension gated on AllocCheck+JET being present as weak dependencies; here they are
# unconditional, because a package that depends on StrictModeTest has asked for exactly this.

# `ignore_throw` (default true, via `StrictMode.set_ignore_throw!`): don't count allocations on
# never-taken error/throw branches (BoundsError etc.) — they are not on the hot path and produce
# false positives on runtime-zero-alloc code.
StrictMode._be_check_allocs(@nospecialize(f), @nospecialize(types)) =
    AllocCheck.check_allocs(f, types; ignore_throw = StrictMode._IGNORE_THROW[])

StrictMode._be_opt_result(@nospecialize(f), @nospecialize(types)) = JET.report_opt(f, types)

StrictMode._be_opt_reports(@nospecialize(r)) = JET.get_reports(r)

# Is this AllocCheck instance a *boxing* / dynamic-dispatch allocation (driven by type
# uncertainty), as opposed to a legitimate typed heap allocation (a `Vector`, `Memory`, …)?
function StrictMode._be_is_boxing(@nospecialize(inst))
    inst isa AllocCheck.DynamicDispatch && return true
    if inst isa AllocCheck.AllocatingRuntimeCall
        n = inst.name
        # jl_box_int64 (boxing a primitive), jl_get_nth_field_checked (runtime tuple/field index
        # → boxing). Excludes array-grow / string runtime calls.
        return occursin("box", lowercase(n)) || occursin("get_nth_field", n)
    end
    inst isa AllocCheck.AllocationSite && return inst.type === Core.Box   # captured-variable box
    return false
end

# ── TrimCheck backend ────────────────────────────────────────────────────────────────────────────
# TrimCheck's public API (`@validate` / `validate_function`) only accepts a call-expr or a
# single-method function eval'd in `Main` — it cannot check an arbitrary concrete `(f, types)`. So we
# drive its core directly: the same `hook_verify_typeinf_trim() do … typeinf_ext_toplevel(…,
# TRIM_SAFE) end` that `validate_function` runs, but for our exact signature. We reference
# TrimCheck's own `Compiler` binding (as `validate_function` does) so we hit the same verifier.
#
# (f, types) -> (passed::Bool, findings::Vector{String}). `types` may be a `Type{<:Tuple}`
# (e.g. `Tuple{Int,Float64}`, as the AllocCheck/JET seam receives) or a plain tuple of types.
function StrictMode._be_trim_validate(@nospecialize(f), @nospecialize(types))
    argtypes = (types isa Type && types <: Tuple) ? collect(types.parameters) : collect(types)
    rts = Base.return_types(f, Tuple{argtypes...})
    if length(rts) != 1
        return (
            false, [
                "could not infer a single concrete return type ($(length(rts)) results); " *
                    "trim verification needs a fully-inferred signature",
            ],
        )
    end
    ret_type = rts[1]
    Comp = TrimCheck.Compiler
    try
        TrimCheck.hook_verify_typeinf_trim() do
            Comp.typeinf_ext_toplevel(
                Any[Core.svec(ret_type, Tuple{typeof(f), argtypes...})],
                [Base.get_world_counter()],
                Comp.TRIM_SAFE,
            )
        end
        return (true, String[])
    catch err
        if err isa TrimCheck.TrimVerificationErrors
            # Route the raw verifier output through TypeContracts' `TrimDiagnostics` — the same parser
            # `explain_trim` uses — for deduplicated, source-mapped sites (statement + user frame),
            # instead of hand-filtering the raw dump.
            raw = try
                sprint(show, err)
            catch
                ""
            end
            tf = TypeContracts.explain_trim_failure(raw)
            if !tf.recognized || isempty(tf.sites)
                return (false, ["juliac --trim=safe rejected this signature (verifier output not recognized)"])
            end
            findings = String[]
            for s in tf.sites
                # frames are innermost-first ⇒ the outermost frame is the user-relevant call site.
                loc = isempty(s.frames) ? "" :
                    "  [" * basename(last(s.frames).file) * ":" * string(last(s.frames).line) * "]"
                push!(findings, s.statement * loc)
            end
            if length(findings) > 8
                extra = length(findings) - 8
                findings = vcat(findings[1:8], ["… (+$extra more call site(s))"])
            end
            return (false, findings)
        end
        rethrow(err)
    end
end

# Warm JET + AllocCheck into this package's precompile image so the first check in a test run is
# fast — but only when checks are enabled (otherwise nobody runs them).
@setup_workload begin
    wk_dot(a, b) = @inbounds a[1] * b[1] + a[2] * b[2]
    A = (1.0, 2.0)
    B = (3.0, 4.0)
    types = (typeof(A), typeof(B))
    @compile_workload begin
        if StrictMode.CHECKS_ENABLED
            StrictMode._BACKEND_AVAILABLE[] = true
            try
                StrictMode.check(wk_dot, types; guarantees = (:typestable, :noalloc, :noboxing, :inlined), fail = :none)
                StrictMode._strict_report("warmup", wk_dot, types)   # warms @explain (+ @code_warntype)
            catch
            finally
                StrictMode._BACKEND_AVAILABLE[] = false               # reset; __init__ sets it at load
            end
        end
    end
end

function __init__()
    StrictMode._BACKEND_AVAILABLE[] = true
    StrictMode._TRIMCHECK_AVAILABLE[] = true
    return nothing
end

end # module StrictModeTest
