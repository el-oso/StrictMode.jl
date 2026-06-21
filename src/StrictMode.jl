"""
    StrictMode

Make high-performance Julia predictable to write: turn Julia's *silent* performance failures
— boxing, type instability, hot-loop allocations — into **loud, declarable, opt-in
guarantees**.

Philosophy: *make correct-and-fast the default; make falling off the fast path a loud error.*

All checks are gated behind a [`Preferences`](https://github.com/JuliaPackaging/Preferences.jl)
compile-time flag (`checks_enabled`, default `false`), so production builds pay **nothing** —
the macros expand to the bare call. Enable them in CI/dev with [`enable_checks!`](@ref).

## v0.1 public API
- [`@assert_noalloc`](@ref) — fail if a call allocates (static via AllocCheck, runtime fallback).
- [`@assert_typestable`](@ref) — fail on type instability (JET + `@inferred`).
- [`@strict`](@ref) — apply every per-call guarantee at once.
- [`@strict_function`](@ref) — annotate a definition; checked at precompile (won't load if it
  violates the contract — the "Rust compiler error" experience).
- [`@strict_contract`](@ref) / [`@verify_strict`](@ref) — pair a TypeContracts interface with
  StrictMode performance guarantees.
- [`enable_checks!`](@ref) / [`disable_checks!`](@ref) / [`checks_enabled`](@ref).

See the README and `docs/cookbook.md` for the trap → macro mapping.
"""
module StrictMode

using Preferences: Preferences, @load_preference, @set_preferences!, @has_preference
using AllocCheck: AllocCheck, check_allocs
using JET: JET
using Test: Test
using TypeContracts: TypeContracts
using InteractiveUtils: InteractiveUtils

export @assert_noalloc, @assert_typestable, @assert_noboxing, @assert_inlined
export @strict, @strict_function
export @strict_contract, @verify_strict, @explain
export @unroll, staticval
export StrictViolation, StrictReport, StrictFinding
export check, findings, check_all, check_compiled, audit, format_findings, watch, unwatch
export enable_checks!, disable_checks!, checks_enabled, fail_mode, analysis_mode

include("preferences.jl")
include("report.jl")
include("static_checks.jl")
include("typestability.jl")
include("macros.jl")
include("strict_function.jl")
include("contracts.jl")
include("explain.jl")
include("idioms.jl")
include("inlining.jl")
include("findings.jl")
include("check.jl")
include("registry.jl")
include("audit.jl")

# Warm the heavy analyzers into the precompile image (when checks are enabled).
include("precompile.jl")

end # module StrictMode
