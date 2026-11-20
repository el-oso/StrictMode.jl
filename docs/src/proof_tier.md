# StrictModeTest — the proofs

`StrictMode` reads inferred types and typed IR. It needs no other package, which is what makes it
safe to depend on from `src` — and why its allocation verdicts **report**: typed IR still shows
allocations LLVM later deletes, so there they can only say something looks wrong.

`StrictModeTest` is the other half. It goes in your **test** environment, brings AllocCheck, JET and
TrimCheck, and **throws** — a violation fails the build. Keeping them apart means your users never
install those backends just to use your package.

```julia
# test/Project.toml:  [deps] StrictMode, StrictModeTest
using StrictMode, StrictModeTest

@test_noalloc kernel!(C, A, B)     # throws if AllocCheck finds any allocating path
test_compiled(MyPkg)               # gate everything the module actually compiled
```

The macro you write picks the engine. There is no mode to switch.

| report (StrictMode) | prove and gate (StrictModeTest) |
| --- | --- |
| `@assert_noalloc f(x)` | `@test_noalloc f(x)` |
| `@assert_noboxing f(x)` | `@test_noboxing f(x)` |
| `@assert_typestable f(x)` | `@test_typestable f(x)` |
| `@assert_trim_compatible f(x)` | `@test_trim_compatible f(x)` |
| `@strict f(x)` | `@test_strict f(x)` |
| `@kernel f(x)` | `@test_kernel f(x)` |
| `findings(f, types)` | `test_signatures(pairs)` |
| `audit(mod; sweep = true)` | `test_compiled(mod)` |
| — | `@test_steady_state f(x)` — allocation that STOPS once warmed, measured |
| — | `@test_no_gc_pause f(x)` — no collection runs while the call does, measured |
| — | `proof_findings(f, types)` / `proof_findings(mod)` — proved, as data |
| — | `proof_audit(mod)` — proved, as data |
| — | `test_registered()` |
| `audit(mod; require = :all)` | `test_coverage(mod)` — every method declared or visibly exempt |
| — | `test_exemptions(mod)` — an opt-out the proofs no longer need |
| — | `test_calls(mod)` — every reachable call resolves, including on a branch no test takes |
| — | `test_layers(L => (deps…), …)` — a declared layer graph holds, both ways |
| — | `test_latency(pkg)` — load time and first-call time, measured in a fresh process |
| — | `test_no_unsafe(mod)` — no `ccall`, `pointer` or `unsafe_*`, with a named allow list |
| `@assert_reaches f(x) g` | `@test_reaches f(x) g` — `g` is in the call graph after optimization; fails on a graph it could not read in full too |
| `route_parity(f => T, g => T)` | `test_route_parity(f => T, g => T)` — two entries reach the same functions, both graphs read in full |
| `spin_wait_report(f, types)` | `test_waits_yield(f, types)` — every task the call spawns waits by yielding; fails on what it could not judge |
| `history_report(f, args...; movers)` | `test_history_invariant(f, args...; movers)` — the same bits after other calls moved the package's state, in one process |
| `allocated_bytes(f, args)` | `@test_allocated_zero f(x)` — the call allocates nothing, measured |
| `threaded_speedup_report(pkg, call)` | `test_threaded_speedup(pkg, call)` — threading does not lose to the serial path, measured in fresh processes |
| `threadcount_invariant_report(pkg, call)` | `test_threadcount_invariant(pkg, call; witness)` — the same bits at every thread count, with a witness that the threaded path ran |
| — | `alloc_entry_report(f)` — every entry point of `f`, keyword methods included, with the allocation proof for each |
| `specialization_report(mod)` | `test_specializations(mod; baseline, workload)` — the count's GROWTH against a baseline |

### Failing on a specialization budget

[`test_specializations`](@ref) gates the **growth** of a compiled-specialization count against a
stored baseline, because there is no threshold that is right for every package — which is also why
[`specialization_report`](@ref) is `:info` and cannot fail anything on its own.

When a project has decided on a number, the report gates it with no extra machinery, because the
report already takes the limit:

```julia
@test isempty(specialization_report(MyPkg; max_specializations = 256, max_type_depth = typemax(Int)))
```

That fails the suite on any method over the budget, and the findings name which ones — sorted by
count, highest first. The report judges two limits, so pin the one you do not mean to gate:
`max_type_depth` defaults to 4 and would otherwise fail the same assertion for a reason that has
nothing to do with the specialization count. Use the growth gate to catch a regression against whatever is true today, and
the line above to hold a number the project has agreed to. They answer different questions and
compose.

```@meta
CurrentModule = StrictModeTest
```

```@docs
StrictModeTest.StrictModeTest
```

## Proving macros

```@docs
@test_noalloc
@test_noboxing
@test_typestable
@test_trim_compatible
@test_steady_state
@test_no_gc_pause
@test_allocated_zero
@test_reaches
@test_strict
@test_kernel
```

### Gating drivers

```@docs
test_signatures
test_compiled
test_registered
test_coverage
test_exemptions
test_calls
test_layers
test_latency
test_no_unsafe
test_specializations
test_route_parity
test_waits_yield
test_history_invariant
test_threaded_speedup
test_threadcount_invariant
alloc_entry_report
AllocEntryReport
AllocEntry
```

### Proofs as data

```@docs
proof_findings
proof_audit
AnalysisError
```

### Barriers, juliac patches, and engine divergence

`ignore_barrier` / `set_ignore_barrier!` decide whether a recognized one-time-init barrier is exempt
from AllocCheck's all-paths proof. `divergence_report` / `StrictDivergence` run both engines on one
signature and capture an **IP-free** record of any disagreement — anonymized signature shape, signal
*categories*, and versions only — that you can send to the maintainers to fix the scan.

A function exempted with `@strict_exempt :noalloc` is not a barrier, and its allocation is not
dropped. A call whose every allocation lies inside such functions gets a result of its own from the
proof: a failure with code SM0018 and an `exempt_by` field listing each exempt function with the
`reason` its exemption gave. It is a failure to every reader: `nfailures` counts it, `@test_noalloc`,
`test_signatures`, `test_compiled` and `test_registered` fail on it, and `alloc_entry_report` lists
the entry as failing. `allow_exempt = true`, on any of those and on `proof_findings` (signature or
module) and `proof_audit`, accepts the exemptions for that check; the result is then a note
(`:info`, same code, same `exempt_by`), which is still not a pass. One allocation outside an exempt function makes it an ordinary failure either way,
and so does an exempt callee that was inlined, since its allocation then belongs to the caller's
own code. The exemption is matched on the method, so a function of the same name in another
module excuses nothing.

An exemption covers the exempt function's own code and what that calls. A function or closure the
exempt function was handed is the caller's code: an allocation made while it runs is the caller's,
and makes the result an ordinary failure. So `withbuf(b -> sum(zeros(n)) + b[1], n)` fails for an
exempt `withbuf`, with or without `allow_exempt`, while the pool growth inside `withbuf` is still
accounted for. The same holds for a callable struct, and for callables held in a field or in an
array argument. When the exempt function receives a callable whose type is known only at run time
(an argument declared `Function` or `Any`, a `Vector{Function}`, a field declared `Function`), a
dynamic call inside it may reach that callable, whose body is not analyzed, so the dynamic call
is the caller's and the result is an ordinary failure.

Only an exemption declared in a module counts here, which is what `@strict_exempt` written in a
package's source is. One declared with no module, from a session, covers by name in every module
and names no method: its caller is an ordinary failure in the proof, with or without
`allow_exempt`. The reporting scan still notes such a caller as reaching an exempt function.

```@docs
ignore_barrier
set_ignore_barrier!
juliac_patches
set_juliac_patches!
divergence_report
StrictDivergence
save_divergence
```

