# Compile-time gating. `CHECKS_ENABLED` is baked at precompile from Preferences; Preferences.jl
# tracks it, so flipping the preference forces a recompile of StrictMode and every module that uses
# its macros — exactly the dev/CI-vs-production switch we want.
#
# A `test/` environment does NOT start clean: `Pkg.test` builds its sandbox with the parent project
# on the load path and merges that project's preferences in, so a package shipping
# `checks_enabled = false` in its own `Project.toml` carries it into its own suite — where every
# `@assert_*` becomes a bare call and `StrictModeTest.__init__` errors. Overriding it needs an
# explicit `[preferences.StrictMode] checks_enabled = true` in `test/Project.toml`.

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

# StrictMode's own UUID, spelled as a project file's `[deps]` block spells it. `test/` pins it
# against `Project.toml`.
const UUID_STRING = "0e98b4f4-d0e6-42ac-af0a-707c24852f32"

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
# `__init__` is kept as a root by `juliac --trim`, so everything it can reach has to be statically
# resolvable — and a session banner is not worth breaking a consumer's build over (issue #28: a
# `--trim` artifact stopped building the moment its author upgraded to 0.4, without calling a single
# StrictMode macro). Measured against juliac's own verifier: `printstyled`, `print` and `write` each
# leave an unresolved call — they route through `styled_print`/`invoke_in_world`, and `stderr` is
# typed `IO` — while a foreigncall verifies clean.
#
# The message IS the format string, and the call passes no variadic arguments. `jl_safe_printf` is
# declared `void jl_safe_printf(const char *fmt, ...)`, and a `ccall` signature naming an extra
# argument describes a NON-variadic call: x86-64 SysV passes it in a register and the callee happens
# to find it, while the AArch64 Apple ABI passes variadic arguments on the stack, so the callee
# reads garbage and the process dies. Measured — `("%s", msg)` segfaulted every macOS CI job at
# `using StrictMode` while Linux and Windows passed.
#
# Passing the message as the format means a `%` in it would be interpreted, so the banner text must
# not contain one. `test/preferences_test.jl` pins that. Color is what a trim-clean load costs.
_eprint(msg::String) = ccall(:jl_safe_printf, Cvoid, (Cstring,), msg)

"""
    StrictMode.banner_enabled() -> Bool

Whether StrictMode prints its tier banner to `stderr` when it loads. Controlled by the `banner`
preference, default `true`. Silence it with

    [preferences.StrictMode]
    banner = false

Baked at precompile like `checks_enabled`, so a change needs a restart. With it off `__init__` has
no body left at all, which is a second answer to issue #28 for anyone who would rather their load
be provably silent than trust that the writer stays trim-clean.

Even with it on, the reporting-tier notice is printed only where StrictMode was chosen — see
[`StrictMode.direct_dependency`](@ref). The disabled-and-CI banner is not gated that way.
"""
banner_enabled() = BANNER_ENABLED
const BANNER_ENABLED = @load_preference("banner", true)::Bool

# The two banner texts, named so a test can assert what `_eprint` requires of them: no `%`, because
# the message is passed as the format string.
const _BANNER_CI_DISABLED = "┌ StrictMode: checks are DISABLED and CI is set.\n" *
    "│ Every @assert_* in this run is a bare call: a green suite proves nothing.\n" *
    "└ Remove `checks_enabled = false` from this environment's preferences.\n"

const _BANNER_REPORTING = "┌ StrictMode: checks ENABLED — reporting tier.\n" *
    "│ The allocation and trim guarantees REPORT (they guess, so they warn);\n" *
    "│ the ones that read compiled output still throw. For the allocation\n" *
    "│ proofs, add StrictModeTest and use @test_* / test_signatures /\n" *
    "│ test_compiled / test_registered.\n" *
    "└ Turn checks off for a shipped application with StrictMode.disable_checks!().\n"

# The shared environment `@v#.#` names. `VERSION` is fixed for a pkgimage, so this is a constant.
const _DEFAULT_ENV = "v$(VERSION.major).$(VERSION.minor)"

# Does the project file at `p` — or in the directory `p` — name StrictMode's UUID? Searches the
# bytes rather than parsing TOML, and reads a fixed-size buffer rather than the whole file, because
# both `TOML.parsefile` and `filesize`/`read(::String, String)` reach code `juliac --trim` cannot
# resolve. 64 KiB holds a project file with thousands of dependencies; a longer one reads as "no".
function _names_strictmode(@nospecialize(p))
    p isa String || return false
    f = isfile(p) ? p :
        isfile(joinpath(p, "JuliaProject.toml")) ? joinpath(p, "JuliaProject.toml") :
        joinpath(p, "Project.toml")
    isfile(f) || return false
    io = open(f)
    buf = Vector{UInt8}(undef, 1 << 16)
    n = readbytes!(io, buf, length(buf))
    close(io)
    return occursin(UUID_STRING, String(@view buf[1:n]))
end

"""
    StrictMode.direct_dependency() -> Bool

Whether an environment this session loads packages from names StrictMode itself. This is who the
tier banner is addressed to: someone who chose StrictMode and can act on which tier is live. A
package that uses StrictMode in its own `src` is a dependency of projects that never named it, and
those sessions stay silent.

Three places are searched, because no single one covers every way a session is started: the active
project (`Base.ACTIVE_PROJECT`), every explicit path on `LOAD_PATH` (`Pkg.test` puts its sandbox
there and clears the active project), and the shared `@v#.#` environment. Anything a project file
names — `[deps]`, `[extras]`, `[weakdeps]` — counts: each is a deliberate mention by whoever wrote
that project.

`__init__` is a `juliac --trim` root, so every call this reaches has to stay statically resolvable
(issue #28), and that dictates the shape: it reads the `Base.ACTIVE_PROJECT` and `LOAD_PATH` slots
rather than `Base.active_project()`/`Base.load_path()`, whose search does not resolve.
`StrictModeTest`'s trim-clean test verifies that against juliac's own verifier. Anything unreadable
counts as "not named", so an unexpected shape leaves a load quiet rather than noisy.
"""
function direct_dependency()
    return try
        _names_strictmode(Base.ACTIVE_PROJECT[]) && return true
        for e in Base.LOAD_PATH
            # `@`-prefixed entries are names, not paths — the active project and `@v#.#` among
            # them, both covered separately.
            startswith(e, '@') && continue
            _names_strictmode(e) && return true
        end
        !isempty(Base.DEPOT_PATH) &&
            _names_strictmode(joinpath(Base.DEPOT_PATH[1], "environments", _DEFAULT_ENV))
    catch
        false
    end
end

function _announce_tier()
    # A compile-time const, so with the banner off this whole function folds to `nothing` and
    # `juliac --trim` never sees the write at all.
    BANNER_ENABLED || return nothing
    # Quiet while a dependent package is being precompiled: that output is captured and replayed
    # per package, so the banner would appear once per dependent instead of once per session.
    iszero(ccall(:jl_generating_output, Cint, ())) || return nothing
    if !CHECKS_ENABLED
        # Silence is the correct default for a shipped application — but under CI it is the
        # vacuous-green shape this package exists to remove: every `@assert_*` is a bare call, so a
        # suite full of them passes while checking nothing. `assert_enabled` is the guard for that,
        # and it only helps a suite that remembers to call it; announcing here covers the ones that
        # do not. Loading `StrictModeTest` turns the same state into a hard error.
        # Not gated on `direct_dependency`, unlike the notice below: this one reports a run whose
        # checks prove nothing, which is worth saying wherever it happens.
        isempty(get(ENV, "CI", "")) || _eprint(_BANNER_CI_DISABLED)
        return nothing
    end
    # Which tier is live is only actionable for whoever chose StrictMode.
    direct_dependency() || return nothing
    _eprint(_BANNER_REPORTING)
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
