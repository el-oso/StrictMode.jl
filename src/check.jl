# The interference-proof core: run guarantees on a `(function, types)` pair with no macro parsing
# and no execution. Everything else (the macros via `@explain`, the registry, the agent audit, the
# Revise loop) reuses this. Every guarantee is computed from `(f, types)` alone.

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

# Build the underlying `StrictReport` from `(f, types)`, calling JET (via the backend) in its
# function form.
function _strict_report(target, @nospecialize(f), @nospecialize(types::Tuple))
    _require_backend()
    opt = try
        _be_opt_result(f, types)
    catch
        nothing
    end
    return _explain(target, f, types, opt)
end

# First source location among allocation sites (any / boxing-only), pulled from the backtraces.
function _first_loc(allocs, boxing_only::Bool)
    allocs === nothing && return ("", 0)
    for a in allocs
        boxing_only && !_be_is_boxing(a) && continue
        bt = a.backtrace
        isempty(bt) || return (string(bt[1].file), Int(bt[1].line))
    end
    return ("", 0)
end

_mkfinding(md, fn, sg, g, fail::Bool, reason, file, line) = StrictFinding(
    md, fn, sg, g, fail ? :fail : :pass, file, line, fail ? reason : "", fail ? _suggestion(g) : ""
)

# Guarantees with a single, backend-independent computation — identical in :fast and :full, so
# both `_build_finding` (:full) and `_findings_fast` (:fast) delegate here instead of each keeping
# its own copy. Returns `nothing` for any other guarantee (the caller then applies its own,
# mode-specific logic for :typestable/:noalloc/:noboxing/:trim_compatible).
function _mode_independent_finding(g::Symbol, @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg)
    if g === :owned
        s = _alloc_signals(f, types; depth = _FAST_ALLOC_DEPTH[])
        return _mkfinding(md, fn, sg, g, s.dictlookup, "runtime AbstractDict lookup on owned scratch (GKH violation)", s.file, s.line)
    elseif g === :inlined
        fail = _inlined_survives(f, types) === true
        return _mkfinding(md, fn, sg, g, fail, "not inlined (survives as :invoke)", "", 0)
    elseif g === :vectorized
        return _mkfinding(md, fn, sg, g, !_vectorized(f, types), "did not vectorize (no `<N x …>` ops in this body)", "", 0)
    elseif g === :no_scalar_loops
        return _mkfinding(md, fn, sg, g, scalar_fp_loops(f, types), "scalar hot loop did not vectorize (FP or integer) (best-effort: `phi double`/`phi iN` + scalar ops, no `<N x …>`)", "", 0)
    elseif g === :trimsafe
        return _trimsafe_finding(f, types, md, fn, sg)
    end
    return nothing
end

function _build_finding(g::Symbol, @nospecialize(f), @nospecialize(types::Tuple), rep, md, fn, sg)
    shared = _mode_independent_finding(g, f, types, md, fn, sg)
    shared === nothing || return shared
    if g === :typestable
        fail = would_fail_typestable(rep)
        return _mkfinding(md, fn, sg, g, fail, "return type $(rep.return_type) is not concrete / internal instability", "", 0)
    elseif g === :noalloc
        fail = would_fail_noalloc(rep)
        file, line = _first_loc(rep.allocs, false)
        n = rep.allocs === nothing ? "?" : string(length(rep.allocs))
        return _mkfinding(md, fn, sg, g, fail, "allocates ($n site(s))", file, line)
    elseif g === :noboxing
        fail = would_fail_noboxing(rep)
        file, line = _first_loc(rep.allocs, true)
        return _mkfinding(md, fn, sg, g, fail, "boxing / dynamic dispatch", file, line)
    elseif g === :trim_compatible
        return _trim_compatible_finding(f, types, md, fn, sg, :full)
    end
    throw(ArgumentError("unknown guarantee :$g; expected :typestable, :noalloc, :noboxing, :owned, :inlined, :vectorized, :no_scalar_loops, :trimsafe, or :trim_compatible"))
end

# `:trimsafe` finding — the static-only subset of `:trim_compatible`, kept for compatibility. Value-free
# TypeContracts scan, identical in `:fast` and `:full` (never escalates to the TrimCheck verifier). Prefer
# `:trim_compatible`.
function _trimsafe_finding(@nospecialize(f), @nospecialize(types::Tuple), md, fn, sg)
    r = _trim_report(f, types)
    m = try
        which(f, types)
    catch
        nothing
    end
    file = m === nothing ? "" : string(m.file)
    line = m === nothing ? 0 : Int(m.line)
    return _mkfinding(md, fn, sg, :trimsafe, !r.passed, "trim-unsafe: " * join(r.findings, "; "), file, line)
end

# `:trim_compatible` finding — escalating: `mode === :full` with TrimCheck loaded runs juliac's
# authoritative `verify_typeinf_trim` verifier; otherwise the TypeContracts static scan (the
# `:trimsafe` subset). `mode` is passed explicitly so `findings(...; mode=:fast|:full)` is honored
# verbatim (the divergence report relies on this).
function _trim_compatible_finding(@nospecialize(f), @nospecialize(types::Tuple), md, fn, sg, mode::Symbol)
    if mode === :full && trimcheck_available()
        passed, fnds = _be_trim_validate(f, Tuple{types...})
        msg = passed ? "trim-compatible (juliac verifier)" :
            "trim-incompatible (juliac --trim=safe): " * join(fnds, "; ")
    else
        r = _trim_report(f, types)
        passed = r.passed
        msg = passed ? "trim-compatible (static scan)" :
            "likely trim-incompatible (static scan): " * join(r.findings, "; ")
    end
    m = try
        which(f, types)
    catch
        nothing
    end
    file = m === nothing ? "" : string(m.file)
    line = m === nothing ? 0 : Int(m.line)
    return _mkfinding(md, fn, sg, :trim_compatible, !passed, msg, file, line)
end

"""
    findings(f, types; guarantees = (:typestable, :noalloc), mode = analysis_mode()) -> Vector{StrictFinding}

Analyze `f` for the concrete signature `types` and return one [`StrictFinding`](@ref) per
requested guarantee. Pure analysis — `f` is never called. `mode` overrides [`analysis_mode`](@ref)
for this call (`:fast` heuristic vs `:full` proof), so you can force a quick scan at runtime
without changing the preference (`ANALYSIS_MODE` is baked at precompile).
"""
function findings(
        @nospecialize(f), @nospecialize(types::Tuple);
        guarantees = (:typestable, :noalloc), mode::Symbol = analysis_mode(),
    )
    key = _cache_key(f, types, guarantees, mode)
    if key !== nothing
        cached = @lock _CACHE_LOCK get(_CACHE, key, nothing)
        if cached !== nothing
            @lock _CACHE_LOCK (_CACHE_HITS[] += 1)
            return copy(cached)
        end
    end
    fs = _findings_uncached(f, types, guarantees, mode)
    if key !== nothing
        @lock _CACHE_LOCK begin
            _CACHE[key] = fs
            _CACHE_MISSES[] += 1
        end
    end
    return copy(fs)
end

function _findings_uncached(@nospecialize(f), @nospecialize(types::Tuple), guarantees, mode::Symbol)
    fn, sg, md = _func_name(f), _sig_string(types), _mod_sym(f)
    if mode === :full
        # Rigorous: AllocCheck proof + JET (needs the analysis backend).
        rep = _strict_report(fn * sg, f, types)
        return StrictFinding[_build_finding(g, f, types, rep, md, fn, sg) for g in guarantees]
    end
    # :fast — value-free inference heuristic; no AllocCheck/JET backend required.
    return _findings_fast(f, types, guarantees, md, fn, sg)
end

# Enrich a boxing/alloc finding with the abstract-`eltype`-container root cause + fix, when the IR scan
# found one (e.g. `Vector{AbstractFoo}`). This is the dispatch the result-type heuristic misses when the
# dispatched method returns a concrete type — and the most actionable thing to tell the user.
function _box_msg(base::AbstractString, sig)
    sig.abscontainer === nothing && return base
    return string(
        base, "; abstract-eltype container detected (`Vector{", sig.abscontainer,
        "}`, …) — indexing/iterating it dispatches dynamically (a speed + `--trim` anti-pattern). ",
        "Use a `Tuple`, a concrete or small-`Union` eltype, or restructure so elements are concretely typed."
    )
end

# `:fast` per-guarantee findings from cheap Base-only analysis (`_alloc_signals`, `return_types`,
# `_inlined_survives`). Triage speed for the edit loop; `:full` is the proof for CI.
function _findings_fast(@nospecialize(f), @nospecialize(types::Tuple), guarantees, md, fn, sg)
    sig = (:typestable in guarantees || :noalloc in guarantees || :noboxing in guarantees) ?
        _alloc_signals(f, types) : nothing
    out = StrictFinding[]
    for g in guarantees
        shared = _mode_independent_finding(g, f, types, md, fn, sg)
        if shared !== nothing
            push!(out, shared)
        elseif g === :typestable
            rts = Base.return_types(f, Tuple{types...})
            badret = length(rts) != 1 || !_is_typestable_return(only(rts))
            # A concrete return can hide internal runtime dispatch (JET's :full finding); the IR
            # boxing signal catches that shape, so fast typestable checks both.
            fail = badret || sig.boxing
            reason = badret ? "return type is not concrete (inference)" :
                "internal dynamic dispatch (concrete return; fast IR heuristic)"
            push!(out, _mkfinding(md, fn, sg, g, fail, reason, "", 0))
        elseif g === :noalloc
            fail = sig.alloc || sig.boxing || sig.abscontainer !== nothing
            push!(out, _mkfinding(md, fn, sg, g, fail, _box_msg("allocates / boxes (fast heuristic)", sig), sig.file, sig.line))
        elseif g === :noboxing
            fail = sig.boxing || sig.abscontainer !== nothing
            push!(out, _mkfinding(md, fn, sg, g, fail, _box_msg("boxing / dynamic dispatch (fast heuristic)", sig), sig.file, sig.line))
        elseif g === :trim_compatible
            push!(out, _trim_compatible_finding(f, types, md, fn, sg, :fast))
        else
            throw(ArgumentError("unknown guarantee :$g; expected :typestable, :noalloc, :noboxing, :owned, :inlined, :vectorized, :no_scalar_loops, :trimsafe, or :trim_compatible"))
        end
    end
    return out
end

"""
    check(f, types; guarantees = (:typestable, :noalloc), fail = fail_mode()) -> Vector{StrictFinding}

Check the guarantees for `f`'s concrete signature `types` and return the findings. It's an
ordinary function call rather than a macro, so it never parses syntax and can't collide with
broadcasting, nested macros, or keyword arguments. Use it as the robust escape hatch, and as the
programmatic entry point when you're automating.

`fail = :error` (the default outside `:warn` mode) throws a [`StrictViolation`](@ref) that collects
the failures together; `:warn` logs them; `:none` just returns the findings without raising.

```julia
check(dot3, (NTuple{3,Float64}, NTuple{3,Float64}))          # ok → all :pass
check(boxy, (Tuple{Int,Float64,Float32},); guarantees=(:noboxing,))   # throws StrictViolation
```
"""
function check(
        @nospecialize(f), @nospecialize(types::Tuple);
        guarantees = (:typestable, :noalloc), fail::Symbol = fail_mode(), mode::Symbol = analysis_mode(),
    )
    fs = findings(f, types; guarantees, mode)
    failed = filter(_failed, fs)
    if !isempty(failed) && fail !== :none
        msg = sprint(io -> format_findings(io, failed; format = :text))
        fail === :error ? throw(StrictViolation(:check, _func_name(f) * _sig_string(types), msg)) : @warn msg
    end
    return fs
end
