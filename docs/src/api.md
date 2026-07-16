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
@assert_owned
@assert_vectorized
@assert_no_scalar_loops
@assert_no_spill
@assert_effects
@strict
@kernel
```

## Performance diagnostics

Non-failing diagnostics that help you understand why a kernel is fast or slow. `kernel_report`
and `register_report` read the compiled output (LLVM IR and native assembly respectively) and
report intensity, register pressure, and signals like alignment, masking, and serial dependencies.
`descend` drops you into an interactive code inspector. `scalar_fp_loops` is the programmatic
version of `@assert_no_scalar_loops`; `spill_report` is the programmatic version of
[`@assert_no_spill`](@ref). `mca_report`/`@assert_mca` go one step further and estimate
steady-state throughput/IPC via `llvm-mca` (an optional, ~680MiB `LLVM_full_jll` weak dependency —
see [`mca_available`](@ref)); unlike every other guarantee here `@assert_mca` never
fails on its own, only on an explicit `max_rthroughput=`/`min_ipc=` bound you supply, since a
naive whole-function `llvm-mca` run can disagree with ground truth (see its docstring).

```@docs
kernel_report
register_report
spill_report
SpillReport
scalar_fp_loops
descend
mca_report
McaReport
@assert_mca
```

## Static-binary compatibility

Tools for checking compatibility with `juliac --trim=safe`. `@assert_trim_compatible` / the
`:trim_compatible` guarantee **escalate** by [`analysis_mode`](@ref): a cheap TypeContracts static scan in
`:fast`, and juliac's authoritative `verify_typeinf_trim` verifier in `:full` when `TrimCheck` is loaded.
`@assert_trim_safe` is the static-only subset. The reactive `explain_trim` translates a real build log.

The static-scan path has one known coverage gap it can't heuristically close without
false-positiving on safe code: N simultaneous small-`Union` arguments whose specialization count
can exceed juliac's reachability limit on a large/opaque callee. A PASS reached only via the
static scan logs a one-time session note about this; see [`@assert_trim_safe`](@ref)'s docstring
for why, and use `:full` + `TrimCheck` for the authoritative check when it matters.

```@docs
@assert_trim_compatible
@assert_trim_safe
explain_trim
```

## Memory safety

[`@assert_memsafe`](@ref)/`memsafe_report` catch out-of-bounds array reads/writes in unsafe SIMD
kernels **deterministically** instead of flakily, via a guard-page (electric-fence style) harness:
`Array` arguments are copied into `mmap`-backed buffers flush against a trailing `PROT_NONE` guard
page, so an access one element past the intended bounds faults on every run rather than only when
the next page happens to be unmapped. `isolate=true` (the default) runs the probe in a subprocess
so a fatal out-of-bounds *read* (an otherwise-uncatchable `SIGSEGV`) is detected via the child's
exit signal instead of crashing your session — this is the only mode that catches that class;
`isolate=false` is a cheaper in-process check that only catches out-of-bounds *writes*. Needs no
extra dependency (`Serialization`, used for subprocess argument marshaling, is a core dep), but is
Linux/macOS-only and scoped to `Array` arguments — see the docstring for the full scope/limits.

```@docs
@assert_memsafe
memsafe_report
MemsafeReport
```

## Concurrency safety

`@assert_concurrency_safe` proves a function treats its plan/workspace argument as read-only (no
write of, or through, it) — the precondition for sharing one plan object safely across concurrent
tasks. `@assert_no_threadid_state` fails on mutable state indexed by `Threads.threadid()`, the
task-migration hazard (a task can move threads mid-run, stranding state keyed on the thread it
started on). `pool_balance_report` is the companion diagnostic for thread-pool balance questions.

```@docs
@assert_concurrency_safe
@assert_no_threadid_state
pool_balance_report
```

## Testing

Golden-file regression for numeric kernels: record exact or ULP-tolerant reference outputs and
assert on them in future runs. See the [SIMD kernel workflow](cookbook.md) in the cookbook.

```@docs
@golden
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
inline_suggestions
static_ownership_suggestions
StrictFinding
format_findings
nfailures
```

## Fast↔full divergence

The `:fast` heuristic and the `:full` proof occasionally disagree (e.g. internal dynamic dispatch with a
concrete return, which `:fast` misses). `divergence_report` runs both and, on a disagreement, captures an
**IP-free** record — anonymized signature shape, signal *categories*, and versions only — that you can send
to the maintainers to fix the heuristic.

```@docs
divergence_report
StrictDivergence
StrictMode.save_divergence
```

## TypeContracts integration

```@docs
@strict_contract
@verify_strict
registered_strict_contracts
```

## Avoiding boxing

These make the fast path the easy one. `@unroll` fully unrolls a fixed-count loop and replaces
the loop variable with a literal on each pass, so a heterogeneous tuple gets indexed type-stably
without boxing. Unlike the asserts these are not gated — the unrolling always happens.

```@docs
@unroll
staticval
```

## Diagnostics

Where the assert macros fail loudly, `@explain` quietly tells you why, without throwing. It
gathers `@code_warntype`, JET, and AllocCheck into a single `StrictReport`.

```@docs
@explain
StrictReport
```

## Failure type

```@docs
StrictViolation
```

## Configuration

Checks are gated behind a compile-time setting. Toggling it writes `LocalPreferences.toml` and
takes effect on the next Julia start. See [Getting Started](getting_started.md) for the recommended
`Project.toml` pattern.

```@docs
enable_checks!
disable_checks!
checks_enabled
assert_enabled
fail_mode
analysis_mode
backend_available
StrictMode.trimcheck_available
mca_available
ignore_throw
set_ignore_throw!
```

### One-time-init allocation barriers

`Base.OncePerProcess`/`OncePerThread`-memoized lazy init allocates once, then reads a memoized
value forever after — `:full` `@assert_noalloc`/`@assert_noboxing` recognize this automatically
and substitute the (already-correct) `:fast` steady-state heuristic for AllocCheck's all-paths
proof on that call, rather than reporting the initializer's one-time allocation as a violation.
`register_alloc_barrier!` extends this to a hand-rolled memoization pattern that doesn't use one
of those two `Base` types (this includes `Base.OncePerTask`, which is **not** auto-recognized —
its implementation has no detectable non-inlined callee boundary; wrap it in your own function and
register that instead). The exemption is logged once per session via `@info`, never silently.

```@docs
register_alloc_barrier!
ignore_barrier
set_ignore_barrier!
```

### Incremental cache

```@docs
cache_stats
clear_cache!
```
