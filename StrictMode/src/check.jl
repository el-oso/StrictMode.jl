# The interference-proof core: run guarantees on a `(function, types)` pair with no macro parsing
# and no execution. Everything else (the registry, the agent audit, the Revise loop, and
# `StrictModeTest`'s proofs) reuses this. Every guarantee is computed from `(f, types)` alone.

_sig_string(@nospecialize(types::Tuple)) = "(" * join(types, ", ") * ")"
_func_name(@nospecialize(f)) = try
    string(nameof(f))
catch
    string(f)
end
_mod_sym(@nospecialize(f)) = try
    nameof(parentmodule(f))
catch
    :Main
end

# A guarantee the analysis could not evaluate. `:fail`, never `:pass`: "I could not check this" and
# "this is fine" must not render the same, which is how a crashed AllocCheck/JET run reported
# success for every method in a sweep.
_unevaluated(md, fn, sg, g, why) = StrictFinding(md, fn, sg, g, :fail, "", 0, why, _suggestion(g))

_mkfinding(md, fn, sg, g, fail::Bool, reason, file, line) = StrictFinding(
    md, fn, sg, g, fail ? :fail : :pass, file, line, fail ? reason : "", fail ? _suggestion(g) : ""
)

const _GUARANTEES = (
    :typestable, :noalloc, :noboxing, :owned, :inlined, :vectorized,
    :no_scalar_loops, :no_spill, :trimsafe, :trim_compatible, :trusted,
)

# Guarantees computed from compiled output rather than from an allocation/inference engine — the
# same answer whichever tier asks, so `StrictModeTest` delegates here for these instead of keeping
# a second copy. Returns `nothing` for a guarantee this does not cover.
function _compiled_output_finding(g::Symbol, @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg)
    if g === :owned
        s = _alloc_signals(f, types; depth = _FAST_ALLOC_DEPTH[])
        return _mkfinding(md, fn, sg, g, s.dictlookup, "runtime AbstractDict lookup on owned scratch (static-ownership violation)", s.file, s.line)
    elseif g === :inlined
        fail = _inlined_survives(f, types) === true
        return _mkfinding(md, fn, sg, g, fail, "not inlined (survives as :invoke)", "", 0)
    elseif g === :vectorized
        return _mkfinding(md, fn, sg, g, !_vectorized(f, types), "did not vectorize (no `<N x …>` ops in this body)", "", 0)
    elseif g === :no_scalar_loops
        return _mkfinding(md, fn, sg, g, scalar_fp_loops(f, types), "scalar hot loop did not vectorize (FP or integer) (best-effort: `phi double`/`phi iN` + scalar ops, no `<N x …>`)", "", 0)
    elseif g === :no_spill
        r = spill_report(f, types)
        return _mkfinding(md, fn, sg, g, r.vec_spills > 0, "vector register(s) spilled to the stack ($(r.vec_spills) spill/reload line(s))", "", 0)
    elseif g === :trimsafe
        return _trimsafe_finding(f, types, md, fn, sg)
    elseif g === :trusted
        # No proving counterpart: the scan reads a call on a type inference has already fixed, so
        # there is nothing a backend could add. Both tiers therefore answer from here.
        return _trusted_finding(f, types, md, fn, sg)
    end
    return nothing
end

# `:trimsafe` finding — the static-only subset of `:trim_compatible`, kept for compatibility.
# Value-free TypeContracts scan; never runs juliac's verifier. Prefer `:trim_compatible`.
function _trimsafe_finding(@nospecialize(f), @nospecialize(types::Tuple), md, fn, sg)
    r = _trim_report(f, types)
    m = try
        which(f, types)
    catch
        nothing
    end
    file = isnothing(m) ? "" : string(m.file)
    line = isnothing(m) ? 0 : Int(m.line)
    return _mkfinding(md, fn, sg, :trimsafe, !r.passed, "trim-unsafe: " * join(r.findings, "; "), file, line)
end

"""
    findings(f, types; guarantees = (:typestable, :noalloc)) -> Vector{StrictFinding}

Analyze `f` for the concrete signature `types` and return one [`StrictFinding`](@ref) per
requested guarantee. Pure analysis — `f` is never called, and this never throws on a violation: it
is the data half of the API, and the caller decides what a finding is worth.

The engine is value-free: inferred return types plus a scan of typed IR. Its allocation verdicts
are structural guesses (typed IR still carries an allocation LLVM will later elide), so **nothing
in StrictMode gates on them**. `StrictModeTest`'s `test_signatures`/`test_compiled` re-run the same
signatures against AllocCheck and JET, and those do gate.
"""
function findings(
        @nospecialize(f), @nospecialize(types::Tuple);
        guarantees = (:typestable, :noalloc),
    )
    key = _cache_key(f, types, guarantees)
    if !isnothing(key)
        cached = @lock _CACHE_LOCK get(_CACHE, key, nothing)
        if !isnothing(cached)
            @lock _CACHE_LOCK (_CACHE_HITS[] += 1)
            return copy(cached)
        end
    end
    fs = _findings_uncached(f, types, guarantees)
    if !isnothing(key)
        @lock _CACHE_LOCK begin
            _CACHE[key] = fs
            _CACHE_MISSES[] += 1
        end
    end
    return copy(fs)
end

function _findings_uncached(@nospecialize(f), @nospecialize(types::Tuple), guarantees)
    return _findings_fast(f, types, guarantees, _mod_sym(f), _func_name(f), _sig_string(types))
end

# Enrich a boxing/alloc finding with the abstract-`eltype`-container root cause + fix, when the IR scan
# found one (e.g. `Vector{AbstractFoo}`). This is the dispatch the result-type heuristic misses when the
# dispatched method returns a concrete type — and the most actionable thing to tell the user.
function _box_msg(base::AbstractString, sig)
    isnothing(sig.abscontainer) && return base
    return string(
        base, "; abstract-eltype container detected (`Vector{", sig.abscontainer,
        "}`, …) — indexing/iterating it dispatches dynamically (a speed + `--trim` anti-pattern). ",
        "Use a `Tuple`, a concrete or small-`Union` eltype, or restructure so elements are concretely typed."
    )
end

# Per-guarantee findings from cheap Base-only analysis (`_alloc_signals`, `return_types`,
# `_inlined_survives`).
function _findings_fast(@nospecialize(f), @nospecialize(types::Tuple), guarantees, md, fn, sg)
    sig = (:typestable in guarantees || :noalloc in guarantees || :noboxing in guarantees) ?
        _alloc_signals(f, types) : nothing
    # typestable asks a DIFFERENT question than noalloc/noboxing: is THIS function's OWN IR dispatch-
    # free? A resolved `:invoke` to a callee that boxes internally (e.g. the complex `_l3ws` IdDict
    # `get!`, whose abstract result is narrowed by a `::L3Workspace{T}` assert) is not the caller's
    # instability — only a direct dynamic `:call` is. So typestable uses depth-0 (this-level) boxing;
    # noalloc/noboxing keep the full-depth signal (a callee's runtime alloc/dispatch IS a real cost).
    # Matches JET's optimization analysis (it flags dynamic dispatch, not resolved invokes).
    local_sig = (:typestable in guarantees) ? _alloc_signals(f, types; depth = 0) : nothing
    local_boxing = isnothing(local_sig) ? false : local_sig.boxing
    # F39: a union-typed local with a member that must be boxed to flow through it. Signature-
    # independent, because the union comes from branch structure rather than from the argument types.
    local_unionphi = isnothing(local_sig) ? false : local_sig.unionphi
    out = StrictFinding[]
    for g in guarantees
        shared = _compiled_output_finding(g, f, types, md, fn, sg)
        if !isnothing(shared)
            push!(out, shared)
        elseif g === :typestable
            rts = Base.return_types(f, Tuple{types...})
            badret = length(rts) != 1 || !_is_typestable_return(only(rts))
            # A concrete return can hide internal runtime dispatch; the IR boxing signal catches
            # that shape, so this checks both.
            fail = badret || local_boxing || local_unionphi
            reason = badret ? "return type is not concrete (inference)" :
                local_boxing ? "internal dynamic dispatch (concrete return; IR heuristic)" :
                "a union-typed local carries a member that must be boxed to flow through it " *
                "(concrete return; IR heuristic)"
            push!(out, _mkfinding(md, fn, sg, g, fail, reason, "", 0))
        elseif g === :noalloc
            fail = sig.alloc || sig.boxing || !isnothing(sig.abscontainer)
            push!(out, _mkfinding(md, fn, sg, g, fail, _box_msg("allocates / boxes (value-free IR scan)", sig), sig.file, sig.line))
        elseif g === :noboxing
            fail = sig.boxing || !isnothing(sig.abscontainer)
            push!(out, _mkfinding(md, fn, sg, g, fail, _box_msg("boxing / dynamic dispatch (value-free IR scan)", sig), sig.file, sig.line))
        elseif g === :trim_compatible
            r = _trim_report(f, types)
            m = try
                which(f, types)
            catch
                nothing
            end
            msg = r.passed ? "trim-compatible (static scan)" :
                "likely trim-incompatible (static scan): " * join(r.findings, "; ")
            push!(
                out, _mkfinding(
                    md, fn, sg, g, !r.passed, msg,
                    isnothing(m) ? "" : string(m.file), isnothing(m) ? 0 : Int(m.line)
                )
            )
        else
            throw(ArgumentError("unknown guarantee :$g; expected one of $(_GUARANTEES)"))
        end
    end
    return out
end
