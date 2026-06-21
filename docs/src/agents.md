# Agentic feedback

A human watches a live REPL stream ([`watch`](@ref)); an AI coding agent needs something
different: a **one-shot, structured, exit-coded** result it can read and act on, slotting into an
edit→check→fix loop like a linter or test runner. That is [`audit`](@ref) — the same checks and
the same findings as everything else, rendered for a machine.

## `audit`

```@example agents
using StrictMode
fs = audit(:registered; format = :json, io = devnull)   # returns Vector{StrictFinding}
nfailures(fs)                                            # 0 = clean
```

`audit` **never throws** on violations — it writes the findings and returns them (the same
`Vector{StrictFinding}` as [`check`](@ref) and the other drivers). For the exit-code loop, pass
`exit_on_fail = true`, which sets the process status to the number of failures:

```bash
julia --project -e 'using MyPkg, StrictMode, AllocCheck, JET; audit(MyPkg; format = :json, exit_on_fail = true)'
```

- `target` is `:registered` (the mark-once registry — "check what I promised") or a `Module` (its
  *declared* functions by default; add `sweep = true` for the usage-driven [`check_compiled`](@ref)
  over everything it compiled).
- A whole-module sweep can be noisy when hot and cold code mix — scope it with `only` / `exempt`
  (functions or name `Symbol`s), e.g. `audit(MyPkg; sweep = true, exempt = [:_plan_helper])`.
- `format` is `:json`, `:jsonlines`, `:github`, or `:text`.
- `exit_on_fail = true` exits the process directly with the failure count;
  [`nfailures`](@ref)`(fs)` gives the count programmatically.

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
            "command": "julia --project -e 'using MyPkg, StrictMode, AllocCheck, JET; audit(MyPkg; format=:json, exit_on_fail=true)'"
          }
        ]
      }
    ]
  }
}
```

A non-zero exit surfaces the JSON findings to the agent, which fixes the kernel and re-runs — the
agentic counterpart to a developer watching Revise.
