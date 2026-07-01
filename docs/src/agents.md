# Agentic feedback

[`audit`](@ref) is StrictMode's one-shot, structured reporting path — the same checks as
everywhere else, returned as a `Vector{StrictFinding}` and optionally formatted as JSON, GitHub
annotations, or plain text. It never throws on a violation; it writes the findings and returns
them, so an AI agent or CI script can act on them programmatically.

## `audit`

```@example agents
using StrictMode
fs = audit(:registered; format = :json, io = devnull)   # returns Vector{StrictFinding}
nfailures(fs)                                            # 0 = clean
```

`audit` never throws on a violation. It writes the findings out and returns them, the same
`Vector{StrictFinding}` you get from [`check`](@ref) and the other drivers. For the exit-code loop,
pass `exit_on_fail = true` and the process status becomes the number of failures:

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

`guarantee` is one of `typestable | noalloc | noboxing | inlined`, and `status` is one of
`fail | pass | skip`. The `suggestion` field is the structured version of what [`@explain`](@ref)
would tell a person, so an agent can act on it as-is. All of it comes from the
[`StrictFinding`](@ref) record, which you can also gather directly with [`findings`](@ref).

## `:github` format for CI

```julia
audit(MyPkg; format = :github)
# ::error file=kernels.jl,line=42::StrictMode @noboxing dot3(…) — boxing / dynamic dispatch
```

GitHub Actions renders these as inline annotations on the offending lines.

## Wiring it into a CI or agent loop

StrictMode provides the command; your harness decides when to run it. The pattern is the same
whether you're using GitHub Actions, a pre-commit hook, or an AI coding agent:

```bash
julia --project -e 'using MyPkg, StrictMode, AllocCheck, JET; audit(MyPkg; format=:json, exit_on_fail=true)'
```

A non-zero exit (failure count) signals the loop to act on the findings. For GitHub Actions,
`:github` format emits inline annotations on the offending lines.

Guard the whole thing with [`assert_enabled`](@ref) as the first line of your strictmode test
or audit script. With checks disabled every `@assert_*` expands to the bare call and the run
passes **vacuously** — `assert_enabled()` turns that into a hard error under CI (any non-empty
`ENV["CI"]`) while still letting a local session skip.

Pair it with the coverage gate — `audit(MyPkg; require = :public)` — so an agent adding a new
public function gets a failing `:coverage` finding (with the `register_strict!` snippet to
paste) until the function either declares its guarantees or is exempted visibly. See
[Automating checks](automating.md).

**Example: Claude Code hook** — runs `audit` after every edit round and feeds failures back to
the agent automatically:

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

The JSON findings appear in the agent's context on a non-zero exit; the agent fixes the violation
and runs again. It's the agent's version of a developer watching Revise.
