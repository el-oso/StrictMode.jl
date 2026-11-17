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
# `file`/`line` are worth passing wherever the caller knows the method: a finding a reader cannot
# navigate to is reported at `:0`, and for a sweep over a whole package that is the difference
# between a list they can act on and a list they have to grep.
_unevaluated(md, fn, sg, g, why; tier::Symbol = :report, file = "", line = 0) =
    StrictFinding(md, fn, sg, g, :fail, file, line, why, _suggestion(g), tier, :SM0203)

# The method's source location for a signature, or `("", 0)` when it cannot be resolved.
function _method_loc(@nospecialize(f), @nospecialize(types::Tuple))
    m = try
        which(f, types)
    catch
        nothing
    end
    return m isa Method ? (string(m.file), Int(m.line)) : ("", 0)
end

_mkfinding(
    md, fn, sg, g, fail::Bool, reason, file, line, suggestion = "";
    tier::Symbol = :report, cause::Union{Nothing, Symbol} = nothing
) = StrictFinding(
    md, fn, sg, g, fail ? :fail : :pass, file, line, fail ? reason : "",
    fail ? (isempty(suggestion) ? _suggestion(g) : suggestion) : "", tier, _code(g, cause)
)

# A clean verdict from a scan that left part of the call tree unread. `:fail`, like any analysis
# that could not be evaluated, so "could not read it all" and "is fine" never render alike.
_truncated_finding(md, fn, sg, g, sig; tier::Symbol = :report) = StrictFinding(
    md, fn, sg, g, :fail, sig.file, sig.line,
    "not established: the value-free scan found nothing, but did not read the whole call tree " *
        "below this call (a body it could not read, or more than $(_SCAN_BODY_BUDGET[]) bodies)",
    "check a smaller part of the call, or prove it with StrictModeTest (`@test_noalloc`)", tier,
    _code(:truncated, nothing)
)

# The call waits for another task: Base's `wait`/`yield`/lock code is reached, which can allocate and
# which AllocCheck counts. Named for what it is, with the two ways to take it out of the verdict.
_scheduler_reason(so) = "blocks in the task scheduler: reaches `" * so.call * "` [" * so.statement * "]" *
    (isempty(so.via) ? "" : ", through " * so.via) * ". It waits for another task, so it can allocate."
const _SCHEDULER_SUGGESTION = "if the wait is a pool join that is expected, register the function that joins with " *
    "`register_alloc_barrier!` or exempt it with `@strict_exempt` by name"

function _scheduler_finding(md, fn, sg, g, sig, so; tier::Symbol = :report)
    return StrictFinding(
        md, fn, sg, g, :fail, sig.file, sig.line, _scheduler_reason(so),
        _SCHEDULER_SUGGESTION, tier, _code(g, :scheduler)
    )
end

# What a load-time or call-site `:noalloc` warning says. The same classification `findings` applies: a
# call whose every origin is in the task scheduler is named as that; anything else is an allocation. Both
# carry their code, and an allocation names the nearest place the scan found one.
function _alloc_message(@nospecialize(f), @nospecialize(types::Tuple), sig, base::AbstractString)
    if isnothing(sig.abscontainer)
        so = _scheduler_origin(f, types)
        isnothing(so) ||
            return string(_code(:noalloc, :scheduler), " ", _scheduler_reason(so), " ", uppercasefirst(_SCHEDULER_SUGGESTION))
    end
    return string(_code(:noalloc), " ", _box_msg(base, sig), _origin_note(f, types))
end

const _GUARANTEES = (
    :typestable, :noalloc, :noboxing, :owned, :inlined, :vectorized,
    :no_scalar_loops, :no_spill, :trim_compatible, :trusted, :noescape,
    :no_threadid_state, :concurrency_safe,
)

# A caller whose only cause for `g` lies inside a registered allocation barrier. The barrier excuses
# allocation alone, so that cause is judged at the barrier, once; the caller is pointed there rather
# than failed again, or passed as if it had been checked.
_barrier_note(md, fn, sg, g::Symbol, barrier::Symbol, file, line; tier::Symbol = :report) =
    StrictFinding(
    md, fn, sg, g, :info, file, line,
    "reaches `$barrier`, a registered allocation barrier; its " *
        (g === :owned ? "dictionary lookup" : "boxing") * " is reported there, under :$g",
    "", tier, _code(g, nothing)
)

# Guarantees computed from compiled output rather than from an allocation/inference engine — the
# same answer whichever tier asks, so `StrictModeTest` delegates here for these instead of keeping
# a second copy. Returns `nothing` for a guarantee this does not cover.
function _compiled_output_finding(
        g::Symbol, @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg;
        tier::Symbol = :report
    )
    if g === :owned
        s = _alloc_signals(f, types; depth = _FAST_ALLOC_DEPTH[])
        s.dictlookup || isnothing(s.barrier_dict) ||
            return _barrier_note(md, fn, sg, g, s.barrier_dict, s.file, s.line; tier)
        # The ordinary walk stopped short: follow the package's own code to the end. A gate does not
        # pass on what it did not read, so only a walk that ran out of bodies is "not established".
        deep = (!s.dictlookup && s.truncated) ? _owned_deep(_sigtype(f, types)) : :clean
        deep === :budget && return StrictFinding(
            md, fn, sg, g, tier === :proof ? :fail : :info, s.file, s.line,
            "not established: the package's own call graph below this call is larger than the walk " *
                "reads ($(_OWNED_DEEP_BUDGET) bodies), or holds a body it cannot read",
            "assert :owned on a smaller part of the call", tier, _code(g, nothing)
        )
        return _mkfinding(md, fn, sg, g, s.dictlookup || deep === :lookup, "runtime AbstractDict lookup on owned scratch (static-ownership violation)", s.file, s.line; tier)
    elseif g === :inlined
        fail = _inlined_survives(f, types) === true
        return _mkfinding(md, fn, sg, g, fail, "not inlined (survives as :invoke)", "", 0; tier)
    elseif g === :vectorized
        return _mkfinding(md, fn, sg, g, !_vectorized(f, types), "did not vectorize (no `<N x …>` ops in this body)", "", 0; tier)
    elseif g === :no_scalar_loops
        return _mkfinding(md, fn, sg, g, scalar_fp_loops(f, types), "scalar hot loop did not vectorize (FP or integer) (best-effort: `phi double`/`phi iN` + scalar ops, no `<N x …>`)", "", 0; tier)
    elseif g === :no_spill
        # Spills inside a loop, the same scope `@assert_no_spill` gates on by default.
        r = spill_report(f, types)
        return _mkfinding(md, fn, sg, g, r.loop_spills > 0, "vector register(s) spilled to the stack inside a loop ($(r.loop_spills) spill/reload line(s))", "", 0; tier)
    elseif g === :trusted
        # No proving counterpart: the scan reads a call on a type inference has already fixed, so
        # there is nothing a backend could add. Both tiers therefore answer from here.
        return _trusted_finding(f, types, md, fn, sg; tier)
    elseif g === :noescape
        # The compiler's own escape analysis answers this, so no backend has anything to add.
        return _noescape_finding(f, types, md, fn, sg; tier)
    elseif g === :concurrency_safe
        # Also no proving counterpart — no backend answers whether an argument is written.
        return _concurrency_safe_finding(f, types, md, fn, sg; tier)
    elseif g === :no_threadid_state
        # Also no proving counterpart — AllocCheck, JET and TrimCheck say nothing about a
        # threadid-indexed store — so both tiers answer from here and cannot drift apart.
        return _threadid_state_finding(f, types, md, fn, sg; tier)
    end
    return nothing
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
            fs, watched = cached
            # The key cannot see an edit to a CALLEE; the compiled code the verdict was read from
            # can. A hit whose instances have been invalidated is dropped rather than handed back.
            if _instances_valid(watched)
                @lock _CACHE_LOCK (_CACHE_HITS[] += 1)
                return copy(fs)
            end
            @lock _CACHE_LOCK delete!(_CACHE, key)
        end
    end
    fs = _findings_uncached(f, types, guarantees)
    if !isnothing(key)
        @lock _CACHE_LOCK begin
            _CACHE[key] = (fs, _watch_instances(f, types))
            _CACHE_MISSES[] += 1
        end
    end
    return copy(fs)
end

function _findings_uncached(@nospecialize(f), @nospecialize(types::Tuple), guarantees)
    n = _window_open()
    try
        return _findings_fast(f, types, guarantees, _mod_sym(f), _func_name(f), _sig_string(types))
    finally
        _window_close(n)
    end
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
    # A verdict read from no body is not a verdict, for any guarantee: "could not check" must not
    # render as a pass. The scan is memoized, so asking it here costs nothing the guarantees below
    # would not pay anyway.
    if _alloc_signals(f, types; depth = 0).unread
        why = "no typed body could be read for this signature (no method matches, or its generator raised)"
        return StrictFinding[_unevaluated(md, fn, sg, g, why) for g in guarantees]
    end
    # `:noalloc` is decided by the first allocation or boxing, so its scan stops there; `:noboxing`
    # reads dispatch alone, to the end of the call graph.
    sig = :noalloc in guarantees ? _alloc_signals(f, types; mode = :alloc) : nothing
    boxsig = :noboxing in guarantees ? _alloc_signals(f, types; mode = :boxing) : nothing
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
            rts = _return_types(f, Tuple(types))
            badret = length(rts) != 1 || !_is_typestable_return(only(rts))
            # A concrete return can hide internal runtime dispatch; the IR boxing signal catches
            # that shape, so this checks both.
            fail = badret || local_boxing || local_unionphi
            base = badret ? "return type is not concrete (inference)" :
                local_boxing ? "internal dynamic dispatch (concrete return; IR heuristic)" :
                "a union-typed local carries a member that must be boxed to flow through it " *
                "(concrete return; IR heuristic)"
            # Name the declaration behind the instability when one is recognizable, so the finding
            # says what to edit rather than only that the body is unstable.
            cause = fail ? _instability_cause(f, types) : nothing
            reason = isnothing(cause) ? base : base * " — " * _cause_reason(cause...)
            push!(
                out, _mkfinding(
                    md, fn, sg, g, fail, reason, "", 0,
                    isnothing(cause) ? "" : _cause_suggestion(cause[1]);
                    cause = isnothing(cause) ? nothing : cause[1]
                )
            )
        elseif g === :noalloc
            fail = sig.alloc || sig.boxing || !isnothing(sig.abscontainer)
            so = fail && isnothing(sig.abscontainer) ? _scheduler_origin(f, types) : nothing
            if !fail && sig.truncated
                push!(out, _truncated_finding(md, fn, sg, g, sig))
            elseif !fail && isnothing(sig.exempt) && !isnothing(sig.barrier_box)
                push!(out, _barrier_note(md, fn, sg, g, sig.barrier_box, sig.file, sig.line))
            elseif !fail && !isnothing(sig.exempt)
                # Its only allocation is in a callee exempted from `:noalloc`: a note, so the
                # excusal stays visible without being reported again at every caller.
                push!(
                    out, StrictFinding(
                        md, fn, sg, g, :info, sig.file, sig.line,
                        "reaches `$(sig.exempt)`, exempt from :noalloc; its allocation is excused there",
                        "", :report, _code(g, nothing)
                    )
                )
            elseif !isnothing(so)
                push!(out, _scheduler_finding(md, fn, sg, g, sig, so))
            else
                push!(out, _mkfinding(md, fn, sg, g, fail, _box_msg("allocates / boxes (value-free IR scan)", sig), sig.file, sig.line))
            end
        elseif g === :noboxing
            fail = boxsig.boxing || !isnothing(boxsig.abscontainer)
            if !fail && boxsig.truncated
                push!(out, _truncated_finding(md, fn, sg, g, boxsig))
                continue
            end
            if !fail && !isnothing(boxsig.barrier_box)
                push!(out, _barrier_note(md, fn, sg, g, boxsig.barrier_box, boxsig.file, boxsig.line))
                continue
            end
            push!(out, _mkfinding(md, fn, sg, g, fail, _box_msg("boxing / dynamic dispatch (value-free IR scan)", boxsig), boxsig.file, boxsig.line))
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
