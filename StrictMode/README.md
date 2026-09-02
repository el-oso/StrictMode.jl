# StrictMode.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/StrictMode.jl/dev/)
[![CI](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)

**The fast path should be the default, and leaving it should be loud, not something you discover
later with a profiler.**

Julia will let your code box a value, miss an inline, drift into a type instability, or allocate in
a hot loop without saying anything. StrictMode lets you ask for those properties out loud: attach a
macro, and the code either holds the property or fails.

```julia
using Pkg
Pkg.add("StrictMode")
```

```julia
using StrictMode

@assert_noalloc    sum(rand(100))
@assert_typestable muladd(2.0, 3.0, 1.0)
@strict            dot(u, v)             # every per-call guarantee at once; returns the value
```

A definition can carry its contract too, and then a violation stops the module loading:

```julia
@strict_function dot3(a::NTuple{3,Float64}, b::NTuple{3,Float64}) =
    a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
```

## What it does and doesn't promise

StrictMode provides guardrails and checks the things a hot kernel can't afford to get wrong: that
it vectorized, that it isn't allocating, that its types stayed concrete. Break one of those and you
can lose anywhere from 2× to 100×, usually without noticing until you sit down to profile.

Even passing these guardrails doesn't mean you're fast, though. It just helps you stay on the
_correct_ path. Two kernels can be equally green while one is very slow and the other very fast.
StrictMode only helps with the language-level things you need to take into account for speed.

## So, what does it do?

StrictMode analyzes with some fast heuristics built on Base's own inference, so it needs no analysis
backend and nothing here can break your build. Its allocation verdicts read typed IR, where an
allocation LLVM later removes is still visible, so they report. These heuristics are not perfect:
when they are unsure there is a problem they only emit a warning, and when they are sure they throw
an error.

The real proofs live in **[StrictModeTest](../StrictModeTest)**, which you add to your test
environment. It uses heavier backends like AllocCheck, JET and TrimCheck.

```julia
@assert_noalloc kernel!(C, A, B)     # warns in your src
@test_noalloc   kernel!(C, A, B)     # throws in your test
```

## Zero cost when disabled

Checks sit behind a [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl) compile-time
flag, on by default. Turn it off and the macros stop existing: `@assert_noalloc f(x)` compiles to
`f(x)` and nothing else, so a shipped application pays nothing for the asserts you left in your
source.

```julia
StrictMode.disable_checks!()   # then restart Julia
StrictMode.enable_checks!()    # back on
```

The flag is baked in when the package precompiles, which is why it needs a restart rather than
taking effect straight away.

## Some agentic integration

It provides a rudimentary `audit()` check that is friendlier to agents. A better MCP will be added
in the future. With `using Revise`, `StrictMode.watch()` re-checks as you edit.

## Documentation

- [Getting started](https://el-oso.github.io/StrictMode.jl/dev/getting_started)
- [Guarantees](https://el-oso.github.io/StrictMode.jl/dev/guarantees) — what each macro checks, and how
- [Cookbook](https://el-oso.github.io/StrictMode.jl/dev/cookbook) — the trap → macro mapping
- [Automating checks](https://el-oso.github.io/StrictMode.jl/dev/automating) — `audit`, `watch`, module sweeps
- [API reference](https://el-oso.github.io/StrictMode.jl/dev/api) — every macro and function, including
  [the proof tier](https://el-oso.github.io/StrictMode.jl/dev/api#The-proof-tier-StrictModeTest)

## Development

StrictMode is developed with the assistance of [Claude Code](https://claude.com/claude-code).
Generated code is reviewed before it lands, and the design decisions, the measurements behind them,
and the released behaviour are the maintainer's own.

## License

MIT.
