# Agentic feedback: a one-shot, structured, exit-coded counterpart to the Revise loop. An AI
# coding agent (or a CI / pre-commit hook) runs `audit`, reads the machine-readable findings, and
# drives an edit→check→fix loop. Unlike the macros it never throws on violations — the caller
# reads the report and the exit code.

"""
    audit(target = :registered; format = :json, io = stdout, exit_on_fail = false,
          guarantees = nothing, sweep = false, only = nothing, exempt = ()) -> Vector{StrictFinding}

Run the strict checks once, write the findings to `io` in a machine-readable `format`, and
return the findings (consistent with [`check`](@ref) / [`check_all`](@ref) /
[`check_compiled`](@ref)). Use [`nfailures`](@ref) for the count, or `exit_on_fail = true` to set
the process exit status to the number of failures — the agent / CI entry point:

```bash
julia --project -e 'using MyPkg, StrictMode; audit(MyPkg; format = :json, exit_on_fail = true)'
```

`target`:
- `:registered` — the mark-once registry ([`check_all`](@ref)). The "check what I promised" scope.
- a `Module` — the registered functions *declared* in that module by default. Pass `sweep = true`
  to also run the usage-driven [`check_compiled`](@ref) over everything the module compiled
  (noisier; scope it with `only` / `exempt`).

`format` is `:json`, `:jsonlines`, `:github`, or `:text`. Each JSON finding carries `guarantee`,
`status`, `file`, `line`, `reason`, and an actionable `suggestion`.

This is the agent-facing path; for live human feedback while editing, use [`watch`](@ref).
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
    )
    fs = StrictFinding[]
    if target === :registered
        append!(fs, check_all(; guarantees, fail = :none, mode))
    elseif target isa Module
        append!(fs, _registered_findings_in(target; guarantees, mode))   # declared scope (quiet)
        if sweep
            gs = guarantees === nothing ? (:typestable, :noalloc) : guarantees
            append!(fs, check_compiled(target; guarantees = gs, fail = :none, only, exempt, mode))
        end
    else
        throw(ArgumentError("audit target must be :registered or a Module, got $(target)"))
    end
    format_findings(io, fs; format)
    exit_on_fail && nfailures(fs) > 0 && exit(nfailures(fs))
    return fs
end
