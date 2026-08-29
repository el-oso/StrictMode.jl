# The proofs: AllocCheck's all-paths no-allocation analysis, JET's optimization analysis, and
# TrimCheck's `juliac --trim=safe` verifier, run over a concrete `(f, types)` signature.
#
# These are called directly, not through a seam. A guarantee here can never find its backend
# missing, because the package that defines it is the package that depends on it.

using StrictMode: StrictFinding, StrictViolation

"""
    AnalysisError <: Exception

Thrown when a backend call (JET's `report_opt`, in practice) fails outright while compiling
`(f, types)`, instead of returning a report. The usual cause: full inference visits every branch of
a method regardless of which one is reachable at runtime for a given call, so a runtime-dead branch
that reaches a `@generated` function whose generator throws (an `@assert` at generation time, rather
than a guarded `return :(throw(...))`) fails analysis even though the function itself runs fine.
Carries the checked target, the analyzed signature, and the original error, so the failure names
what was being analyzed instead of surfacing as a bare exception raised from inside the backend.
"""
struct AnalysisError <: Exception
    target::String
    signature::String
    original::Any
end

function Base.showerror(io::IO, e::AnalysisError)
    print(
        io,
        "StrictModeTest: the analysis backend failed while compiling `", e.target,
        "` (signature ", e.signature, "). Full inference visits every branch of a method regardless ",
        "of runtime reachability, so a runtime-dead branch that reaches a `@generated` function whose ",
        "generator throws (e.g. `@assert` at generation time) fails analysis here even though the call ",
        "runs fine. Fix the generator to always succeed: guard it and return a throw expression instead ",
        "of asserting — `cond || return :(throw(AssertionError(\"...\")))`. Original error: "
    )
    showerror(io, e.original)
    return nothing
end

# ── AllocCheck ───────────────────────────────────────────────────────────────────────────────────

# Whether an allocation barrier recognized by StrictMode's IR scan
# (`Base.OncePerProcess`/`OncePerThread`, or a function passed to `register_alloc_barrier!`) exempts
# a call from AllocCheck's all-paths proof.
const _IGNORE_BARRIER = Ref(true)

"""
    ignore_barrier() -> Bool

Whether `@test_noalloc`/`@test_noboxing` exempt a call recognized as routing through a one-time-init
allocation barrier (`Base.OncePerProcess`/`OncePerThread`, or a function registered via
`StrictMode.register_alloc_barrier!`) from AllocCheck's all-paths proof. Default `true`.
See [`set_ignore_barrier!`](@ref).
"""
ignore_barrier() = _IGNORE_BARRIER[]

"""
    set_ignore_barrier!(b::Bool)

Set whether a detected allocation barrier is exempt from AllocCheck's all-paths proof. `false`
disables the exemption — a barrier-containing call then reds `@test_noalloc` exactly as it would
without this feature, since AllocCheck's static proof sees the barrier's one-time allocation and
has no way to know it is amortized. Clears StrictMode's findings cache.
"""
function set_ignore_barrier!(b::Bool)
    _IGNORE_BARRIER[] = b
    StrictMode.clear_cache!()
    return b
end

# `StrictMode.ignore_throw()` (default true): don't count allocations on never-taken error/throw branches
# (BoundsError etc.) — they are not on the hot path and produce false positives on
# runtime-zero-alloc code.
_raw_allocs(@nospecialize(f), @nospecialize(types)) =
    AllocCheck.check_allocs(f, types; ignore_throw = StrictMode.ignore_throw())

# Is this AllocCheck instance a *boxing* / dynamic-dispatch allocation (driven by type
# uncertainty), as opposed to a legitimate typed heap allocation (a `Vector`, `Memory`, …)?
function _is_boxing(@nospecialize(inst))
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

# Barrier-aware wrapper around `_raw_allocs`. Filtering AllocCheck's own per-instance backtraces to
# attribute allocations to a barrier does not work in practice — measured on a real
# `OncePerProcess`-memoized calibrator, 24 of 52 reported instances merge into generic Base
# scheduler/lock/task internals ("multiple call sites") with no single traceable origin, even under
# an exact type-based filter. So the exemption is granted at the STATIC-IR level instead (StrictMode's
# `_alloc_signals` `barrier` signal): when a call is recognized as routing through a barrier AND the
# barrier-aware scan finds nothing else allocating/boxing/an abstract-eltype container, skip
# AllocCheck's per-instance proof entirely and report a clean, empty allocation list. This is
# deliberately scoped to the "clean except for a recognized barrier" case; a barrier call that ALSO
# has some other real allocation risk falls through to the normal (noisier, but honest) proof, since
# the scan alone cannot produce AllocCheck-typed per-site instances for that case. The
# `abscontainer` check matters: without it, a barrier call that ALSO reads an abstract-eltype
# container (e.g. a `Vector{Real}` field) would pass here while StrictMode's own scan correctly
# fails it — the proof must never be MORE permissive than the scan. Returns `(allocs, exempted)`.
function _checked_allocs(@nospecialize(f), @nospecialize(types::Tuple))
    if _IGNORE_BARRIER[]
        sig = StrictMode._alloc_signals(f, types)
        if sig.barrier && !sig.alloc && !sig.boxing && isnothing(sig.abscontainer)
            @info "StrictModeTest: `$(f)` reaches a one-time-init allocation barrier — noalloc/noboxing exempted (StrictMode's steady-state IR scan used instead of AllocCheck's all-paths proof for this call). Disable with set_ignore_barrier!(false)." maxlog = 1
            return (Any[], true)
        end
    end
    return (_raw_allocs(f, types), false)
end

function _format_allocs(results; header = "call provably allocates")
    io = IOBuffer()
    println(io, header, " (", length(results), " site(s)):")
    for (i, a) in enumerate(results)
        print(io, "  [", i, "] ")
        # AllocCheck instances `show` with their source location and reason; reuse that.
        print(io, a)
        i < length(results) && println(io)
    end
    return String(take!(io))
end

# First source location among allocation sites (any / boxing-only), pulled from the backtraces.
function _first_loc(allocs, boxing_only::Bool)
    for a in allocs
        boxing_only && !_is_boxing(a) && continue
        bt = a.backtrace
        isempty(bt) || return (string(bt[1].file), Int(bt[1].line))
    end
    return ("", 0)
end

# ── JET ──────────────────────────────────────────────────────────────────────────────────────────

# Wraps `JET.report_opt` so a backend failure names the check target and signature instead of
# propagating raw from inside JET (see `AnalysisError`).
function _opt_reports(target::AbstractString, @nospecialize(f), @nospecialize(types::Tuple))
    try
        return JET.get_reports(JET.report_opt(f, types))
    catch err
        throw(AnalysisError(target, "(" * join(types, ", ") * ")", err))
    end
end

# ── TrimCheck ────────────────────────────────────────────────────────────────────────────────────

# TrimCheck's public API (`@validate` / `validate_function`) only accepts a call-expr or a
# single-method function eval'd in `Main` — it cannot check an arbitrary concrete `(f, types)`. So we
# drive its core directly: the same `hook_verify_typeinf_trim() do … typeinf_ext_toplevel(…,
# TRIM_SAFE) end` that `validate_function` runs, but for our exact signature. We reference
# TrimCheck's own `Compiler` binding (as `validate_function` does) so we hit the same verifier.
#
# `types` may be a `Type{<:Tuple}` (e.g. `Tuple{Int,Float64}`) or a plain tuple of types.
function _trim_validate(@nospecialize(f), @nospecialize(types))
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

# ── the proof engine ─────────────────────────────────────────────────────────────────────────────

"""
    StrictModeTest.proof_findings(f, types; guarantees = (:typestable, :noalloc)) -> Vector{StrictFinding}

One [`StrictMode.StrictFinding`](@ref) per requested guarantee, computed with the proofs rather
than StrictMode's value-free scan. `f` is never called. This is the data half of the gating API;
`test_signatures`/`test_compiled`/`test_registered` add the raise.
"""
proof_findings(@nospecialize(f), @nospecialize(types::Tuple); guarantees = (:typestable, :noalloc)) =
    _proof_findings(f, types, guarantees)

function _proof_findings(@nospecialize(f), @nospecialize(types::Tuple), guarantees)
    fn, sg, md = StrictMode._func_name(f), StrictMode._sig_string(types), StrictMode._mod_sym(f)
    target = fn * sg
    # AllocCheck runs at most once per signature even when both allocation guarantees are asked
    # for: the boxing verdict is a filter over the same instance list.
    allocs, alloc_error = if :noalloc in guarantees || :noboxing in guarantees
        try
            (first(_checked_allocs(f, types)), nothing)
        catch err
            err isa StrictViolation && rethrow()
            (nothing, sprint(showerror, err))
        end
    else
        (nothing, nothing)
    end
    out = StrictFinding[]
    for g in guarantees
        shared = StrictMode._compiled_output_finding(g, f, types, md, fn, sg)
        if !isnothing(shared)
            push!(out, shared)
        elseif g === :typestable
            push!(out, _typestable_finding(target, f, types, md, fn, sg))
        elseif g === :noalloc
            if isnothing(allocs)
                push!(out, StrictMode._unevaluated(md, fn, sg, g, "AllocCheck could not analyze this signature: $alloc_error"))
            else
                file, line = _first_loc(allocs, false)
                push!(
                    out, StrictMode._mkfinding(
                        md, fn, sg, g, !isempty(allocs),
                        "allocates ($(length(allocs)) site(s))", file, line
                    )
                )
            end
        elseif g === :noboxing
            if isnothing(allocs)
                push!(out, StrictMode._unevaluated(md, fn, sg, g, "AllocCheck could not analyze this signature: $alloc_error"))
            else
                boxing = filter(_is_boxing, allocs)
                file, line = _first_loc(allocs, true)
                push!(
                    out, StrictMode._mkfinding(
                        md, fn, sg, g, !isempty(boxing), "boxing / dynamic dispatch", file, line
                    )
                )
            end
        elseif g === :trim_compatible
            passed, fnds = _trim_validate(f, Tuple{types...})
            m = try
                which(f, types)
            catch
                nothing
            end
            push!(
                out, StrictMode._mkfinding(
                    md, fn, sg, g, !passed,
                    "trim-incompatible (juliac --trim=safe): " * join(fnds, "; "),
                    isnothing(m) ? "" : string(m.file), isnothing(m) ? 0 : Int(m.line)
                )
            )
        else
            throw(ArgumentError("unknown guarantee :$g; expected one of $(StrictMode._GUARANTEES)"))
        end
    end
    return out
end

# Two layers, both authoritative here: the inferred return type must be concrete, and JET's
# optimization analysis must be clean. StrictMode's own `:typestable` uses an IR boxing signal for
# the second layer, which is why it only warns; this is the proof that replaces it.
function _typestable_finding(target, @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg)
    rts = Base.return_types(f, Tuple{types...})
    if length(rts) != 1 || !StrictMode._is_typestable_return(only(rts))
        rt = isempty(rts) ? "none" : (length(rts) == 1 ? string(only(rts)) : string(rts))
        return StrictMode._mkfinding(md, fn, sg, :typestable, true, "return type $rt is not concrete (inference)", "", 0)
    end
    reports = _opt_reports(target, f, types)
    return StrictMode._mkfinding(
        md, fn, sg, :typestable, !isempty(reports),
        "internal instability / runtime dispatch ($(length(reports)) JET report(s))", "", 0
    )
end
