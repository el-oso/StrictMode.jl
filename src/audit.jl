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
    audit(target = :registered; format = :json, io = stdout,
          guarantees = nothing, sweep = false, require = nothing,
          only = nothing, exempt = ()) -> Vector{StrictFinding}

Run the strict checks once, write the findings to `io` in a machine-readable `format`, and return
them, the same `Vector{StrictFinding}` you get from [`findings`](@ref). [`nfailures`](@ref) gives
you the count. That's the discovery entry point for an agent or for a dev loop:

```bash
julia --project -e 'using MyPkg, StrictMode; audit(MyPkg; format = :json)'
```

**This is a discovery tool, not a gate.** Its verdicts come from a value-free engine whose
allocation findings are structural guesses, so it reports and never sets an exit status; a human or
an agent reads the output and judges. To gate a build, add `StrictModeTest` to the test environment
and use its `test_*` drivers, which run the proofs.

`target`:
- `:registered` — the mark-once registry, the "check what I promised" scope.
- a `Module` — by default, the registered functions declared in that module. Pass `sweep = true` to
  also sweep everything the module has actually compiled. That's
  noisier, so scope it with `only` / `exempt`.

`format` is `:json`, `:jsonlines`, `:github`, or `:text`. Each JSON finding carries `guarantee`,
`status`, `file`, `line`, `reason`, and an actionable `suggestion`.

`require = :public` (Module target only) adds the **coverage gate**: one failing finding
(`guarantee = :coverage`) per exported/`public` function of the module that is neither
registered ([`register_strict!`](@ref) / [`@strict_function`](@ref)) nor exempted
(`@strict_exempt` / the `exempt` kwarg). It makes "every public kernel declares its
guarantees" a red test instead of a convention — a new function cannot ship silently
unchecked; opting out requires a visible exempt.

`inline_suggest = true` additionally runs [`inline_suggestions`](@ref): informational
"consider `@inline` on X" findings (`guarantee = :inline_suggestion`, `status = :info`) for
`@generated` / in-loop callees the compiler left non-inlined. They are **never failures**
(`nfailures` ignores them) — a prompt to benchmark, not a gate.

`static_ownership_suggest = true` additionally runs [`static_ownership_suggestions`](@ref):
informational "consider GKH ownership" findings (`guarantee = :static_ownership`,
`status = :info`) for type/symbol-keyed registry lookups. Also never a failure.

This is the agent-facing path. For live feedback while you edit, use [`watch`](@ref) instead.
"""
function audit(
        target = :registered;
        format::Symbol = :json,
        io::IO = stdout,
        guarantees = nothing,
        sweep::Bool = false,
        require::Union{Nothing, Symbol} = nothing,
        only = nothing,
        exempt = (),
        inline_suggest::Bool = false,
        static_ownership_suggest::Bool = false,
    )
    require === nothing || require === :public ||
        throw(ArgumentError("audit: require must be :public (or nothing), got $(require)"))
    require === :public && !(target isa Module) &&
        throw(ArgumentError("audit: require = :public needs a Module target"))
    fs = StrictFinding[]
    if target === :registered
        append!(fs, _findings_all(; guarantees))
        if inline_suggest || static_ownership_suggest
            for ((f, types), _) in STRICT_REGISTRY
                _is_exempt(f) && continue
                try
                    inline_suggest && append!(fs, inline_suggestions(f, types))
                    static_ownership_suggest && append!(fs, static_ownership_suggestions(f, types))
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
        append!(fs, _registered_findings_in(target; guarantees))   # declared scope (quiet)
        if sweep
            gs = guarantees === nothing ? (:typestable, :noalloc) : guarantees
            append!(fs, _findings_compiled(target; guarantees = gs, only, exempt))
        end
        require === :public && append!(fs, _coverage_findings(target; only, exempt))
        # Inline / static-ownership suggestions are informational (status :info, never failures)
        # and noisy, so opt-in.
        inline_suggest && append!(fs, inline_suggestions(target; only, exempt))
        static_ownership_suggest && append!(fs, static_ownership_suggestions(target; only, exempt))
    else
        throw(ArgumentError("audit target must be :registered or a Module, got $(target)"))
    end
    format_findings(io, fs; format)
    return fs
end
