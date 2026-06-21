# Compile-time gating. The two `const`s below are baked at precompile from Preferences;
# Preferences.jl tracks them, so flipping a preference forces a recompile of StrictMode and
# every module that uses its macros — exactly the CI/dev-vs-production switch we want.

"""
    checks_enabled() -> Bool

Whether StrictMode guarantee checks are active in this build. Controlled by the
`checks_enabled` preference (default `false`). When `false`, every guarantee macro expands to
the **bare** call/definition — zero runtime cost.

Toggle with [`enable_checks!`](@ref) / [`disable_checks!`](@ref) (triggers recompilation).
"""
checks_enabled() = CHECKS_ENABLED
const CHECKS_ENABLED = @load_preference("checks_enabled", false)::Bool

"""
    fail_mode() -> Symbol

How a failed guarantee is reported: `:error` (default — throw [`StrictViolation`](@ref),
Rust-like) or `:warn` (emit `@warn` and continue). Controlled by the `fail_mode` preference.
"""
fail_mode() = FAIL_MODE
const FAIL_MODE = Symbol(@load_preference("fail_mode", "error"))::Symbol

"""
    enable_checks!(; fail_mode::Union{Symbol,AbstractString} = "error")

Turn StrictMode guarantee checks on for the active project and set the failure mode
(`:error` or `:warn`). Writes a `LocalPreferences.toml` entry and **triggers recompilation**;
restart the session (or re-`using`) for the change to take effect.
"""
function enable_checks!(; fail_mode::Union{Symbol, AbstractString} = "error")
    fm = String(fail_mode)
    fm in ("error", "warn") || throw(ArgumentError("fail_mode must be :error or :warn, got $fail_mode"))
    @set_preferences!("checks_enabled" => true, "fail_mode" => fm)
    @info "StrictMode checks ENABLED (fail_mode = :$fm). Restart Julia to apply."
    return nothing
end

"""
    disable_checks!()

Turn StrictMode guarantee checks off for the active project (the production default). Writes a
`LocalPreferences.toml` entry and **triggers recompilation**; restart the session to apply.
After this, every guarantee macro compiles away to the bare call.
"""
function disable_checks!()
    @set_preferences!("checks_enabled" => false)
    @info "StrictMode checks DISABLED. Restart Julia to apply."
    return nothing
end

# Central gating helper used by every macro at *expansion* time. Returns the checked branch
# only when checks are compiled in; otherwise the untouched expression. Kept as a plain
# function so the gating logic itself is unit-testable.
_gate(check_expr, passthrough_expr) = CHECKS_ENABLED ? check_expr : passthrough_expr

# --- shared macro plumbing (runs at user macro-expansion time, never at module load) ---

# Split a `f(args...)` call expression into (function-expr, [arg-exprs]). Errors loudly on
# anything that is not a plain positional call, so the guarantee macros stay predictable.
function _callinfo(call)
    Meta.isexpr(call, :call) || throw(
        ArgumentError(
            "StrictMode guarantee macros expect a function call `f(args...)`, got: $call"
        )
    )
    fexpr = call.args[1]
    argexprs = call.args[2:end]
    any(a -> Meta.isexpr(a, (:parameters, :kw)), argexprs) && throw(
        ArgumentError(
            "StrictMode guarantee macros do not support keyword arguments yet: $call"
        )
    )
    return fexpr, argexprs
end

# Evaluate each argument exactly once into a fresh local, so side effects don't repeat across
# the warmup/measure passes. Returns (arg-symbols, binding-exprs) with arguments escaped.
function _bind_args(argexprs)
    syms = [gensym(:arg) for _ in eachindex(argexprs)]
    binds = [:($s = $(esc(e))) for (s, e) in zip(syms, argexprs)]
    return syms, binds
end
