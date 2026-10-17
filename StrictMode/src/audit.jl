# Agentic feedback: a one-shot, structured counterpart to the Revise loop. An AI coding agent (or a
# human at a prompt) runs `audit`, reads the machine-readable findings, and drives an
# edit→check→fix loop. It reports; it never throws, and it never sets an exit status. Its verdicts
# come from the value-free engine, whose allocation findings are structural guesses — a tool that
# reports is allowed to be wrong, a tool that gates is not. `StrictModeTest`'s `test_*` drivers gate.

# An advisory pass that errored on one signature, recorded rather than dropped.
_advisory_error(@nospecialize(f), @nospecialize(types), err) = StrictFinding(
    _mod_sym(f), _func_name(f), _sig_string(Tuple(types)), :advisory, :info, "", 0,
    "suggestions could not be computed for this signature: " * sprint(showerror, err),
    "This is an advisory pass, not a guarantee — the signature is otherwise unaffected."
)

"""
    audit(target = :registered; guarantees = nothing, sweep = false, require = nothing,
          only = nothing, exempt = ()) -> Vector{StrictFinding}

Run the strict checks once and return the findings, the same `Vector{StrictFinding}`
[`findings`](@ref) gives for a single signature. [`nfailures`](@ref) counts the failures, and
displaying the result prints the failures with their locations and suggested fixes. That is the
discovery entry point for an agent or a dev loop:

```julia
fs = audit(MyPkg; sweep = true)        # the findings, as data
filter(StrictMode._failed, fs)         # narrow before reading anything
```

It returns the value and prints nothing. To render, pass it to [`format_findings`](@ref) — one
rendering step, chosen by whoever consumes it:

```bash
julia --project -e 'using MyPkg, StrictMode; print(format_findings(audit(MyPkg); format = :json))'
```

A module sweep can run to hundreds of findings, whose `:json` rendering is well over 100 kB. A
session that formats on every call sends that through a log or a tool-result channel which then
truncates it, so the rendering is the caller's decision and not a default.

**This is a discovery tool, not a gate.** Its verdicts come from a value-free engine whose
allocation findings are structural guesses, so it reports and never sets an exit status; a human or
an agent reads the output and judges. To gate a build, add `StrictModeTest` to the test environment
and use its `test_*` drivers, which run the proofs.

`target`:
- `:registered` — the mark-once registry, the "check what I promised" scope.
- a `Module` — by default, the registered functions declared in that module. Pass `sweep = true` to
  also sweep everything the module has actually compiled. That's
  noisier, so scope it with `only` / `exempt`.

[`format_findings`](@ref) renders a result as `:json`, `:jsonlines`, `:github`, or `:text`. Each
JSON finding carries `guarantee`, `status`, `tier`, `file`, `line`, `reason`, and an actionable
`suggestion`.

`require` (Module target only) adds the **coverage gate**: a failing finding
(`guarantee = :coverage`) for anything that is neither declared
([`register_strict!`](@ref) / [`@strict_function`](@ref)) nor exempted (`@strict_exempt` / the
`exempt` kwarg). It makes "every kernel declares its guarantees" a red test instead of a
convention — a new function cannot ship silently unchecked, and opting out is visible in the
source.

- `:public` — one finding per undeclared exported/`public` **function**.
- `:all` — one finding per undeclared **method** `mod` defines, including methods on foreign
  functions (`Base.size`, `Base.getindex`), which are often a package's hottest code and which no
  walk over the module's names can see. Keyword wrappers, closures and default constructors are
  not counted, and one `:info` finding reports how many were left out, so the gate never
  quietly narrows its own scope. See [`StrictMode.module_methods`](@ref).

Coverage is asked per SIGNATURE: a method that has compiled concrete signatures is covered only
when every one of them is declared, so declaring `f(Float64)` leaves an `f(Int32)` that also ran
reported. A method nothing has compiled has no signature to name, and there the gate asks only
whether some declaration speaks for it.

`inline_suggest = true` additionally runs [`inline_suggestions`](@ref): informational
"consider `@inline` on X" findings (`guarantee = :inline_suggestion`, `status = :info`) for
`@generated` / in-loop callees the compiler left non-inlined. They are **never failures**
(`nfailures` ignores them) — a prompt to benchmark, not a gate.

`dispatch_suggest` (default `true`) runs [`dispatch_suggestions`](@ref): informational findings
(`guarantee = :dispatch`, `status = :info`, never a failure) for call sites that dispatch at run time,
and for those sitting at exactly `max_methods` matching methods — static today, dynamic as soon as one
more method is defined anywhere. On by default because the at-the-limit hazard is one nobody thinks to
ask about: the code looks fine today. Measured on 10,974 PureBLAS specializations it reports nothing,
and costs 17.8% of the sweep — one extra typed-IR read per specialization. Pass `false` to skip it.

`static_ownership_suggest = true` additionally runs [`static_ownership_suggestions`](@ref):
informational "consider static ownership" findings (`guarantee = :static_ownership`,
`status = :info`) for type/symbol-keyed registry lookups. Also never a failure.

This is the agent-facing path. For live feedback while you edit, use [`watch`](@ref) instead.
"""
function audit(target = :registered; kwargs...)
    return _audit(_scan_findings, "audit", target; kwargs...)
end

# The shared driver. `analyze(f, types, guarantees)` is the ONLY thing that differs between
# StrictMode's `audit` (the value-free scan) and StrictModeTest's `proof_audit` (AllocCheck + JET
# + TrimCheck), so they share one implementation rather than drifting apart.
function _audit(
        analyze, name::String,
        target = :registered;
        guarantees = nothing,
        sweep::Bool = false,
        require::Union{Nothing, Symbol} = nothing,
        only = nothing,
        exempt = (),
        inline_suggest::Bool = false,
        static_ownership_suggest::Bool = false,
        dispatch_suggest::Bool = true,
        format = nothing,
        io = nothing,
    )
    # Rendering is the caller's job, so `format`/`io` are accepted only in order to reject them by
    # name: an unrecognized keyword raises a `MethodError`, which says nothing about what to call.
    isnothing(format) && isnothing(io) || throw(
        ArgumentError(
            "$name no longer renders its own output; it returns the findings. Render them " *
                "separately: `print(format_findings($name(…); format = :json))`, or " *
                "`format_findings(fs; format = :text, only_failures = true)`. A module sweep's " *
                "`:json` rendering runs past 100 kB, which is why formatting is the caller's choice."
        )
    )
    isnothing(require) || require in (:public, :all) ||
        throw(ArgumentError("$name: require must be :public or :all (or nothing), got $(require)"))
    isnothing(require) || target isa Module ||
        throw(ArgumentError("$name: require = $(require) needs a Module target"))
    fs = StrictFinding[]
    if target === :registered
        append!(fs, _findings_all(analyze; guarantees))
        if inline_suggest || static_ownership_suggest || dispatch_suggest
            for ((f, types), _) in declarations()
                _is_exempt(f) && continue
                try
                    inline_suggest && append!(fs, inline_suggestions(f, types))
                    static_ownership_suggest && append!(fs, static_ownership_suggestions(f, types))
                    dispatch_suggest && append!(fs, dispatch_suggestions(f, types))
                catch err
                    err isa StrictViolation && rethrow()
                    # Not dropped: the user asked for suggestions over this signature and would
                    # otherwise get silently fewer than they asked for. `:info`, because a failed
                    # advisory is not a guarantee violation.
                    push!(fs, _advisory_error(f, types, err))
                end
            end
        end
    elseif target isa Module
        append!(fs, _registered_findings_in(analyze, target; guarantees))   # declared scope (quiet)
        if sweep
            gs = guarantees === nothing ? (:typestable, :noalloc) : guarantees
            append!(fs, _findings_compiled(analyze, target; guarantees = gs, only, exempt))
        end
        require === :public && append!(fs, _coverage_findings(target; only, exempt))
        require === :all && append!(fs, _coverage_all_findings(target; only, exempt))
        # Inline / static-ownership suggestions are informational (status :info, never failures)
        # and noisy, so opt-in.
        inline_suggest && append!(fs, inline_suggestions(target; only, exempt))
        static_ownership_suggest && append!(fs, static_ownership_suggestions(target; only, exempt))
        dispatch_suggest && append!(fs, dispatch_suggestions(target; only, exempt))
    else
        throw(ArgumentError("$name target must be :registered or a Module, got $(target)"))
    end
    return fs
end
