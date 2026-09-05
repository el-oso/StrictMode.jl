# API Reference

```@meta
CurrentModule = StrictMode
```

```@index
```

```@docs
StrictMode.StrictMode
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

Tools for checking compatibility with `juliac --trim=safe`. `@assert_trim_compatible` **reports**;
juliac's authoritative `verify_typeinf_trim` verifier is `StrictModeTest`'s
`@test_trim_compatible`, which gates. The reactive `explain_trim` translates a real build log.
`@assert_trim_safe` is the same scan under an older name — deprecated, warns once per session.

The static-scan path has one known coverage gap it can't heuristically close without
false-positiving on safe code: N simultaneous small-`Union` arguments whose specialization count
can exceed juliac's reachability limit on a large/opaque callee. A PASS reached only via the
static scan logs a one-time session note about this; see
[`@assert_trim_compatible`](@ref)'s docstring for why, and use
`StrictModeTest.@test_trim_compatible` when it matters.

```@docs
@assert_trim_compatible
@assert_trim_safe
explain_trim
```

## Memory safety

[`@assert_memsafe`](@ref)/`memsafe_report` catch out-of-bounds array reads/writes in unsafe SIMD
kernels **deterministically** instead of flakily, via a guard-page (electric-fence style) harness:
`Array` arguments are copied into `mmap`-backed buffers flush against a trailing `PROT_NONE` guard
region, so an access one element past the intended bounds faults on every run rather than only when
the next page happens to be unmapped. The probe always runs in a subprocess, so a fatal
out-of-bounds *read* (an otherwise-uncatchable `SIGSEGV`) is detected via the child's exit signal
instead of crashing your session; a *write* is localized by a poisoned canary read back before the
child touches the guard pages. Needs no extra dependency (`Serialization`, used for subprocess
argument marshaling, is a core dep), but is Linux/macOS-only and scoped to `Array` arguments —
arguments it cannot guard are listed in the report's `unguarded` field, and `@assert_memsafe`
rejects the ones the caller can materialize. See the docstring for the full scope/limits.

```@docs
@assert_memsafe
memsafe_report
MemsafeReport
```

## Trusted data

`Untrusted(x)` marks data that came from outside the program — a socket, a file, `ARGS`, a device.
Wrapping is free (same layout as `x`, nothing allocated) and it changes the *type*, so no method
written for the payload matches it: an accidental use raises a `MethodError` rather than quietly
succeeding, and it does so in a shipped build too, because the type is never checked away. The one
way to the value is [`unsafe_trust`](@ref), and [`@assert_trusted`](@ref) reports every function
that calls it outside a validating boundary registered with [`trust_boundary!`](@ref).

This is the Linux kernel's `__user` pointer annotation, in Julia. There the type records that a
pointer came from userspace, `__force` is the one cast that crosses the line, and an external
checker reports where that cast appears — which helps only when somebody runs it. Here the type
does the same work, `unsafe_trust` is the cast, and the check rides the same registry sweep as
every other guarantee.

```@docs
Untrusted
unsafe_trust
trust_boundary!
@assert_trusted
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

Two macros answer "does this definition hold its contract?", and they differ in *when* the answer
is formed. [`@strict_function`](@ref) decides at the enclosing module's load, against the declared
argument types — so a violation stops the module loading. [`@strict_stable`](@ref) decides per
specialization, as each is compiled, which reaches instantiations a declaration cannot name at the
cost of failing later than load.

```@docs
@strict_function
@strict_stable
@strict_exempt
```

## Automation

The function API, the mark-once registry, and the usage-driven sweep. See
[Automating checks](automating.md).

```@docs
findings
migration_report
register_strict!
registered_strict
watch
unwatch
```

## Agentic feedback

One-shot, structured reporting for AI agents and the dev loop. See
[Agentic feedback](agents.md).

```@docs
audit
inline_suggestions
static_ownership_suggestions
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

## Avoiding boxing

These make the fast path the easy one. `@unroll` fully unrolls a fixed-count loop and replaces
the loop variable with a literal on each pass, so a heterogeneous tuple gets indexed type-stably
without boxing. Unlike the asserts these are not gated — the unrolling always happens.

```@docs
@unroll
staticval
```

## Diagnostics

Where the assert macros report a verdict, `@explain` says why, without throwing. It gathers
`@code_warntype`, the inferred return type, and the typed-IR signals into a single `StrictReport`.

```@docs
@explain
StrictReport
```

## Failure type

```@docs
StrictViolation
```

## Configuration

Checks are gated behind a compile-time setting, on by default. Toggling it writes
`LocalPreferences.toml` and takes effect on the next Julia start. See
[Getting Started](getting_started.md) for the `Project.toml` pattern a shipped application wants.

```@docs
enable_checks!
disable_checks!
checks_enabled
proofs_loaded
assert_enabled
mca_available
ignore_throw
set_ignore_throw!
```

### One-time-init allocation barriers

`Base.OncePerProcess`/`OncePerThread`-memoized lazy init allocates once, then reads a memoized
value forever after. The IR scan recognizes those two `Base` once-guard types automatically and
stops at them instead of counting the initializer, and `StrictModeTest` honors the same
recognition: `@test_noalloc` substitutes the (already-correct) steady-state scan for AllocCheck's
all-paths proof on a call whose only allocation risk is the barrier, rather than reporting the
initializer's one-time allocation as a violation. That substitution is logged once per session via
`@info`, never silently, and `StrictModeTest.set_ignore_barrier!(false)` turns it off.

`register_alloc_barrier!` extends the recognition to a hand-rolled memoization pattern that doesn't
use one of those two `Base` types (this includes `Base.OncePerTask`, which is **not**
auto-recognized — its implementation has no detectable non-inlined callee boundary; wrap it in your
own function and register that instead).

```@docs
register_alloc_barrier!
```

### Incremental cache

```@docs
cache_stats
clear_cache!
```
