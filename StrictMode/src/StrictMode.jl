"""
    StrictMode

Make high-performance Julia predictable to write: turn Julia's *silent* performance failures
— boxing, type instability, hot-loop allocations — into **loud, declarable, opt-in
guarantees**.

Philosophy: *make correct-and-fast the default; make falling off the fast path a loud error.*

All checks are gated behind a [`Preferences`](https://github.com/JuliaPackaging/Preferences.jl)
compile-time flag (`checks_enabled`, default `true`), so a dev or test environment is checked
without any setup. A shipped application turns them off with [`disable_checks!`](@ref); the macros
then expand to the bare call and pay **nothing**.

## Two packages

This one reads inferred types and typed IR, and depends on no analysis backend at all. The proofs —
AllocCheck, JET and TrimCheck — live in `StrictModeTest`, a separate package for your test
environment. The macro you write picks the engine: `@assert_noalloc` is this package's scan,
`@test_noalloc` is the proof.

## Where to start
- [`@assert_noalloc`](@ref) — report if a call allocates, from a scan of typed IR.
- [`@assert_typestable`](@ref) — throw on a non-concrete inferred return type; report the IR
  signals for dispatch and boxing behind a concrete return.
- [`@strict`](@ref) — type stability, owned scratch and allocation-freedom on one call.
- [`@strict_function`](@ref) — annotate a definition, checked at the enclosing module's precompile.
- [`@strict_contract`](@ref) / [`@verify_strict`](@ref) — pair a TypeContracts interface with
  StrictMode performance guarantees.
- [`enable_checks!`](@ref) / [`disable_checks!`](@ref) / [`checks_enabled`](@ref).

Which guarantees throw and which report is fixed per guarantee: the ones that read compiled output
throw, the ones that infer report. `docs/src/guarantees.md` lists both, and `docs/src/cookbook.md`
has the trap → macro mapping.
"""
module StrictMode

# AllocCheck and JET are not dependencies of this package at all; StrictModeTest supplies them.
using Preferences: Preferences, @load_preference, @set_preferences!
using TOML: TOML
using TypeContracts: TypeContracts
using InteractiveUtils: InteractiveUtils

export @assert_noalloc, @assert_typestable, @assert_noboxing, @assert_owned, @assert_inlined
export @assert_vectorized, @assert_no_scalar_loops, @assert_effects, @assert_trim_safe, @assert_trim_compatible, descend, explain_trim, kernel_report, scalar_fp_loops, register_report
export @assert_no_spill, spill_report, SpillReport
export @assert_memsafe, memsafe_report, MemsafeReport
export @assert_mca, mca_report, McaReport, mca_available
export @assert_concurrency_safe, @assert_no_threadid_state, pool_balance_report
export @strict, @kernel, @strict_function, @strict_stable, @strict_exempt
export @strict_contract, @verify_strict, @explain
export @unroll, staticval
export @golden
export StrictViolation, StrictReport, StrictFinding
export findings, audit, format_findings, nfailures, watch, unwatch
export inline_suggestions, migration_report
export static_ownership_suggestions
export @assert_trusted, Untrusted, unsafe_trust, trust_boundary!
export clear_cache!, cache_stats
export enable_checks!, disable_checks!, checks_enabled, assert_enabled, proofs_loaded
export register_alloc_barrier!

include("preferences.jl")
include("report.jl")
include("backend.jl")
include("effects.jl")
include("static_checks.jl")
include("typestability.jl")
include("macros.jl")
include("strict_function.jl")
include("contracts.jl")
include("trimsafe.jl")
include("explain.jl")
include("idioms.jl")
include("inlining.jl")
include("static_ownership.jl")
include("trusted.jl")
include("scheduling.jl")
include("concurrency.jl")
include("findings.jl")
include("cache.jl")
include("check.jl")
include("memsafe.jl")
include("mca.jl")
include("registry.jl")
include("audit.jl")
include("golden.jl")
include("migration.jl")

# The proofs — AllocCheck, JET, TrimCheck — and the `@test_*` / `test_*` gating API live in the
# companion `StrictModeTest` package. Nothing here calls them, and nothing here is a stub they fill.

__init__() = _announce_tier()

end # module StrictMode
