"""
    StrictModeTest

The proving half of StrictMode, for a package's `test/` environment.

`StrictMode` analyzes with a value-free engine — inferred return types plus a scan of typed IR —
that needs no backend and is cheap enough to run at load time. It **reports**: its allocation
verdicts are structural guesses, so nothing in it can break a build. `StrictModeTest` adds the
proofs — AllocCheck's static no-allocation analysis, JET's optimization analysis, and TrimCheck's
`juliac --trim=safe` verifier — and it **gates**.

There is no preference to switch and no ambient state to read: **which engine a call site uses is
the macro you wrote.**

| report (StrictMode) | prove and gate (StrictModeTest) |
| --- | --- |
| `@assert_noalloc f(x)` | `@test_noalloc f(x)` |
| `@assert_noboxing f(x)` | `@test_noboxing f(x)` |
| `@assert_typestable f(x)` | `@test_typestable f(x)` |
| `@assert_trim_compatible f(x)` | `@test_trim_compatible f(x)` |
| `findings(f, types)` | [`test_signatures`](@ref) |
| `audit(mod; sweep = true)` | [`test_compiled`](@ref) |
| — | [`test_registered`](@ref) |

```julia
using StrictMode, StrictModeTest    # in test/runtests.jl
```

Loading this package requires `StrictMode.checks_enabled()`. With checks off every `@assert_*` is a
bare call, nothing registers, and `test_registered()` would sweep an empty registry and report
success — so it refuses to load rather than gate on nothing.
"""
module StrictModeTest

using StrictMode
using AllocCheck
using JET
using TrimCheck
using TypeContracts   # its TrimDiagnostics parses the trim verifier's output
using PrecompileTools: @setup_workload, @compile_workload

export @test_noalloc, @test_noboxing, @test_typestable, @test_trim_compatible
export @test_strict, @test_kernel
export test_signatures, test_compiled, test_registered
export proof_audit
export proof_findings, AnalysisError
export ignore_barrier, set_ignore_barrier!
export juliac_patches, set_juliac_patches!
export divergence_report, StrictDivergence

include("proofs.jl")
include("macros.jl")
include("drivers.jl")
include("divergence.jl")

# Warm JET + AllocCheck into this package's precompile image so the first proof in a test run is
# fast.
@setup_workload begin
    wk_dot(a, b) = @inbounds a[1] * b[1] + a[2] * b[2]
    A = (1.0, 2.0)
    B = (3.0, 4.0)
    types = (typeof(A), typeof(B))
    @compile_workload begin
        try
            _proof_findings(wk_dot, types, (:typestable, :noalloc, :noboxing, :inlined))
        catch
        end
    end
end

# The state worth announcing is the TIER, not the on/off switch: with this package loaded,
# `@assert_*` still only reports and the `@test_*` surface is what gates.
function _announce()
    # Quiet while a dependent package is being precompiled — see StrictMode's `_announce_tier`.
    iszero(ccall(:jl_generating_output, Cint, ())) || return nothing
    printstyled(stderr, "┌ StrictMode: checks ENABLED — proof tier (StrictModeTest loaded).\n"; color = :green)
    printstyled(
        stderr,
        "│ @assert_* still only report. @test_noalloc / @test_typestable /\n" *
            "└ test_signatures / test_compiled / test_registered gate on AllocCheck + JET + TrimCheck.\n";
        color = :green
    )
    return nothing
end

function __init__()
    StrictMode.checks_enabled() || error(
        "StrictModeTest was loaded but `StrictMode.checks_enabled()` is false in this " *
            "environment, so every `@assert_*` expands to a bare call and nothing registers — " *
            "`test_registered()` would sweep an empty registry and report success. Checks are on " *
            "by default, so something set them off: remove `checks_enabled = false` from this " *
            "environment's `[preferences.StrictMode]` block (or its LocalPreferences.toml) and " *
            "restart."
    )
    _announce()
    return nothing
end

end # module StrictModeTest
