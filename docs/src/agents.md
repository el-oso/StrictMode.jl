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

**Example: Claude Code Stop hook** — audits at the end of every agent turn that touched `src/`,
and blocks the stop until the findings are fixed. Naively re-running `julia -e 'audit(...)'` on
every stop costs a cold start each time; the template below skips unchanged source via a content
hash and only pays the audit when an edit actually happened.

`.claude/settings.json` (committed, so every agent session gets it):

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "bash .claude/hooks/strictmode-stop.sh" }] }
    ]
  }
}
```

`.claude/hooks/strictmode-stop.sh` — point the `julia` line at your audit script (a file that
warms your kernels, runs `audit(MyPkg; ...)`, and errors on `nfailures > 0`):

```bash
#!/usr/bin/env bash
# StrictMode Stop hook: audit only when src/ changed this turn; block the stop on failures.
input=$(cat)
grep -q '"stop_hook_active":true' <<<"$input" && exit 0   # loop guard: don't re-block our own stop

cd "$(dirname "$0")/../.." || exit 0
hash=$(find src -name '*.jl' | sort | xargs cat | md5sum | cut -d' ' -f1)
stamp=.claude/hooks/.src-hash                              # gitignore this stamp file
[[ -f $stamp && $(cat "$stamp") == "$hash" ]] && exit 0    # src untouched → free

if ! out=$(julia --project=bench bench/strictmode_audit.jl 2>&1); then
    echo "StrictMode audit failed — fix these findings before stopping:" >&2
    tail -40 <<<"$out" >&2
    exit 2                                                 # blocks the stop, stderr reaches the agent
fi
echo "$hash" > "$stamp"                                    # only stamp a clean audit
```

The findings appear in the agent's context on exit 2; the agent fixes the violation and stops
again. It's the agent's version of a developer watching Revise, at Stop-hook granularity — a
cold `julia` run costs ~30–60 s once per source-touching turn. Keep the audit script on
`analysis = "fast"` (no AllocCheck/JET needed) so that run stays as cheap as possible.
