# StrictMode.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/StrictMode.jl/dev/)
[![CI](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml)
[![Coverage](https://coveralls.io/repos/github/el-oso/StrictMode.jl/badge.svg?branch=master)](https://coveralls.io/github/el-oso/StrictMode.jl?branch=master)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Make correct-and-fast the default; make falling off the fast path a loud error.**

Julia stays *silent* when your code boxes, fails to inline, becomes type-unstable, or allocates
in a hot loop — Rust errors instead. Each of these is invisible until you profile. StrictMode
turns them into **loud, declarable, opt-in guarantees**: attach a macro and the code either
holds the property or fails — at test time, or even at module load.

> This package is the sequel to the JuliaCon 2024 talk *"Why do we need a stricter Julia mode?"*
> The recurring traps that motivated it came from optimizing a SIMD FFT, where runtime tuple
> indexing silently boxed and cost a **measured 135× slowdown** — invisible until profiled.

StrictMode does both halves of the job: the **forcing** (push code onto the fast path) and the
**telling** (shout when you fell off). It is a thin, unified, failing-loud interface over
[AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl),
[JET.jl](https://github.com/aviatesk/JET.jl), and `Test.@inferred` — it doesn't reinvent them.

## Zero cost when disabled

Every check is gated behind a [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl)
compile-time flag. By default the flag is **off**, and every guarantee macro expands to the
*bare call* — production builds pay nothing. Turn the checks on in CI/dev:

```julia
using StrictMode
StrictMode.enable_checks!()       # writes LocalPreferences.toml; restart Julia to apply
StrictMode.disable_checks!()      # back to the production default
```

```julia
# checks ON  →  @assert_noalloc f(x)  expands to a guarded check
# checks OFF →  @assert_noalloc f(x)  expands to exactly  f(x)
```

## Quick start

```julia
using StrictMode   # (with checks enabled)

@assert_noalloc    sum(rand(100))        # fails if the call provably/empirically allocates
@assert_typestable muladd(2.0, 3.0, 1.0) # fails on type instability (return type or internals)
@strict            dot(u, v)             # all per-call guarantees at once; returns the value
```

## Before / after

**Before** — a hot kernel that silently boxes. Nothing warns you; you only notice in a profile:

```julia
component(state, i) = state[i]        # state::Tuple{Int,Float64,String}, i is a runtime value
#                     ^ runtime tuple index → Union return → boxing → 135× slower, silently
```

**After** — the same kernel, guarded. The violation is now *loud* and points at the cause:

```julia
@assert_typestable component(state, rand(1:3))
# ERROR: StrictViolation (@typestable): guarantee not satisfied
#   target:  component(state, rand(1:3))
#   reason:  return type is not concretely inferrable: ... Union{Int64,Float64,String}
```

## The "won't load if it's wrong" guarantee

`@strict_function` checks a definition's contract at **precompile time** against its declared
argument types. If the contract is violated, the module fails to load — the same forcing
function Rust's compiler gives you:

```julia
@strict_function dot3(a::NTuple{3,Float64}, b::NTuple{3,Float64}) =
    a[1]*b[1] + a[2]*b[2] + a[3]*b[3]    # loads: type-stable + non-allocating

@strict_function leaky(n::Int) = sum(collect(1:n))
# ERROR at load: StrictViolation (@strict_function): call provably allocates ...
```

## Interfaces + performance, together

Pair a [TypeContracts.jl](https://github.com/el-oso/TypeContracts) interface with StrictMode's
performance guarantees: `@contract` verifies the *method surface*, StrictMode verifies that
those methods are *fast*.

```julia
@strict_contract AbstractMetric begin
    score(::Self, xs::AbstractVector{<:Real})::Real
end

m = MyMetric(); xs = rand(100)
@verify_strict MyMetric begin   # checks the interface AND that score is stable + non-allocating
    score(m, xs)
end
```

## Automation & agents

Beyond per-call macros, StrictMode can check **automatically**:

```julia
check(f, (T1, T2))                 # function API — never collides with other macros/syntax
@strict module Kernels … end       # mark a module; checked automatically when it loads
check_compiled(MyPkg)              # usage-driven: check whatever actually compiled
StrictMode.watch()                 # live re-checking on each edit (with `using Revise`)
audit(MyPkg; format = :json, exit_on_fail = true)  # one-shot, structured, exit-coded — for AI agents / CI
```

`audit` emits machine-readable findings (with a `file`, `line`, `reason`, and an actionable
`suggestion` per violation) and returns the failure count. See
[Automating checks](https://el-oso.github.io/StrictMode.jl/dev/automating) and
[Agentic feedback](https://el-oso.github.io/StrictMode.jl/dev/agents).

## API

| Macro / function | Guarantee |
|---|---|
| `@assert_noalloc f(args...)` | call is allocation-free (AllocCheck; `@allocated` fallback) |
| `@assert_noboxing f(args...)` | forbid boxing / dynamic dispatch, but **allow** legitimate buffer allocation |
| `@assert_typestable f(args...)` | concrete return type + no internal instability/dispatch (JET + `@inferred`) |
| `@assert_inlined f(args...)` | fail unless the call is inlined (best-effort; not part of `@strict`) |
| `@strict f(args...)` | all per-call guarantees at once; returns the call's value |
| `@strict_function def` | verify the definition's contract at precompile time |
| `@strict_contract I begin … end` | declare a TypeContracts interface carrying perf guarantees |
| `@verify_strict T begin … end` | verify an implementation's surface *and* performance |
| `@explain f(args...)` | aggregate `@code_warntype` + JET + AllocCheck into one "why did it fail" report (never throws) |
| `@unroll for i in lo:hi …` | fully unroll a fixed-count loop with literal indices (kills runtime-tuple-index boxing); not gated |
| `staticval(n)` | lift a count into the type domain (`Val{n}`) for compile-time specialization |
| `check(f, types)` | function API — guarantees on a `(function, signature)`, no macro interference |
| `@strict module … end` | mark a whole module; checked automatically at load |
| `check_all` / `check_compiled` | re-check the registry / sweep what actually compiled |
| `audit` / `watch` | structured one-shot report for agents / live Revise loop for humans |
| `enable_checks!` / `disable_checks!` / `checks_enabled` | toggle / query the compile-time gate |

See the [documentation](https://el-oso.github.io/StrictMode.jl/dev/) and
`docs/src/cookbook.md` for the trap → macro mapping.

### Status
v0.3 adds the ergonomics layer: a function API (`check`), `@strict module` with automatic
checking at load, a usage-driven `check_compiled` sweep, a Revise live loop (`watch`), and an
`audit` path that emits structured findings for AI agents. v0.2 (the guarantee set, `@explain`,
`@unroll`, PrecompileTools warmup, `:fast`/`:full`) is complete.

## Installation

```julia
using Pkg
Pkg.add(url = "https://github.com/el-oso/StrictMode.jl")
```

## License

MIT.
