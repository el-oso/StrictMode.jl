# Agentic feedback: a one-shot, structured, exit-coded counterpart to the Revise loop. An AI
# coding agent (or a CI / pre-commit hook) runs `audit`, reads the machine-readable findings, and
# drives an edit→check→fix loop. Unlike the macros it never throws on violations — the caller
# reads the report and the exit code.

"""
    audit(target = :registered; format = :json, io = stdout, exit_on_fail = false,
          guarantees = nothing) -> Int

Run the strict checks once, write the findings to `io` in a machine-readable `format`, and
return the **number of failing findings** (`0` = clean) so a caller can set the process exit
status:

```bash
julia --project -e 'using MyPkg, StrictMode; exit(StrictMode.audit(MyPkg))'
```

`target` is `:registered` (the mark-once registry via [`check_all`](@ref)) or a `Module` (which
also runs the usage-driven [`check_compiled`](@ref) sweep). `format` is one of `:json`,
`:jsonlines`, `:github`, `:text`. Each JSON finding carries `guarantee`, `status`, `file`,
`line`, `reason`, and an actionable `suggestion`. With `exit_on_fail = true` the process exits
directly with the failure count.

This is the agent-facing path; for live human feedback while editing, use [`watch`](@ref).
"""
function audit(
        target = :registered;
        format::Symbol = :json,
        io::IO = stdout,
        exit_on_fail::Bool = false,
        guarantees = nothing,
    )
    fs = if target === :registered
        check_all(; guarantees, fail = :none)
    elseif target isa Module
        gs = guarantees === nothing ? (:typestable, :noalloc) : guarantees
        vcat(check_all(; guarantees, fail = :none), check_compiled(target; guarantees = gs, fail = :none))
    else
        throw(ArgumentError("audit target must be :registered or a Module, got $(target)"))
    end
    format_findings(io, fs; format)
    n = nfailures(fs)
    exit_on_fail && n > 0 && exit(n)
    return n
end
