# Compile-time gating. `CHECKS_ENABLED` is baked at precompile from Preferences; Preferences.jl
# tracks it, so flipping the preference forces a recompile of StrictMode and every module that uses
# its macros — exactly the dev/CI-vs-production switch we want. Preferences are read from the ACTIVE
# project only, so a package and its `test/` environment can disagree and each gets its own pkgimage.

"""
    checks_enabled() -> Bool

Whether StrictMode guarantee checks are active in this build. Controlled by the `checks_enabled`
preference, which defaults to **`true`**: a test environment needs no `[preferences.StrictMode]`
block to get checks, which is what makes them hard to disarm by accident. When `false`, every
guarantee macro expands to the **bare** call/definition — zero runtime cost — and that is the
setting a production deployment wants.

Turn it off for a shipped application with [`disable_checks!`](@ref), or by adding

    [preferences.StrictMode]
    checks_enabled = false

to the deployed project's `Project.toml`. Both trigger recompilation, so restart to apply.
"""
checks_enabled() = CHECKS_ENABLED
const CHECKS_ENABLED = @load_preference("checks_enabled", true)::Bool

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
assert_enabled() = _assert_enabled(
    checks_enabled(), !isempty(get(ENV, "CI", "")), _backend_declared_but_unloaded()
)

"""
    StrictMode.proofs_loaded() -> Bool

Whether `StrictModeTest` — which supplies the AllocCheck/JET/TrimCheck proofs and the `@test_*` /
`test_*` gating API — is loaded in this session. StrictMode itself never calls the proofs; this is
for reporting which tier a session is in.
"""
proofs_loaded() = any(m -> nameof(m) === :StrictModeTest, values(Base.loaded_modules))

# Is `StrictModeTest` a declared dependency of the ACTIVE project while never having been loaded?
# Then the environment advertises the proofs and nothing runs them: every `@assert_*` is the
# value-free scan, and none of the `test_*` gates exist to be called.
#
# Read the project file directly rather than `Base.identify_package`, which searches the entire
# LOAD_PATH and would fire on a copy sitting in the user's global `@v#.#` environment. That is the
# same over-broad check that made test/standalone's isolation proof pass for the wrong reason.
# Failure to read or parse the project is NOT a mismatch — this must never turn a working setup red.
function _backend_declared_but_unloaded()
    proofs_loaded() && return false
    proj = Base.active_project()
    (proj isa AbstractString && isfile(proj)) || return false
    tbl = try
        TOML.parsefile(proj)
    catch
        return false
    end
    deps = get(tbl, "deps", nothing)
    return deps isa AbstractDict && haskey(deps, "StrictModeTest")
end

# Pure core, unit-testable without touching ENV, the baked const, or the filesystem.
function _assert_enabled(enabled::Bool, ci::Bool, backend_declared_but_unloaded::Bool = false)
    if !enabled
        ci && error(
            "StrictMode checks are DISABLED in this build, but CI is set — refusing to skip " *
                "silently (a green run with checks off proves nothing). Checks are on by default, " *
                "so something turned them off: remove `checks_enabled = false` from this " *
                "environment's `[preferences.StrictMode]` block (or its LocalPreferences.toml), or " *
                "run `StrictMode.enable_checks!()` and restart. For the proofs, add " *
                "`StrictModeTest` to that environment."
        )
        return false
    end
    backend_declared_but_unloaded && error(
        "StrictMode: `StrictModeTest` is a dependency of this environment but has not been loaded, " *
            "so every guarantee here runs on the value-free scan while the environment " *
            "advertises the proofs — a green run would not mean what it appears to mean. Add\n" *
            "    using StrictModeTest\n" *
            "once, above this call, at the top of your test entry point. (If you reach this from a " *
            "test file, note the load is process-wide: `test/runtests.jl` is the right place.)"
    )
    return true
end

# What a session gets, stated at load. The state worth announcing is not "checks are off" but
# "checks are on, and `@assert_noalloc` is a scan rather than a proof" — StrictModeTest prints the
# authoritative variant when it loads, so the two tiers are visibly different at a glance.
function _announce_tier()
    CHECKS_ENABLED || return nothing
    # Quiet while a dependent package is being precompiled: that output is captured and replayed
    # per package, so the banner would appear once per dependent instead of once per session.
    iszero(ccall(:jl_generating_output, Cint, ())) || return nothing
    printstyled(stderr, "┌ StrictMode: checks ENABLED — reporting tier.\n"; color = :cyan)
    printstyled(
        stderr,
        "│ @assert_* report and do not gate a build. To gate, add StrictModeTest\n" *
            "│ and use @test_* / test_signatures / test_compiled / test_registered.\n" *
            "└ Turn checks off for a shipped application with StrictMode.disable_checks!().\n";
        color = :cyan
    )
    return nothing
end

"""
    enable_checks!()

Turn StrictMode's guarantee checks back on for the active project, undoing a
[`disable_checks!`](@ref). This writes a `LocalPreferences.toml` entry and triggers recompilation,
so restart the session (or re-`using`) before the change takes effect. Checks are on by default, so
this is only needed where something turned them off.

StrictMode analyzes with a value-free engine (`Base.return_types` concreteness plus a typed-IR
scan) and needs no analysis backend. The proofs — AllocCheck's static no-allocation proof, JET's
`@report_opt`, and TrimCheck's `juliac --trim=safe` verifier — live in the companion
`StrictModeTest` package, which you add to the test environment.
"""
function enable_checks!()
    @set_preferences!("checks_enabled" => true)
    if CHECKS_ENABLED
        @info "StrictMode checks ENABLED."
    else
        @warn "StrictMode checks will be ENABLED — but the gate is compile-time, so THIS session " *
            "is unaffected (`checks_enabled()` stays false and every `@assert_*` is still a " *
            "no-op). Restart Julia to apply. To commit the setting, remove `checks_enabled = " *
            "false` from the project's `[preferences.StrictMode]` block (or its " *
            "`LocalPreferences.toml`), then run in a fresh process."
    end
    return nothing
end

"""
    disable_checks!()

Turn StrictMode guarantee checks off for the active project — what a shipped application wants.
Writes a `LocalPreferences.toml` entry and **triggers recompilation**; restart the session to
apply. After this, every guarantee macro compiles away to the bare call and StrictMode costs
nothing at runtime.
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
