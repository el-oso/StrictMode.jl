# Agentic feedback

A human watches a live REPL stream ([`watch`](@ref)); an AI coding agent needs something
different: a **one-shot, structured, exit-coded** result it can read and act on, slotting into an
edit→check→fix loop like a linter or test runner. That is [`audit`](@ref) — the same checks and
the same findings as everything else, rendered for a machine.

## `audit`

```@example agents
using StrictMode
audit(:registered; format = :json, io = devnull)   # returns the number of failing findings (0 = clean)
```

`audit` **never throws** on violations — it writes the findings and returns the failure count, so
a caller sets the process exit status:

```bash
julia --project -e 'using MyPkg, StrictMode; exit(StrictMode.audit(MyPkg))'
```

- `target` is `:registered` (the mark-once registry) or a `Module` (also runs the usage-driven
  [`check_compiled`](@ref) sweep).
- `format` is `:json`, `:jsonlines`, `:github`, or `:text`.
- `exit_on_fail = true` exits the process directly with the failure count.

## The JSON schema

Each finding is one object (here pretty-printed):

```json
{
  "module": "Kernels",
  "function": "dot3",
  "signature": "(Tuple{Int64, Float64, Float32})",
  "guarantee": "noboxing",
  "status": "fail",
  "file": "kernels.jl",
  "line": 42,
  "reason": "boxing / dynamic dispatch",
  "suggestion": "boxing / runtime tuple index: use @unroll for fixed-size loops, or dispatch the size into a Val{N} type parameter."
}
```

`guarantee` ∈ `typestable | noalloc | noboxing | inlined`; `status` ∈ `fail | pass | skip`. The
`suggestion` is the structured equivalent of what [`@explain`](@ref) tells a human — an agent can
act on it directly. The fields come from the [`StrictFinding`](@ref) record, which you can also
collect programmatically with [`findings`](@ref).

## `:github` format for CI

```julia
audit(MyPkg; format = :github)
# ::error file=kernels.jl,line=42::StrictMode @noboxing dot3(…) — boxing / dynamic dispatch
```

GitHub Actions renders these as inline annotations on the offending lines.

## Wiring it into Claude Code

The package provides the command; the harness wires it. A `Stop` (or `PostToolUse`) hook in
`settings.json` that audits after edits and feeds failures back to the agent:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "julia --project -e 'using MyPkg, StrictMode; exit(StrictMode.audit(MyPkg; format=:json))'"
          }
        ]
      }
    ]
  }
}
```

A non-zero exit surfaces the JSON findings to the agent, which fixes the kernel and re-runs — the
agentic counterpart to a developer watching Revise.
