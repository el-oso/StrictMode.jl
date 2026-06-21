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
@assert_typestable
@strict
```

## Definition-level guarantees

```@docs
@strict_function
```

## TypeContracts integration

```@docs
@strict_contract
@verify_strict
registered_strict_contracts
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
```
