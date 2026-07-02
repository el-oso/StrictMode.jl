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
            "restart), and make sure AllocCheck + JET are test deps for :full analysis."
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
    analysis_mode() -> Symbol

How thoroughly the per-call asserts ([`@assert_typestable`](@ref), [`@assert_noalloc`](@ref),
[`@strict`](@ref)) analyze a call:

- `:full` (default) — rigorous proofs: JET `@report_opt` for type stability and AllocCheck's
  static no-allocation proof. Best for CI.
- `:fast` — cheap Base-only checks: `Base.return_types` concreteness plus a typed-IR scan
  (dynamic dispatch — including internal dispatch behind a concrete return, explicit heap
  allocation following direct non-inlined callees, throw-path allocations excluded). ~60×
  faster than `:full` (2026-07-02 corpus study, 552 real specializations: 4.9 ms vs 296 ms
  median) at **matching verdicts on every `:typestable`/`:noalloc` case** (3 residual
  `:noboxing` under-reports on cold helpers, all still failing via `:noalloc`). Still a
  heuristic — `:full` remains the proof; `divergence_report` captures any disagreement.

[`@explain`](@ref) and [`@strict_function`](@ref) always use the full analysis regardless of
this setting. Controlled by the `analysis` preference; set it via [`enable_checks!`](@ref).

`analysis_mode()` reads the *current* preference at runtime (so it reflects a change without a
restart, and is what `check`/`audit`/`findings` use by default). The per-call macros instead use
the value **baked at precompile** (`ANALYSIS_MODE`); if a stale package image disagrees with the
current preference, `analysis_mode()` warns once.
"""
function analysis_mode()
    live = Symbol(@load_preference("analysis", "full"))
    if live !== ANALYSIS_MODE && !_MODE_WARNED[]
        _MODE_WARNED[] = true
        @warn "StrictMode: this image was precompiled with analysis = :$ANALYSIS_MODE, but the " *
            "preference is now :$live. `check`/`audit`/`findings` will use :$live; the per-call " *
            "macros still use the baked :$ANALYSIS_MODE until you restart/recompile."
    end
    return live
end
const _MODE_WARNED = Ref(false)
# Baked at precompile — used by the per-call macros (which branch at expansion time).
const ANALYSIS_MODE = Symbol(@load_preference("analysis", "full"))::Symbol

"""
    enable_checks!(; fail_mode = "error", analysis = "full")

Turn StrictMode's guarantee checks on for the active project, and set the failure mode (`:error`
or `:warn`) and the [`analysis_mode`](@ref) (`:full` or `:fast`) while you're at it. This writes a
`LocalPreferences.toml` entry and triggers recompilation, so restart the session (or re-`using`)
before the change takes effect.
"""
function enable_checks!(;
        fail_mode::Union{Symbol, AbstractString} = "error",
        analysis::Union{Symbol, AbstractString} = "full",
    )
    fm = String(fail_mode)
    fm in ("error", "warn") || throw(ArgumentError("fail_mode must be :error or :warn, got $fail_mode"))
    an = String(analysis)
    an in ("full", "fast") || throw(ArgumentError("analysis must be :full or :fast, got $analysis"))
    @set_preferences!("checks_enabled" => true, "fail_mode" => fm, "analysis" => an)
    if CHECKS_ENABLED
        @info "StrictMode checks ENABLED (fail_mode = :$fm, analysis = :$an)."
    else
        @warn "StrictMode checks will be ENABLED (fail_mode = :$fm, analysis = :$an) — but the " *
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

# --- shared macro plumbing (runs at user macro-expansion time, never at module load) ---

# Split a call expression into (function-expr, [arg-exprs]). Handles plain calls `f(a, b)` and
# broadcasts `f.(a, b)` (rewritten to `broadcast(f, a, b)`). Anything else (keyword args, bare
# macrocalls, blocks) gets a clear error pointing at the interference-proof `StrictMode.check`.
function _callinfo(call)
    # Broadcasting: `f.(xs...)` parses as `Expr(:., f, Expr(:tuple, xs...))`.
    if Meta.isexpr(call, :., 2) && Meta.isexpr(call.args[2], :tuple)
        return :broadcast, Any[call.args[1], call.args[2].args...]
    end
    Meta.isexpr(call, :call) || throw(
        ArgumentError(
            "StrictMode guarantee macros expect a call `f(args...)` or broadcast `f.(args...)`, " *
                "got: $call. For keyword args, blocks, or other forms, use the function API: " *
                "`StrictMode.check(f, (T1, T2, …))`."
        )
    )
    fexpr = call.args[1]
    argexprs = call.args[2:end]
    any(a -> Meta.isexpr(a, (:parameters, :kw)), argexprs) && throw(
        ArgumentError(
            "StrictMode guarantee macros don't support keyword arguments in `$call`. " *
                "Use the function API instead: `StrictMode.check(f, (T1, T2, …))`."
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
