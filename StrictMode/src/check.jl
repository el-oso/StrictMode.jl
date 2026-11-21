# The interference-proof core: run guarantees on a `(function, types)` pair with no macro parsing
# and no execution. Everything else (the registry, the agent audit, the Revise loop, and
# `StrictModeTest`'s proofs) reuses this. Every guarantee is computed from `(f, types)` alone.

# Printing a type searches the loaded modules for an alias that names it, and one signature is
# printed for its exemption lookup, for its findings and for its trim report, so the text is kept
# for the world it was printed in (a definition can add an alias).
const _SIG_STRING_MEMO = IdDict{Any, Tuple{UInt, String}}()

function _sig_string(@nospecialize(types::Tuple))
    key = try
        Tuple{types...}
    catch
        return "(" * join(types, ", ") * ")"
    end
    world = Base.get_world_counter()
    hit = @lock _SIGNAL_MEMO_LOCK get(_SIG_STRING_MEMO, key, nothing)
    (!isnothing(hit) && hit[1] == world) && return hit[2]
    s = "(" * join(types, ", ") * ")"
    @lock _SIGNAL_MEMO_LOCK (_SIG_STRING_MEMO[key] = (world, s))
    return s
end
# A callable object is named by its type, with the type's parameters and without its module
# (`Boxed{Int64}`): one method serves every `Boxed{T}`, and each instantiation is its own row, so
# the name keeps their `key`s apart. Printing the value would show its fields. `only` and `exempt`
# match it by `nameof` alone (`Boxed`). The keyword body of a constructor or a callable object, which
# Julia names `_`, is named after the callable it belongs to (`_kwbody_owner`).
_func_name(@nospecialize(f)) = try
    if f isa Function && _demangle(nameof(f)) === :_
        owner = _kwbody_owner(typeof(f))
        isnothing(owner) || return _func_name(something(owner))
    end
    f isa Function || f isa Type ? string(nameof(f)) : _type_label(_ftype(f))
catch
    string(f)
end
_type_label(@nospecialize(T)) = sprint(show, T; context = :module => parentmodule(T))
_mod_sym(@nospecialize(f)) = try
    nameof(parentmodule(f isa Function || f isa Type || f isa Module ? f : _ftype(f)))
catch
    :Main
end
# The module that wrote the method `f` reaches for `types`. A finding is named after it: a method a
# package defines on `Base.getproperty` is the package's code, not Base's.
_mod_sym(@nospecialize(f), @nospecialize(types)) = try
    nameof(_which(f, Tuple(types)).module)
catch
    _mod_sym(f)
end

# A guarantee the analysis could not evaluate. `:fail`, never `:pass`: "I could not check this" and
# "this is fine" must not render the same, which is how a crashed AllocCheck/JET run reported
# success for every method in a sweep.
# `file`/`line` are worth passing wherever the caller knows the method: a finding a reader cannot
# navigate to is reported at `:0`, and for a sweep over a whole package that is the difference
# between a list they can act on and a list they have to grep.
_unevaluated(md, fn, sg, g, why; tier::Symbol = :report, file = "", line = 0) =
    StrictFinding(md, fn, sg, g, :fail, file, line, why, _suggestion(g), tier, :SM0203)

# A signature whose inferred return is `Union{}` returns on no path: every one throws (or never
# ends). Each guarantee then passes on nothing, because nothing is left to check once the paths
# that only throw are set aside: no value is returned to be unstable, and no statement runs on a
# returning path to allocate or dispatch. That is what a deliberate error helper looks like, and
# also a kernel called with a wrong argument type or without a required keyword argument, so a
# pass is replaced by a finding that says which of the two the reader has to decide.
#
# It is `:info` as the scan and the proofs produce it, which is what a sweep reports: a module's
# error helpers are not defects (#36). A caller that named the signature asked about a path that
# returns, and turns it into a failure with `_gate_always_throws`.
function _always_throws(@nospecialize(f), @nospecialize(types::Tuple))
    rts = _return_types_memo(f, types)
    return !isempty(rts) && all(T -> T === Union{}, rts)
end

const _ALWAYS_THROWS_WHY = "always throws or never returns: the inferred return type is `Union{}`, " *
    "so nothing on a returning path was checked"
const _ALWAYS_THROWS_FIX = "nothing is wrong if this is an error helper, or a loop that is meant to " *
    "run until its task ends. Otherwise a call in its body matches no method for these argument " *
    "types, or the signature leaves out a required keyword argument; run the call to see which"

_always_throws_finding(x::StrictFinding, status::Symbol) = StrictFinding(
    x.mod, x.func, x.signature, x.guarantee, status, x.file, x.line,
    _ALWAYS_THROWS_WHY, _ALWAYS_THROWS_FIX, x.tier, :SM0208, x.policy, x.exempt_by
)

# The findings of a signature that always throws: each pass becomes the `:info` note. A failure
# stays, since it reports something the analysis did read (a throw path, with `ignore_throw` off).
_mark_always_throws(fs::Vector{StrictFinding}) =
    StrictFinding[x.status === :pass ? _always_throws_finding(x, :info) : x for x in fs]

# For a caller that named the signature: the note is a failure.
_gate_always_throws(fs::Vector{StrictFinding}) = StrictFinding[
    (x.code === :SM0208 && x.status === :info) ? _always_throws_finding(x, :fail) : x for x in fs
]

# The method's source location for a signature, or `("", 0)` when it cannot be resolved.
function _method_loc(@nospecialize(f), @nospecialize(types::Tuple))
    m = try
        _which(f, types)
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

const _NO_BODY_WHY = "no typed body could be read for this signature (no method matches, or its generator raised)"

# The guarantees `_compiled_output_finding` answers.
const _SHARED_GUARANTEES = (
    :owned, :inlined, :vectorized, :no_scalar_loops, :no_spill, :trusted, :noescape,
    :concurrency_safe, :no_threadid_state,
)

# The guarantees read from ONE typed body by the value-free scan. A signature that is not concrete
# can match several methods, and the scan reads one of them, so a verdict there says nothing about
# the others. Such a signature is unevaluated for these, as it is for the guarantees read from
# compiled output. `:typestable` is not among them: its return type is inferred over every matching
# method.
const _ONE_BODY_GUARANTEES = (:noalloc, :noboxing, :owned)

# Guarantees computed from compiled output rather than from an allocation/inference engine — the
# same answer whichever tier asks, so `StrictModeTest` delegates here for these instead of keeping
# a second copy. Returns `nothing` for a guarantee this does not cover.
#
# A signature with no typed body is unevaluated here for every guarantee: with no method to read,
# the scans find nothing and the compiler's effects start from "every effect holds".
function _compiled_output_finding(
        g::Symbol, @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg;
        tier::Symbol = :report
    )
    g in _SHARED_GUARANTEES || return nothing
    isnothing(_typed_body(_sigtype(f, types))) && return _unevaluated(md, fn, sg, g, _NO_BODY_WHY; tier)
    if g === :owned
        _has_compiled_body(f, types) || return _unevaluated(md, fn, sg, g, _output_unread(f, types); tier)
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
        survives = _inlined_survives(f, types)
        isnothing(survives) && return _unevaluated(md, fn, sg, g, _INLINED_UNREAD; tier)
        return _mkfinding(md, fn, sg, g, survives, "not inlined (survives as :invoke)", "", 0; tier)
    elseif g === :vectorized
        ir = _llvm_ir(f, types)
        isempty(ir) && return _unevaluated(md, fn, sg, g, _output_unread(f, types); tier)
        return _mkfinding(md, fn, sg, g, !_ir_vectorized(ir), "did not vectorize (no `<N x …>` ops in this body other than loads and in-order reductions)", "", 0; tier)
    elseif g === :no_scalar_loops
        ir = _llvm_ir(f, types)
        isempty(ir) && return _unevaluated(md, fn, sg, g, _output_unread(f, types); tier)
        return _mkfinding(md, fn, sg, g, _scalar_fp_loops(ir), "scalar hot loop did not vectorize (FP or integer) (best-effort: `phi double`/`phi iN` + scalar ops, no `<N x …>`)", "", 0; tier)
    elseif g === :no_spill
        # Spills inside a loop, the same scope `@assert_no_spill` gates on by default.
        why = _spill_arch_unread()
        isnothing(why) || return _unevaluated(md, fn, sg, g, why; tier)
        asm = _native_asm(f, types)
        isempty(asm) && return _unevaluated(md, fn, sg, g, _output_unread(f, types); tier)
        r = _spill_report(fn * sg, asm)
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
    # A caller that names the function hands over a constant, and the compiler propagates a constant
    # function through everything below, `@nospecialize` or not: the whole scan inferred again for
    # every such caller (99 ms per call site, against 5 ms).
    f = Base.inferencebarrier(f)
    # The key cannot see a change to `exempt_strict()`; this clears the cache when one happened.
    _sync_exemptions!()
    key = _cache_key(f, types, guarantees)
    if !isnothing(key)
        cached = @lock _CACHE_LOCK get(_CACHE, key, nothing)
        if !isnothing(cached)
            fs, watched, world, loaded = cached
            # The key cannot see an edit to a CALLEE; the compiled code the verdict was read from
            # can. A hit whose instances have been invalidated is dropped rather than handed back.
            if _entry_valid(watched, world, loaded)
                @lock _CACHE_LOCK (_CACHE_HITS[] += 1)
                return copy(fs)
            end
            @lock _CACHE_LOCK delete!(_CACHE, key)
        end
    end
    world = Base.get_world_counter()
    loaded = _loaded_count()
    tasks = _TASK_BODY_READS[]
    fs = _findings_uncached(f, types, guarantees)
    if !isnothing(key)
        # A verdict that read a task body has nothing to watch for an edit there (`_TASK_BODY_READS`).
        watched = _TASK_BODY_READS[] == tasks ? _watch_instances(f, types) : Core.CodeInstance[]
        @lock _CACHE_LOCK begin
            _CACHE[key] = (fs, watched, world, loaded)
            _CACHE_MISSES[] += 1
        end
    end
    return copy(fs)
end

"""
    findings(sig::Type{<:Tuple}; guarantees = (:typestable, :noalloc)) -> Vector{StrictFinding}

The same analysis for a signature type `Tuple{F, types...}`, where `F` is the type of the callable.
This form needs no instance of `F`, so it reaches a callable object's method — `(r::Reader)(x)` — from
its type alone: `findings(Tuple{Reader, Int})` reads what `findings(Reader(1), (Int,))` reads. A
callable object is named by its type in the findings, with the type's parameters and without its
module: `Boxed{Int64}`.
"""
function findings(@nospecialize(sig::Type{<:Tuple}); guarantees = (:typestable, :noalloc))
    (sig isa DataType && !isempty(sig.parameters)) || throw(
        ArgumentError("findings: `$sig` is not a signature `Tuple{F, argtypes...}` without free type parameters")
    )
    return findings(_callee(sig.parameters[1]), Tuple(sig.parameters[2:end]); guarantees)
end

function _findings_uncached(@nospecialize(f), @nospecialize(types::Tuple), guarantees)
    n = _window_open()
    try
        return _findings_fast(f, types, guarantees, _mod_sym(f, types), _func_name(f), _sig_string(types))
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
    # render as a pass. The body is memoized, and every guarantee below reads it.
    isnothing(_typed_body(_sigtype(f, types))) &&
        return StrictFinding[_unevaluated(md, fn, sg, g, _NO_BODY_WHY) for g in guarantees]
    concrete = _has_compiled_body(f, types)
    # `:noalloc` is decided by the first allocation or boxing, so its scan stops there; `:noboxing`
    # reads dispatch alone, to the end of the call graph.
    sig = concrete && :noalloc in guarantees ? _alloc_signals(f, types; mode = :alloc) : nothing
    boxsig = concrete && :noboxing in guarantees ? _alloc_signals(f, types; mode = :boxing) : nothing
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
        elseif !concrete && g in _ONE_BODY_GUARANTEES
            push!(out, _unevaluated(md, fn, sg, g, _output_unread(f, types)))
        elseif g === :typestable
            rts = _return_types_memo(f, types)
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
                _which(f, types)
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
    return _always_throws(f, types) ? _mark_always_throws(out) : out
end
