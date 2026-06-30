# Agentic feedback: a one-shot, structured, exit-coded counterpart to the Revise loop. An AI
# coding agent (or a CI / pre-commit hook) runs `audit`, reads the machine-readable findings, and
# drives an edit→check→fix loop. Unlike the macros it never throws on violations — the caller
# reads the report and the exit code.

"""
    audit(target = :registered; format = :json, io = stdout, exit_on_fail = false,
          guarantees = nothing, sweep = false, only = nothing, exempt = ()) -> Vector{StrictFinding}

Run the strict checks once, write the findings to `io` in a machine-readable `format`, and return
them, the same `Vector{StrictFinding}` you get from [`check`](@ref), [`check_all`](@ref), and
[`check_compiled`](@ref). [`nfailures`](@ref) gives you the count, and `exit_on_fail = true` sets
the process exit status to the number of failures. That's the entry point for an agent or for CI:

```bash
julia --project -e 'using MyPkg, StrictMode; audit(MyPkg; format = :json, exit_on_fail = true)'
```

`target`:
- `:registered` — the mark-once registry ([`check_all`](@ref)), the "check what I promised" scope.
- a `Module` — by default, the registered functions declared in that module. Pass `sweep = true` to
  also run the usage-driven [`check_compiled`](@ref) over everything the module compiled. That's
  noisier, so scope it with `only` / `exempt`.

`format` is `:json`, `:jsonlines`, `:github`, or `:text`. Each JSON finding carries `guarantee`,
`status`, `file`, `line`, `reason`, and an actionable `suggestion`.

`inline_suggest = true` additionally runs [`inline_suggestions`](@ref): informational
"consider `@inline` on X" findings (`guarantee = :inline_suggestion`, `status = :info`) for
`@generated` / in-loop callees the compiler left non-inlined. They are **never failures**
(`nfailures`/`exit_on_fail` ignore them) — a prompt to benchmark, not a gate.

This is the agent-facing path. For live feedback while you edit, use [`watch`](@ref) instead.
"""
function audit(
        target = :registered;
        format::Symbol = :json,
        io::IO = stdout,
        exit_on_fail::Bool = false,
        guarantees = nothing,
        sweep::Bool = false,
        only = nothing,
        exempt = (),
        mode::Symbol = analysis_mode(),
        inline_suggest::Bool = false,
    )
    fs = StrictFinding[]
    if target === :registered
        append!(fs, check_all(; guarantees, fail = :none, mode))
        if inline_suggest
            for ((f, types), _) in STRICT_REGISTRY
                _is_exempt(f) && continue
                try
                    append!(fs, inline_suggestions(f, types))
                catch err
                    err isa StrictViolation && rethrow()
                end
            end
        end
    elseif target isa Module
        append!(fs, _registered_findings_in(target; guarantees, mode))   # declared scope (quiet)
        if sweep
            gs = guarantees === nothing ? (:typestable, :noalloc) : guarantees
            append!(fs, check_compiled(target; guarantees = gs, fail = :none, only, exempt, mode))
        end
        # Inline suggestions are informational (status :info, never failures) and noisy, so opt-in.
        inline_suggest && append!(fs, inline_suggestions(target; only, exempt))
    else
        throw(ArgumentError("audit target must be :registered or a Module, got $(target)"))
    end
    format_findings(io, fs; format)
    exit_on_fail && nfailures(fs) > 0 && exit(nfailures(fs))
    return fs
end
