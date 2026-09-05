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

# juliac includes two patch files into the target before trim inference
# (`juliac-trim-base.jl`, `juliac-trim-stdlib.jl`). They change what the verifier sees — most
# consequentially by raising `print_to_string`'s `max_args`, without which a ≥4-argument string
# interpolation on a reachable throw path despecializes to `Vararg{Any}` and the verifier rejects
# code juliac itself builds clean. That is issue #19: an ordinary
# `throw(ArgumentError("… $m×$n"))` reds the guarantee on Julia 1.13 while `juliac --trim=safe`
# produces the `.so`. Verifying without them checks a DIFFERENT PROGRAM than juliac compiles.
#
# They are OFF by default, and the reason is not caution — it is measured. `juliac-trim-base.jl`
# contains:
#
#     @eval Base.CoreLogging begin
#         # Disable logging (TypedCallable is required to support the existing dynamic
#         # logger interface, but it's not implemented yet)
#         @inline current_logger_for_env(std_level::LogLevel, group, _module) = nothing
#     end
#
# Applying that in-process SILENCES EVERY `@warn` AND `@info` for the rest of the session — which
# is the whole of StrictMode's reporting tier. Every `@assert_noalloc` would find its violations and
# say nothing: the vacuous-green shape this package exists to remove, installed by the package
# itself. Observed directly, as two `@test_logs` assertions in this suite going empty the moment the
# patches were applied by default.
#
# TrimCheck's own `validate_function` avoids this by running `init_validation` on a Distributed
# worker. The correct fix for issue #19 is the same isolation; until then this is an opt-in for a
# session that does nothing but trim verification and does not need its logging back.
const _JULIAC_PATCHES = Ref(false)
const _JULIAC_PATCHED = Ref(false)

"""
    juliac_patches() -> Bool

Whether trim verification applies juliac's own `juliac-trim-base.jl` / `juliac-trim-stdlib.jl`
patches before running the verifier. Default `false` — applying them disables logging for the whole
session. See [`set_juliac_patches!`](@ref).
"""
juliac_patches() = _JULIAC_PATCHES[]

"""
    set_juliac_patches!(b::Bool)

Set whether trim verification applies juliac's Base/stdlib patches first.

`true` makes the verifier check the same program `juliac --trim=safe` compiles, which is the only
way to avoid issue #19's false FAILs (a ≥4-argument string interpolation on a reachable throw path
is rejected without them). The patched verification runs in a **subprocess**, so the caller's
session keeps its logging: `juliac-trim-base.jl` stubs `Base.CoreLogging.current_logger_for_env`,
which silences every `@warn` and `@info` in whatever process applies it, and that process is now a
throwaway child.

The child costs a Julia start and a package load per verification, which is why this is off by
default rather than always on. A signature whose function cannot be reached in a fresh process —
a closure, or something defined in a module the child cannot load — falls back to unpatched
in-process verification with a warning naming the reason.

`false` (the default) verifies against stock Base in this process and accepts the false-FAIL class.
"""
set_juliac_patches!(b::Bool) = (_JULIAC_PATCHES[] = b)

# Returns whether the patches are actually in effect. The subprocess path reports this back, so a
# verdict reached against STOCK Base is never presented as a patched one — the patch files are
# absent on some Julia builds (1.13.0-rc4 ships none), and a silent fallback there would relabel
# exactly the false FAILs issue #19 is about.
function _apply_juliac_patches()
    _JULIAC_PATCHES[] || return false
    _JULIAC_PATCHED[] && return true             # already applied in this process
    _JULIAC_PATCHED[] = true                     # set first: a failed attempt must not retry per call
    dir = joinpath(Sys.BINDIR, "..", "share", "julia", "juliac")
    files = ("juliac-trim-base.jl", "juliac-trim-stdlib.jl")
    try
        for f in files
            p = joinpath(dir, f)
            isfile(p) || error("$p not found")
            Base.include(Main, p)
        end
        @info "StrictModeTest: applied juliac's trim patches ($(join(files, ", "))) so the " *
            "verifier checks the same program `juliac --trim=safe` compiles. These mutate " *
            "process-global compiler state and are not reversible; set_juliac_patches!(false) " *
            "skips them at the cost of reinstating a false-FAIL class (issue #19)."
    catch err
        @warn "StrictModeTest: could not apply juliac's trim patches ($(sprint(showerror, err))). " *
            "Trim verification will run against STOCK Base, which rejects some code juliac builds " *
            "clean — a `@test_trim_compatible` failure may therefore be a false alarm."
        return false
    end
    return true
end

# TrimCheck's public API (`@validate` / `validate_function`) only accepts a call-expr or a
# single-method function eval'd in `Main` — it cannot check an arbitrary concrete `(f, types)`. So we
# drive its core directly: the same `hook_verify_typeinf_trim() do … typeinf_ext_toplevel(…,
# TRIM_SAFE) end` that `validate_function` runs, but for our exact signature. We reference
# TrimCheck's own `Compiler` binding (as `validate_function` does) so we hit the same verifier.
#
# `types` may be a `Type{<:Tuple}` (e.g. `Tuple{Int,Float64}`) or a plain tuple of types.
# `Compiler.typeinf_ext_toplevel` gained a fourth argument, `external_linkage::Bool`, in Julia
# 1.13.0-rc4. Dispatching on whether that method exists, rather than on a version number, keeps this
# working across the change in either direction — the argument arrived mid-release-candidate, so a
# `VERSION` bound would have to name an rc.
#
# `false` reproduces what the three-argument form did: it passed nothing through to
# `collectinvokes!`, whose own `external_linkage` keyword defaults to `false`.
function _typeinf_toplevel(Comp, methods::Vector{Any}, worlds::Vector{UInt})
    return if hasmethod(Comp.typeinf_ext_toplevel, Tuple{Vector{Any}, Vector{UInt}, UInt8, Bool})
        Comp.typeinf_ext_toplevel(methods, worlds, Comp.TRIM_SAFE, false)
    else
        Comp.typeinf_ext_toplevel(methods, worlds, Comp.TRIM_SAFE)
    end
end

# --- issue #19: verify against juliac's patched Base without poisoning this session --------------
# Applying `juliac-trim-base.jl` is what makes the verifier check the program juliac actually
# compiles, but it stubs `Base.CoreLogging.current_logger_for_env`, so the process that applies it
# stops emitting `@warn`/`@info` — the whole of StrictMode's reporting tier, silent. The isolation
# is the fix: run the patched verification in a child and read back only the verdict. TrimCheck's
# own `validate_function` runs `init_validation` on a Distributed worker for the same reason.
#
# `f` and the argument types travel by `Serialization`, which records a function by module and name
# — so the child resolves them only if it can load the defining module. A closure, or a fixture
# defined inside a `@testitem`, cannot survive that, which is why every failure path here falls back
# to unpatched in-process verification rather than erroring: an unavailable subprocess must degrade
# to the old answer, never to a FAIL.
const _TRIM_CHILD_STDERR = Ref("")

function _trim_subprocess_script(in_path::String, out_path::String, modname::Union{Nothing, Symbol})
    load = isnothing(modname) ? "" : """
        try
            @eval using $modname
        catch
        end
        """
    # Only `StrictModeTest` is loaded by name. `Serialization` is reached through it rather than
    # with a `using` of its own: under `Pkg.test()` the child runs in the temporary test
    # environment, where Serialization is a dependency of this package but not a direct dependency
    # of that environment — so `using Serialization` there is an ArgumentError.
    return """
    using StrictModeTest
    $load
    __f, __types = StrictModeTest.deserialize($(repr(in_path)))
    StrictModeTest.set_juliac_patches!(true)
    __patched = StrictModeTest._apply_juliac_patches()
    __passed, __findings = StrictModeTest._trim_validate_here(__f, __types)
    StrictModeTest.serialize($(repr(out_path)), (__patched, __passed, __findings))
    """
end

function _trim_validate_subprocess(@nospecialize(f), argtypes::Vector)
    # Both handles are closed before the temp files are removed. Windows refuses to unlink a file
    # that is still open (EBUSY), where Linux and macOS allow it — so dropping `mktemp`'s IO on the
    # floor is a leak that only ever fails on one platform.
    in_path, in_io = mktemp()
    out_path, out_io = mktemp()
    close(out_io)
    try
        serialize(in_io, (f, argtypes))
        close(in_io)
        m = parentmodule(f)
        modname = (m === Main || m === Base || m === Core) ? nothing : nameof(m)
        script = _trim_subprocess_script(in_path, out_path, modname)
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $script`
        # The child's stderr is kept, not discarded: when it fails, that text is the only account of
        # why, and a silent decline here reads identically to "juliac ships no patches on this
        # build" — two very different situations for whoever is reading the fallback warning.
        err = IOBuffer()
        ok = success(pipeline(ignorestatus(cmd); stdout = devnull, stderr = err))
        if !ok
            _TRIM_CHILD_STDERR[] = String(take!(err))
            return nothing
        end
        r = open(deserialize, out_path)
        r isa Tuple{Bool, Bool, Vector{String}} || return nothing
        patched, passed, findings = r
        # The child ran, but without the patches — juliac ships none on some builds (1.13.0-rc4).
        # That verdict came from stock Base, so it carries the false-FAIL class this whole path
        # exists to remove, and must not be returned as though it did not.
        patched || return nothing
        return (passed, findings)
    catch
        return nothing
    finally
        # `close` is a no-op on an already-closed stream, and matters on the path where `serialize`
        # threw before the close above. Cleanup itself is best-effort: a temp file that outlives the
        # call is untidy, not a reason to fail a verification that already has its answer.
        close(in_io)
        try
            rm(in_path; force = true)
            rm(out_path; force = true)
        catch
        end
    end
end

function _trim_validate(@nospecialize(f), @nospecialize(types))
    argtypes = (types isa Type && types <: Tuple) ? collect(types.parameters) : collect(types)
    if _JULIAC_PATCHES[]
        r = _trim_validate_subprocess(f, argtypes)
        isnothing(r) || return r
        @warn "StrictModeTest: could not run the patched trim verification in a subprocess for " *
            "`$(nameof(f))` (a closure, a function the child cannot load, or a build shipping no " *
            "juliac patches). Falling back to STOCK Base in this process, which rejects some code " *
            "juliac builds clean — a failure here may be a false alarm (issue #19)." *
            (isempty(_TRIM_CHILD_STDERR[]) ? "" : "\n  child stderr: " * first(_TRIM_CHILD_STDERR[], 500)) maxlog = 3
    end
    return _trim_validate_here(f, argtypes)
end

# The verification itself, in whatever process calls it. The child runs this with the patches
# applied; the parent runs it against stock Base.
function _trim_validate_here(@nospecialize(f), argtypes::Vector)
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
            _typeinf_toplevel(
                Comp,
                Any[Core.svec(ret_type, Tuple{typeof(f), argtypes...})],
                [Base.get_world_counter()],
            )
        end
        return (true, String[])
    catch err
        err isa TrimCheck.TrimVerificationErrors && return _trim_verdict(err)
        rethrow(err)
    end
end

"""
    _trim_verdict(err::TrimVerificationErrors) -> (passed::Bool, findings::Vector{String})

Classify what the verifier raised. `err.errors` is a `Vector{Pair{Bool, Any}}` whose `Bool` is
`warn`, and **juliac's own gate fails only on the non-warning entries** — so treating every entry as
a failure reds signatures juliac itself would build (issue #20). A raise carrying nothing but
warnings is a PASS here.

Split out from `_trim_validate` so the classification can be tested against hand-built
`TrimVerificationErrors` values — provoking a warnings-only raise from a real signature is not
something a test can arrange deterministically.
"""
function _trim_verdict(err)
    real = filter(p -> !first(p), err.errors)
    nwarn = length(err.errors) - length(real)
    if isempty(real)
        nwarn > 0 && @info "StrictModeTest: juliac's trim verifier raised $nwarn warning(s) for this " *
            "signature and no errors — juliac's own gate accepts that, so this is a PASS." maxlog = 3
        return (true, String[])
    end
    # Route the verifier output through TypeContracts' `TrimDiagnostics` — the same parser
    # `explain_trim` uses — for deduplicated, source-mapped sites (statement + user frame), instead
    # of hand-filtering the raw dump. Re-wrap so only the real errors reach the parser; otherwise a
    # warning's call site would be reported as a failing one.
    errs = try
        TrimCheck.TrimVerificationErrors(real, err.parents)
    catch
        err                                   # constructor shape changed: fall back to the whole set
    end
    raw = try
        sprint(show, errs)
    catch
        ""
    end
    tf = TypeContracts.explain_trim_failure(raw)
    if !tf.recognized || isempty(tf.sites)
        return (false, ["juliac --trim=safe rejected this signature ($(length(real)) error(s); verifier output not recognized)"])
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
    isempty(reports) || return StrictMode._mkfinding(
        md, fn, sg, :typestable, true,
        "internal instability / runtime dispatch ($(length(reports)) JET report(s))", "", 0
    )
    # F39. JET cannot see this class at all: a union-typed local that boxes a member on the way in is
    # not dynamic dispatch, so `@report_opt` is silent at every signature. Without this the proof
    # would be WEAKER than the scan it is supposed to settle — `@assert_typestable` catches it and
    # `@test_typestable` would wave it through.
    unionphi = StrictMode._alloc_signals(f, types; depth = 0).unionphi
    return StrictMode._mkfinding(
        md, fn, sg, :typestable, unionphi,
        "a union-typed local carries a member that must be boxed to flow through it " *
            "(concrete return, and invisible to JET)", "", 0
    )
end
