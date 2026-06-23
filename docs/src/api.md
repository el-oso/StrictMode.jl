# API Reference

```@meta
CurrentModule = StrictMode
```

```@index
```

## Per-call guarantees

These go at a call site. Each one evaluates its arguments once and hands back the call's value, so
you can wrap an expression and leave the rest of your code alone. With checks disabled they expand
to the bare call.

```@docs
@assert_noalloc
@assert_noboxing
@assert_typestable
@assert_inlined
@assert_vectorized
@assert_effects
@assert_trim_safe
@strict
@kernel
```

## Scheduling visibility

```@docs
descend
kernel_report
```

## Trim-safety (juliac --trim)

```@docs
explain_trim
```

## Definition-level guarantees

```@docs
@strict_function
@strict_exempt
```

## Automation

The function API, the mark-once registry, and the usage-driven sweep. See
[Automating checks](automating.md).

```@docs
check
findings
register_strict!
registered_strict
check_all
check_compiled
check_signatures
watch
unwatch
```

## Agentic feedback

One-shot, structured, exit-coded reporting for AI agents and CI. See
[Agentic feedback](agents.md).

```@docs
audit
StrictFinding
format_findings
nfailures
```

## TypeContracts integration

```@docs
@strict_contract
@verify_strict
registered_strict_contracts
```

## Idioms (force the fast path)

These make the fast path the easy one. Unlike the asserts they aren't gated, so the unrolling
always happens, and they produce straight-line code with literal indices.

```@docs
@unroll
staticval
```

## Diagnostics

Where the assert macros fail loudly, [`@explain`](@ref) quietly tells you why, without throwing.

```@docs
@explain
StrictReport
```

## Failure type

```@docs
StrictViolation
```

## Configuration

Checks are gated behind a [Preferences.jl](https://github.com/JuliaPackaging/Preferences.jl)
compile-time flag. Toggling it writes `LocalPreferences.toml` and triggers recompilation.

```@docs
enable_checks!
disable_checks!
checks_enabled
fail_mode
analysis_mode
backend_available
ignore_throw
set_ignore_throw!
```

### Incremental cache

```@docs
cache_stats
clear_cache!
```
