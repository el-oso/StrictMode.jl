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

`audit` never throws on a violation and never sets an exit status. It writes the findings out and
returns them, the same `Vector{StrictFinding}` you get from [`findings`](@ref).

**It is a discovery tool, not a gate.** Its verdicts come from StrictMode's value-free engine,
whose allocation findings are structural guesses — a tool that reports is allowed to be wrong, a
tool that gates is not. To gate, add `StrictModeTest` to the test environment and call
`test_compiled(MyPkg)` / `test_registered()` / `test_signatures([...])`, which run AllocCheck, JET,
and TrimCheck and throw a `StrictViolation` collecting every failure.

```bash
# report — for an agent's edit→check→fix loop
julia --project -e 'using MyPkg, StrictMode; audit(MyPkg; format = :json)'

# gate — for CI
julia --project=test -e 'using MyPkg, StrictMode, StrictModeTest; test_compiled(MyPkg)'
```

- `target` is `:registered` (the mark-once registry — "check what I promised") or a `Module` (its
  *declared* functions by default; add `sweep = true` to also sweep everything it compiled).
- A whole-module sweep can be noisy when hot and cold code mix — scope it with `only` / `exempt`
  (functions or name `Symbol`s), e.g. `audit(MyPkg; sweep = true, exempt = [:_plan_helper])`.
- `format` is `:json`, `:jsonlines`, `:github`, or `:text`.
- [`nfailures`](@ref)`(fs)` gives the count programmatically.

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

`guarantee` is one of `typestable | noalloc | noboxing | inlined | owned | vectorized |
no_scalar_loops | no_spill | trim_compatible | trusted` (plus the deprecated `trimsafe`); the
advisory passes also emit `coverage`, `inline_suggestion` and `static_ownership`. `status` is one of
`fail | pass | info`:

| status | meaning | counts as a failure? |
|---|---|---|
| `pass` / `fail` | a verdict to act on | `fail` does |
| `info` | advisory ([`inline_suggestions`](@ref)/[`static_ownership_suggestions`](@ref)) | no |

A guarantee the analysis could not evaluate is `fail`, carrying the error text in `reason` — "could
not check" and "is fine" must not render the same.

**A `fail` is worth what the package behind it is worth, and no field tells you that.** `audit`'s
`noalloc` and `noboxing` verdicts come from the scan, which reads typed IR and still sees
allocations LLVM later deletes.

Measured over 120 compiled specializations from two real packages: **8.1%** of those findings were
false, every one measuring 0 bytes — and in the other direction the scan misses **23 of the 91**
signatures AllocCheck flags, a recall of 75%.

So treat them as "investigate". Re-run the same signatures through `StrictModeTest`'s `test_*`
drivers before acting as though a finding were proved. It is the same reason
[`@strict_function`](@ref) warns: it runs during your package's own precompile, where the proof
cannot be loaded, and a guess must not decide a build.

The `suggestion` field is
the structured version of what [`@explain`](@ref) would tell a person, so an agent can act on it
as-is. All of it comes from the [`StrictFinding`](@ref) record, which you can also gather
directly with [`findings`](@ref).

**Not in this list**: [`@assert_memsafe`](@ref)/`memsafe_report` and [`@assert_mca`](@ref)/
`mca_report` are deliberately outside the `findings`/`audit` pipeline — they need real
argument *values* (guard-page buffers, actual assembly) to run, and that pipeline is explicitly
value-free by design (it works from compiled *types*, so it can sweep an entire module without
calling anything). An agent that wants those checks calls them directly and reads the returned
[`MemsafeReport`](@ref)/[`McaReport`](@ref) struct's fields — there is no JSON formatter for them,
but every field is public and named, so `getproperty`/`propertynames` is enough for a script to
consume programmatically.

## `:github` format for CI

```julia
audit(MyPkg; format = :github)
# ::error file=kernels.jl,line=42::StrictMode @noboxing dot3(…) — boxing / dynamic dispatch
```

GitHub Actions renders these as inline annotations on the offending lines.

## Wiring it into a CI or agent loop

StrictMode provides the command; your harness decides when to run it. The gate belongs in the test
environment, where the proofs live:

```bash
julia --project=test -e 'using MyPkg, StrictMode, StrictModeTest; test_compiled(MyPkg)'
```

A thrown `StrictViolation` fails the run and names every failing signature at once. For GitHub
Actions annotations on a *reporting* pass, `audit(MyPkg; format = :github)` emits them inline.

Guard the whole thing with [`assert_enabled`](@ref) as the first line of your strictmode test
or audit script. With checks disabled every `@assert_*` expands to the bare call and the run
passes **vacuously** — `assert_enabled()` turns that into a hard error under CI (any non-empty
`ENV["CI"]`) while still letting a local session skip. `test_registered()` calls it for you, and
`StrictModeTest` refuses to load at all when checks are off.

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
cold `julia` run costs ~30–60 s once per source-touching turn. Keep `StrictModeTest` out of the
audit environment (plain `StrictMode`, no AllocCheck/JET) so that run stays as cheap as possible.
