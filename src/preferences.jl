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
    assert_enabled() -> Bool

Guard against the silent-skip failure mode: returns [`checks_enabled`](@ref) locally, but
**errors under CI** (any non-empty `ENV["CI"]`, set by GitHub Actions and most CI systems)
when checks are disabled. With checks off every `@assert_*` expands to the bare call, so a
"passing" strictmode test proves nothing — in CI that must be a red build, not a green skip.

Use it as the predicate where you would otherwise skip:

```julia
if !StrictMode.assert_enabled()          # errors in CI instead of skipping
    @test_skip false                      # local session with checks off: skip is fine
    return
end
```

Reports the **build** state (the precompile-baked preference), which is what CI must check:
a preference flipped without a restart does not count.
"""
assert_enabled() = _assert_enabled(checks_enabled(), !isempty(get(ENV, "CI", "")))

# Pure core, unit-testable without touching ENV or the baked const.
function _assert_enabled(enabled::Bool, ci::Bool)
    enabled && return true
    ci && error(
        "StrictMode checks are DISABLED in this build, but CI is set — refusing to skip " *
            "silently (a green run with checks off proves nothing). Enable them by adding\n" *
            "    [preferences.StrictMode]\n    checks_enabled = true\n    fail_mode = \"error\"\n" *
            "to the test environment's Project.toml (or run `StrictMode.enable_checks!()` and " *
            "restart). For the `:full` proofs, add `StrictModeTest` to that environment."
    )
    return false
end

"""
    fail_mode() -> Symbol

How a failed guarantee is reported: `:error` (default — throw [`StrictViolation`](@ref),
Rust-like) or `:warn` (emit `@warn` and continue). Controlled by the `fail_mode` preference.
"""
fail_mode() = FAIL_MODE
const FAIL_MODE = Symbol(@load_preference("fail_mode", "error"))::Symbol

"""
    enable_checks!(; fail_mode = "error")

Turn StrictMode's guarantee checks on for the active project, and set the failure mode (`:error`
or `:warn`) while you're at it. This writes a `LocalPreferences.toml` entry and triggers
recompilation, so restart the session (or re-`using`) before the change takes effect.

StrictMode analyzes with the value-free `:fast` engine (`Base.return_types` concreteness plus a
typed-IR scan) and needs no analysis backend. The rigorous `:full` proofs — AllocCheck's static
no-allocation proof and JET's `@report_opt` — live in the companion `StrictModeTest` package,
which you add to the test environment; there is no preference to switch between them.
"""
function enable_checks!(; fail_mode::Union{Symbol, AbstractString} = "error")
    fm = String(fail_mode)
    fm in ("error", "warn") || throw(ArgumentError("fail_mode must be :error or :warn, got $fail_mode"))
    @set_preferences!("checks_enabled" => true, "fail_mode" => fm)
    if CHECKS_ENABLED
        @info "StrictMode checks ENABLED (fail_mode = :$fm)."
    else
        @warn "StrictMode checks will be ENABLED (fail_mode = :$fm) — but the " *
            "gate is compile-time, so THIS session is unaffected (`checks_enabled()` stays false " *
            "and every `@assert_*` is still a no-op). Restart Julia to apply. To commit the " *
            "setting, add `[preferences.StrictMode]` with `checks_enabled = true` to the project's " *
            "`Project.toml` (or a `LocalPreferences.toml`), then run in a fresh process."
    end
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

# The shared macro-parsing plumbing (_callinfo/_collect_kw!/_call_parts/_macro_call) lives in
# macros.jl, not here — it has nothing to do with Preferences-based gating.
