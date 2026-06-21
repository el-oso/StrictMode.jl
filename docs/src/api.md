# API Reference

```@meta
CurrentModule = StrictMode
```

```@index
```

## Per-call guarantees

Attach these at a call site. Each evaluates the arguments once and returns the call's value, so
they are drop-in wrappers. When checks are disabled they expand to the bare call.

```@docs
@assert_noalloc
@assert_noboxing
@assert_typestable
@assert_inlined
@assert_vectorized
@assert_effects
@strict
```

## Scheduling visibility

```@docs
descend
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

Make the fast path the *easy* path. Unlike the asserts, these are not gated — the unrolling
always applies — and they emit straight-line code with literal indices.

```@docs
@unroll
staticval
```

## Diagnostics

Where the assert macros fail loudly, [`@explain`](@ref) tells you *why* — without throwing.

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
```

### Incremental cache

```@docs
cache_stats
clear_cache!
```
