# Guarantees

A guarantee is a property you declare for a function. StrictMode checks it at the call site, when
the module loads, or in the test suite, and reports any later edit that breaks it. Some guarantees
are about **speed**: the properties a hot path needs. The others are about **correctness**: they
keep a program from reading the wrong memory, racing, or failing on a branch no test ran.

### Speed

| Guarantee | What it checks | Section |
|:--- |:--- |:--- |
| `:noalloc` | no heap allocation | `@assert_noalloc` below |
| `:noboxing` | no boxed value and no run-time dispatch; allocating a buffer is fine | `@assert_noboxing` below |
| `:typestable` | concrete return type and locals | `@assert_typestable` below |
| `:inlined` | a named callee is inlined into the caller | [`@assert_inlined`](@ref) |
| `:vectorized`, `:no_scalar_loops` | loops compile to vector arithmetic rather than one element at a time | [`@assert_vectorized`](@ref), [Performance diagnostics](performance_diagnostics.md) |
| `:no_spill` | the kernel's live values fit in registers | [`@assert_no_spill`](@ref) |
| `:owned` | the hot path finds its buffers by dispatch rather than a run-time lookup | Static ownership below |
| `@test_no_gc_pause`, `test_latency` | no collection pauses the call; load and first-call time stay in budget | their sections below |

### Correctness

| Guarantee | What it checks | Section |
|:--- |:--- |:--- |
| `:memsafe` | no read or write past the end of an `Array` argument, checked against guard pages | `@assert_memsafe` below |
| `:noalias` | no argument the call writes overlaps one it reads | `@assert_noalias` below |
| `:noescape` | a value of a registered scoped type, created in the frame, stays in it | `@assert_noescape` below |
| `:trusted` | data from outside is read only inside a declared trust boundary | `@assert_trusted` below |
| `:concurrency_safe` | no write to the shared argument (the first by default), to anything reached through it, or to a mutable global | `@assert_concurrency_safe` below |
| `:no_threadid_state` | no state indexed by `threadid()` is written and still in use after a point where the task can be suspended | `@assert_no_threadid_state` below |
| `:trim_compatible` | the code still builds as a static binary with `juliac --trim` | `@assert_trim_compatible` below |
| `test_calls` | every call reachable from the module's compiled signatures has a matching method and reads only defined names, even on branches no test runs | `test_calls` below |
| `test_no_unsafe` | no `ccall`, `pointer`, `unsafe_` function or `@inbounds` beyond the ones the module lists as allowed | `test_no_unsafe` below |
| `test_layers` | each module extends only functions of the layers it declared, and reads only public names of the others | `test_layers` below |
| `@golden` | a result matches the one recorded for it, bit for bit or within a stated number of ULPs | `@golden` below |
| `test_threadcount_invariant` | a call returns the same bits at every thread count, and its threaded path ran | `test_threadcount_invariant` below |

### How much a verdict is worth

A check that could not finish never passes. A scan that read only part of the code reports SM0207,
"not established". An analysis that errored reports the error as a failure. A scan that could not
follow a callee reports that callee as undecided.

A signature that always throws or never returns does not pass either. Its inferred return type is
`Union{}`, so no path returns and there is nothing for a guarantee to check: that is an error
helper, a worker loop that runs until its task ends, and it is also a kernel called with a wrong
argument type or without a required keyword argument. Every guarantee
reports SM0208 for it. In a sweep (`audit`, `test_compiled`, `test_registered`, `@strict_policy`)
that is a note, because a module's error helpers are not defects. Where the signature was listed
(`test_signatures`, a `@verify_strict` line, `@strict_function signatures = [...]`) it is a failure.

A module policy is a sweep with a position. `@strict_policy` checks only the methods defined above
it, and raises when none of them is checked or accounted for (exempt, declared with
`signatures = [...]`, a constructor, a macro or a callable object's method), so it is written at
the end of the module ([Automating](automating.md)).

Whether a failure throws or warns depends on how sure the check is. A check that observes what it
reports throws: it read compiled output, the type the compiler assigned, or a store in the IR. A
check that infers something it cannot see, such as the allocation scan, warns, and the proof in
StrictModeTest (AllocCheck, JET, TrimCheck) is the gate. Promise scope below says which is which.

Where a guarantee needs a policy choice, it follows an established one: Go for memory and calls
into C, Rust for concurrency and unsafe code, and Julia's own semantics where the two disagree.
See Compared with Rust below.

A speed guarantee keeps you on the fast path; it does not promise you have found the *fastest*
path. For the gap between "passing" and "fast", `@explain` and the rest of the tools, see
[Performance diagnostics](performance_diagnostics.md). For the techniques that fix what a
guarantee flags, `@unroll` among them, see the [Cookbook](cookbook.md).

## Key concepts

If these terms are unfamiliar, a quick definition first:

- **Type stability** — the compiler can predict a function's return type without running it. A
  stable function always returns `Float64`, say; an unstable one might return `Float64` or `Int`
  depending on a runtime condition. Instability forces the compiler to generate slower, more
  general code.

- **Boxing** — wrapping a value in a generic heap-allocated container because its type can't be
  predicted at compile time. A runtime index into a heterogeneous tuple (e.g. `t[i]` where `t`
  holds mixed types) causes it. Each box costs a heap allocation and prevents SIMD vectorization.

- **Dynamic dispatch** — deciding which method to call at runtime instead of compile time. Happens
  when the compiler can't pin down the type of a receiver, and adds a function-table lookup to
  every call.

Allocation-free code avoids boxing and dispatch; type-stable code avoids instability (and usually
boxing too). The macros below check each property separately, so you can be precise about what you
need. See [Key Concepts](concepts.md) for worked examples of each.

Every example here is live: the docs are built with checks enabled, so the analysis runs as the
page is generated. Passing calls appear as real `@example` blocks; calls meant to fail appear as
annotated code, keeping the build green.

```@example guide
using StrictMode
```

## `@assert_noalloc` / `@test_noalloc` — no heap allocations

`@assert_noalloc` scans the call's typed IR for allocation sites. Dynamic dispatch and boxing both
show up as allocations, so they get caught here as well.

```@example guide
dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]

@assert_noalloc dot3((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
```

`static = false` skips the scan and measures the call directly with `@allocated`, after a warmup
pass — a value-dependent measurement of what actually ran, not a signature-level verdict:

```julia
@assert_noalloc static = false stream_step!(buffer, x)
```

An allocating hot loop gets reported:

```julia
function grow_and_sum(n)
    v = Int[]              # allocates
    for i in 1:n
        push!(v, i)        # …and grows
    end
    return sum(v)
end

@assert_noalloc grow_and_sum(10)
# ┌ Warning: StrictViolation (@noalloc): guarantee not satisfied
# │   target:  grow_and_sum(10)
# │   reason:  allocates / boxes (value-free IR scan) …
# └   note:    StrictMode's `@assert_noalloc` check is a heuristic, so it reports rather than
#              gating. Add StrictModeTest and use `@test_noalloc` for the proof.
```

**Reported, not thrown** — see [Why `@assert_noalloc` reports instead of
gating](#Why-@assert_noalloc-reports-instead-of-gating) below. The proof is
`StrictModeTest`'s `@test_noalloc`: it hands the call to
[AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl) and asks for a proof that the call
cannot allocate on any path:

```julia
using StrictMode, StrictModeTest        # test/Project.toml
@test_noalloc grow_and_sum(10)
# ERROR: StrictViolation (@noalloc): guarantee not satisfied
#   reason:  allocates (… site(s)) …
```

### Why `@assert_noalloc` reports instead of gating

The scan reads **typed IR**. AllocCheck reads **LLVM IR**, after the optimizer has run. Anything
LLVM deletes in between is still visible to the scan and already gone for the proof:

```text
  your code  →  typed IR  →  LLVM optimizes  →  LLVM IR  →  machine code
                   ↑                              ↑
              the scan reads here            AllocCheck reads here
              sees the allocation            it has been deleted
```

```julia
mkvec(n::Int) = length(Vector{Float64}(undef, n))
@allocated mkvec(4)     # => 0   — the array is never materialized
```

The scan flags it, AllocCheck does not, and the truth is 0 bytes. Measured over 120 compiled
specializations from two real packages, 8.1% of the scan's findings were false this way.

So these checks **warn** instead of throwing. It matters most at load time:
[`@strict_function`](@ref) runs during your package's own precompile, where `StrictModeTest`
cannot be loaded — it belongs to `test/`. A wrong guess there would stop a consumer's package
installing over code that may be perfectly clean.

The declaration is registered either way, so the proof still gets its turn:

```julia
using StrictMode, StrictModeTest     # in test/
@test_noalloc kernel!(C, A, B)       # AllocCheck's all-paths proof — throws
test_registered()                    # …or re-prove everything that was declared
```

Guarantees whose check *observes* compiled output — `:typestable`'s return-type layer, `:memsafe`,
`:vectorized`, `:no_spill`, `:inlined`, `:owned`, `:trusted` — throw from StrictMode directly.
The ones that infer what they cannot see (`:noalloc`, `:noboxing`, `:no_scalar_loops`,
`:trim_compatible`, and both of `:typestable`'s IR signals — internal dispatch and
the union-typed local) report.

### What the scan leaves out of your body

Two kinds of statement are in the compiled body but never counted against it.

**StrictMode's own machinery.** With checks enabled, a `@strict` or `@assert_*` site leaves a live call
to StrictMode's scan behind a per-site flag, so a function containing one carries the tool in its IR.
Scanning that function skips those callees entirely: their cost belongs to the tool, is paid once per
site, and disappears with [`disable_checks!`](@ref). They are not treated as a one-time-init barrier
either — a barrier grants an allocation exemption, and StrictMode's presence says nothing about whether
your code allocates.

**Error paths**, while [`StrictMode.ignore_throw`](@ref) is `true` (the default). That means every statement from
which no path reaches a `return` carrying a value, not just the `throw`: the message an
`ArgumentError("… $x …")` builds is usually assembled in an earlier block that jumps to the throw, and
counting only the throw's own block reported allocation for text no successful call builds. A loop is
never an error path.

### One-time-init calibration doesn't have to break this

A lazy calibration memoized with `Base.OncePerProcess`/`OncePerThread` allocates once, then reads
the memoized value forever after. AllocCheck's all-paths proof sees the initializer's one-time
allocation as statically reachable and would red a call that's provably alloc-free in steady
state. The IR scan recognizes the two `Base` once-guard types automatically and stops at them,
and `@test_noalloc`/`@test_noboxing` honor that: on a call whose ONLY allocation risk is the
barrier, they substitute the steady-state scan for AllocCheck's all-paths proof rather than
report the cold-path allocation as a violation — logged once per session via `@info`, never
silently:

```julia
const _NP_ONCE = Base.OncePerProcess{Int}(_measure_calibration)
steady(x::Int) = x + _NP_ONCE()

@assert_noalloc steady(1)   # passes: the once-guard's cold path is exempted, not the caller's own code
```

For a hand-rolled memoization pattern that doesn't use one of those two `Base` types, register it
explicitly with [`register_alloc_barrier!`](@ref). `Base.OncePerTask` is **not** auto-recognized
— its implementation has no detectable non-inlined callee boundary to key off of — so wrap it in
your own function and register that.

What a barrier is, precisely: **the memoized accessor call**, whose cold path is the one-time init
of a scope — a process, a thread, or a task. Recognition keys on that call, so it covers
`_NP_ONCE()` and nothing else: not a function that happens to be reachable from it, and not a
function that allocates again within the same scope.

A growing pool is the case that catches people out, because the allocator often lives beside a
once-guard. It allocates again at a new high-water mark within the same process, thread and task,
so no scope's init has finished and there is no cold path to key on. It is an ordinary allocating
function, and registering it by hand does not make it a barrier — it tells the scan to stop there
anyway.

The distinction matters because the two call for different tools. A barrier is right where the
allocation genuinely happens once per process or thread. Where it happens a bounded number of times
— a pool growing to its high-water mark — `:noalloc` cannot express that: "finitely many growths,
then nothing" is a property of the call sequence, not of the code, so an all-paths proof must report
the growth path forever. Excuse it visibly with
`@strict_exempt :noalloc reason = "…"` and assert the real property where it can be measured, by
warming the call and checking that a second identical call allocates nothing.

## `@assert_noboxing` / `@test_noboxing` — forbid boxing, allow buffers

[`@assert_noboxing`](@ref) is the easygoing cousin of `@assert_noalloc`. It objects only to
allocations that come from type uncertainty: boxing (the runtime-tuple-index trap, a captured
variable wrapped in a `Core.Box`, or an isbits value stored into a slot of abstract type, such as a
`Float64` into a `Ref{Any}`) and dynamic dispatch. Honest typed heap allocations are fine.
Use it on a hot path that may allocate a working buffer but must never box.

```@example guide
function fill_sum(n)
    v = Vector{Float64}(undef, n)   # a real heap allocation …
    for i in 1:n
        @inbounds v[i] = i
    end
    return sum(v)
end

@assert_noboxing fill_sum(3)        # passes: it allocates, but it does not box
```

The same call doesn't get past `@assert_noalloc`, which forbids any allocation:

```julia
@assert_noalloc fill_sum(3)
# ┌ Warning: StrictViolation (@noalloc): allocates / boxes … Vector{Float64} …
@test_noalloc fill_sum(3)
# ERROR: StrictViolation (@noalloc): allocates (1 site(s)) …
```

Boxing and dynamic dispatch are still out:

```julia
boxy(t) = (s = 0.0; for i in 1:3; s += t[i]; end; s)   # heterogeneous tuple, runtime index
@assert_noboxing boxy((1, 2.0, 3.0f0))
# ┌ Warning: StrictViolation (@noboxing): boxing / dynamic dispatch (value-free IR scan)
```

`@test_noboxing` is where the distinction is proved. It reads AllocCheck's instances: a dynamic
dispatch, a boxing runtime call, a `Core.Box`, and a heap allocation of an isbits type, which is a
value boxed to be handed over as a reference (a `Float64` stored into a `Vector{Any}`). It adds the
dynamic calls in the bodies Julia's own compiler produces, because AllocCheck compiles every callee
for its inferred argument types and Julia does not: a function that only passes a `Function`
argument along is compiled once for `Function`, and calls through it at run time.

## `@assert_typestable` / `@test_typestable` — concrete, stable types

Three layers, graded differently. `@assert_typestable` insists the return type is concrete —
exact for the question it asks, so a violation **throws**. It also adds two IR signals, both
heuristics, so both only **warn**: internal dispatch hiding behind a concrete return, and a
union-typed local carrying a member that must be boxed to flow through it.

`@test_typestable` replaces the dispatch signal with `JET.@report_opt` and throws on it. It keeps
the union-typed-local signal as-is, because JET cannot see that class at all: union splitting is
not dynamic dispatch, so `@report_opt` is silent on it at every signature. Without it the proof
would be weaker than the scan it is meant to settle.

One JET report kind does **not** fail the guarantee: an optimization failure, which says a frame
produced no optimized IR (typically a recursive cycle). That is a statement about the optimizer, not
about types, so it is logged rather than failed. Because JET reads dispatch from optimized IR, such a
frame's own body cannot produce a dispatch report either — so that body is scanned directly, and a
runtime dispatch found there fails like any other.

### The finding names the declaration to edit

A failure identifies what to change, not just that the body is unstable: a captured variable in a
`Core.Box`, an untyped non-`const` global, an abstractly typed field, a container with an abstract
payload type, reflection, a type built from a runtime value, or more matching methods than inference
enumerates. The [dynamic dispatch](@ref dynamic-dispatch) guide lists each cause with the fix and its
measured effect, and [`dispatch_report`](@ref) shows where a module dispatches at run time — including
calls that are static today and one method away from dynamic.

### A union-typed local that boxes

A non-isbits union is a tagged pointer, so a member that normally lives unboxed has to be
heap-boxed to flow through it. Representation decides, not member count: an isbits member rides
the union's inline payload, and a mutable one is already a pointer, but an immutable struct
holding heap references — `SubArray`, `Adjoint`, `Transpose` — is boxed on the way in.

```julia
function through_union(A::AbstractMatrix{Float64}, take::Bool)
    local x = take ? view(A, :, 1:1) : A   # Union{SubArray, Matrix}: the SubArray boxes, the Matrix does not
    s = 0.0
    for i in eachindex(x)
        s += @inbounds x[i]
    end
    return s
 end
```

The return type here is `Float64` — concrete — so the first layer sees nothing. The box leaves no
`:new` and no allocating `foreigncall` in optimized IR, so the allocation scan sees nothing
either. Its only trace is the phi's own type.

This rides `:typestable` rather than `:noalloc` deliberately. "This local is union-typed with a
box-on-entry member" is a property of the code as written; whether the box survives is LLVM's
call and moves with inlining — the same function measures 16 B per call across a module boundary
and 0 B once it inlines into its caller. Reporting it as an allocation would red kernels LLVM
made free.

```@example guide
affine(x) = 2x + 1

@assert_typestable affine(3.0)
```

Runtime tuple indexing — the trap that keeps coming up — produces a `Union` return type and
boxes. It doesn't pass:

```julia
state = (1, 2.0, "three")     # heterogeneous tuple
component(s, i) = s[i]        # i is a runtime value → Union{Int,Float64,String}

@assert_typestable component(state, rand(1:3))
# ERROR: StrictViolation (@typestable): guarantee not satisfied
#   target:  component(state, rand(1:3))
#   reason:  return type is not concrete or isbits-union (inference): Union{Float64, Int64, String}
```

## Keyword calls and explicit signatures

Every guarantee macro accepts two extra forms, so you can point them straight at a real API
instead of an internal positional driver.

**Keyword arguments.** A keyword call is checked as written: StrictMode routes it through
`Core.kwcall`, so inference, AllocCheck and JET all see the keyword sorter's real specialization.
That holds under a `types = (…)` override too — the override pins the POSITIONAL types and the
kwcall wrapper is kept, so the analyzed signature stays the one the call actually reaches.

```julia
@assert_noalloc    trsm!(B, A; side='L', uplo='L', alpha=1.0)   # public kwarg entry point
@assert_typestable scale(x; by=2)
```

**`types = (…)` — pin the analyzed signature.** By default the signature comes from
`typeof.(args)`, so `typeof(Float64) == DataType`. For a *type-argument* function that becomes a
genuine false positive: over `Tuple{DataType, …}` the parameter `T` is unresolvable, and the
return type widens to non-concrete. Supply the real specialization explicitly:

```julia
tmp(::Type{T}, n) where {T} = Vector{T}(undef, n)

@assert_typestable tmp(Float64, 4)
# ERROR: StrictViolation (@typestable): return type is not concrete or isbits-union (inference): Vector

@assert_typestable tmp(Float64, 4) types=(Type{Float64}, Int)   # ok: real call-site specialization
```

`types = (…)` works on `@assert_noalloc`, `@strict`, `@kernel` and the rest the same way. It is
the escape hatch for whenever `typeof.(args)` doesn't name the specialization you actually run.

## `@assert_inlined` — keep the call on the fast path (best-effort)

[`@assert_inlined`](@ref) fails unless the compiler actually inlined the call. To find out,
StrictMode compiles a tiny wrapper around it and reads the optimized IR: if the call is still
sitting there as an `:invoke`, it wasn't absorbed, and the assert fails.

Inlining is a heuristic, not a promise — a failure only means the compiler chose not to inline
under the current settings, which may or may not matter. That's why it isn't part of
[`@strict`](@ref).

```julia
@inline   hot(x) = x * x + 1
@assert_inlined hot(3.0)        # ok: small, inlined

@noinline cold(x) = x * x + 1
@assert_inlined cold(3.0)
# ERROR: StrictViolation (@inlined): call to `cold` was not inlined — it survives as an `:invoke` …
```

## `@assert_trim_compatible` — static-binary (`juliac --trim`) compatibility

[`@assert_trim_compatible`](@ref) reports when `f(args...)` looks incompatible with
`juliac --trim=safe`, the static-binary build mode that rejects dynamic dispatch and reflection.
It is a value-free scan of the typed IR: unresolved dynamic calls, reflection, and calls left
unresolved by exceeding the union-split limit.

The authoritative answer is a different macro, not a different mode: `StrictModeTest`'s
`@test_trim_compatible` runs juliac's own `verify_typeinf_trim` over the exact signature and
**throws**, with deduplicated, source-mapped findings. Nothing switches based on which packages
happen to be loaded — the macro you wrote decides.

Like `@assert_inlined`, this is advisory and **opt-in** — *not* part of [`@strict`](@ref):
juliac's whole-program verifier over the real build is the final word. The reactive counterpart,
for a real build log, is [`explain_trim`](@ref).

```julia
clean(x::Int) = x * 2 + 1
@assert_trim_compatible clean(3)          # ok

reflecty(x::Int) = length(Base.return_types(sin, (Float64,)))   # reflection → trim-unsafe
@assert_trim_compatible reflecty(3)
# ┌ Warning: StrictViolation (@trim_compatible): likely trim-incompatible (static scan —
# │ `@test_trim_compatible` runs the authoritative juliac verifier):
# │   Base.indexed_iterate(…)::Any  [myfile.jl:NN]; … (+N more call site(s))
```

As an engine guarantee it is `:trim_compatible`:

```julia
findings(reflecty, (Int,); guarantees = (:trim_compatible,))     # report
test_signatures([(reflecty, (Int,))]; guarantees = (:trim_compatible,))   # prove (StrictModeTest)
```

### A trimmed build needs checks off

`--trim=safe` rejects any call it cannot resolve statically, and with checks **enabled** a guarded call
site reaches StrictMode's IR scan, which uses reflection. Measured: a consumer with one
`@strict dot3(a, b)` inside code the binary runs fails with **248 verifier errors**, traced from the
macro through `macros.jl` into the scan. With `checks_enabled = false` the same source builds and runs
— every macro expands to the bare call, so nothing of StrictMode is left to resolve.

So a package that ships a trimmed artifact sets the preference off in the environment it builds from:

```toml
# LocalPreferences.toml, next to the Project.toml you build with
[StrictMode]
checks_enabled = false
```

Both halves are gates in this repo's CI (`StrictMode/test/consumer`): the armed build proves the load
path and `@strict_function` declarations trim, and the shipping build proves an embedded call-site
macro leaves nothing behind. Per-call allocation is 0 bytes in **both** configurations — the check
runs once per site, not per call.

## `@strict` — the guarantees a hot path wants, together

[`@strict`](@ref) checks three things in order: type stability first (that's usually what's
behind a surprise allocation), then owned scratch, then allocation-freedom. It returns the
call's value, so you can drop it in around an expression you already have:

```@example guide
saxpy(a, x, y) = a .* x .+ y

result = @strict saxpy(2.0, (1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
```

Only the type-stability check throws; the other two warn. The owned-scratch rule flags *any*
runtime dictionary accessor — right when you name it yourself, too broad applied to every call
site — and the allocation check is a heuristic scan. Use [`@assert_owned`](@ref) for a hard gate
on owned scratch, and `StrictModeTest`'s `@test_noalloc` for a proof of allocation-freedom.

`@assert_noboxing` is not part of it: its rule is a strict subset of `@assert_noalloc`'s, so
including both would say the same thing twice.

### A `@strict` call allocates nothing

The checks run **once per call site and argument signature**, not on every execution. Measured on a
warm 64-element dot product:

```text
  bare call                          0 bytes
  @strict at the call site           0 bytes
  @strict_function on a definition   0 bytes
```

This holds for `@strict` alone. [`@kernel`](@ref) and the single-guarantee `@assert_*` macros still
check on every execution — per call, on the same fixture: `@assert_noalloc` 112 B,
`@assert_typestable` 208 B, `@kernel` ~583 KB.

This matters because the checks allocate while they run, and they run inside the *enclosing*
function. If they ran per call, `@allocated` — or `StrictModeTest.@test_noalloc` — pointed at that
function would measure the guard rather than the kernel it guards, and a package could not prove
its own hot paths allocation-free with checks on (issue #29).

`StrictModeTest` excludes the guard frame from its proofs too, so `@test_noalloc` and
`@test_typestable` pass on a guarded call whose kernel is clean — and still fail on one whose kernel
is not. Those two are what the reporter had to mark `@test_broken`, so a zero `@allocated` alone
would not have answered the issue.

Each half gets there differently:

- **Type stability** is a question inference already answers, via `Base.promote_op`. The result is
  a compile-time constant, so a stable call folds the test away and keeps no branch. This is the
  same mechanism [`@strict_stable`](@ref) uses.
- **The IR scans** cannot fold — they inspect compiled output, and Julia forbids code reflection
  inside a generated function (`Base.check_generated_context`). They sit behind a per-signature
  flag instead: one load and a compare on the warm path, the scan itself on a cold branch.

The flag carries Julia's world counter, so defining any method re-arms every site. A check can
never stay ticked against code that has since changed — a silent skip is the failure this package
exists to remove. The price is an occasional extra scan after a recompile, which the warm path
does not pay.

Use [`@strict_function`](@ref) when you want a definition checked at module load rather than at its
first call.

## `@strict_function` — verify a definition at load time

Put it on a definition and StrictMode checks that definition against its declared argument types,
at precompile or module-load time. A clean one loads like any other:

```@example guide
@strict_function scaled(a::Float64, x::NTuple{3, Float64}) = a .* x

scaled(2.0, (1.0, 2.0, 3.0))
```

A later edit that makes the return type non-concrete stops the module loading. An allocation only
**warns** here: this runs at your own package's precompile, where the proof is not loadable, and
a guess must not stop a consumer installing. `test_registered()` re-proves the same signature
from `test/`, and that one fails.

```julia
@strict_function maybe(x::Int) = x > 0 ? x : 1.0     # Union{Int,Float64} return
# ERROR: StrictViolation (@strict_function): return type is not concrete …

@strict_function leaky(n::Int) = sum(collect(1:n))   # collect allocates
# ┌ Warning: @strict_function leaky(Int64): allocates / boxes (value-free IR scan — a structural
# │ guess, not a proof; add StrictModeTest to your test environment and call test_registered()
# └ to resolve it)
```

### When the declaration names no concrete types

A generic declaration cannot be checked as written — inference has nothing to work with:

```@example guide
pick(t::Tuple, i::Int) = t[i]
Base.return_types(pick, Tuple{Tuple, Int})
```

`Any` — so verifying the declared signature directly would fail every generic function ever
written. That's why such a definition is skipped with a warning rather than checked. The same
function is answerable once you fix the tuple type, and the answer differs per instantiation:

```@example guide
[Base.return_types(pick, Tuple{T, Int}) for T in
    (NTuple{3, Float64}, Tuple{Int, Float64}, Tuple{Float64, String})]
```

Two ways to get an answer anyway, differing in who names the instantiations and when the verdict
forms.

**Name them yourself, still at load** — `signatures = [...]` verifies each listed instantiation
exactly as a concrete declaration is verified, so a violation still stops the module loading:

```julia
sigs = [(NTuple{3,Float64}, Int), (Tuple{Float64,String}, Int)]
@strict_function signatures = sigs pick(t::Tuple, i::Int) = t[i]
# the second entry infers Union{Float64,String}, so the module fails to load
```

**Or check whatever callers create** — [`@strict_stable`](@ref) moves the body into a hidden
inner function and has the public one infer its return type. That inference is a compile-time
constant, so a stable specialization compiles to exactly the code the unannotated definition
would, and an unstable one throws as it is compiled:

```@example guide
@strict_stable spick(t::Tuple, i::Int) = t[i]
spick((1.0, 2.0, 3.0), 2)      # stable: no check survives in the compiled code
```

```julia
spick((1.0, "a"), 2)           # Union{Float64,String}
# ERROR: StrictViolation (@typestable): return type is not concrete for this specialization …
```

The trade: `@strict_stable` forms its verdict per specialization rather than once at load, and
inference is not stable under an open world — a definition that loaded clean can begin to throw
after unrelated code changes what inference can prove. Reach for `signatures` when the contract
is a fixed set of types you own; reach for `@strict_stable` for an entry point whose callers
pick the types. Only type stability travels this way: allocation and vectorization are read from
compiled output.

## Interfaces + performance with TypeContracts

When you define an interface (an abstract type with a required set of methods), you can also
require that every implementation of it is fast. [`@strict_contract`](@ref) declares the
interface with performance guarantees attached, and [`@verify_strict`](@ref) checks both sides:
that an implementation has the right methods, and that those methods are fast.

```@example guide
using TypeContracts

@strict_contract AbstractMetric begin
    score(::Self, xs::AbstractVector{<:Real})::Real
end
function score end

struct PeakMetric end
score(::PeakMetric, xs::AbstractVector{<:Real}) = @inbounds xs[begin]

m = PeakMetric()
xs = [1.5, 2.5, 3.5]
@verify_strict PeakMetric begin
    score(m, xs)
end
```

A line may name the argument types instead of passing values, which needs no instance. Write
every positional argument as `::T` and every keyword as `name::T`; keywords may come in any order,
and one left out takes its default:

```@example guide
@verify_strict PeakMetric begin
    score(::PeakMetric, ::Vector{Float64})
end
```

An implementation that has the right methods but allocates is reported:

```julia
struct SlowMetric end
score(::SlowMetric, xs::AbstractVector{<:Real}) = sum(collect(xs))   # allocates

@verify_strict SlowMetric begin
    score(SlowMetric(), [1.0, 2.0, 3.0])
end
# ┌ Warning: StrictViolation (@noalloc): guarantee not satisfied …
```

## Static ownership — one method per type, not a lookup table

When each type needs its own value — a workspace, a unit, a scratch buffer — write one method
per type instead of keying a dict by the type:

```julia
# lookup table: a probe on every call
const UNITS = Dict{Type, Any}(Int => 1, Float64 => 1.0)
unit(::Type{T}) where {T} = UNITS[T]

# Static ownership: one method per type
unit(::Type{Int})     = 1
unit(::Type{Float64}) = 1.0
```

Both are called the same way, `unit(Float64)`. What differs is **when the answer is found**:

```text
  unit(Float64)                      unit(Float64)
  one method per type                dict keyed by type
       │                                  │
  ┌────┴──────────────┐             ┌─────┴──────────────┐
  │ COMPILE TIME      │             │ EVERY CALL         │
  │ Julia picks the   │             │ hash the type      │
  │ method, inlines   │             │ probe the table    │
  │ the constant      │             │ return, typed Any  │
  └────┬──────────────┘             └─────┬──────────────┘
       ↓                                  ↓
  the call is gone                   ~130 ns, every time
```

Julia cannot skip the dict probe: the type is an ordinary value at runtime, and a mutable
dict's contents are not knowable while compiling. Base works the method way — `one(::Type{T})`
was never going to be a dict.

The idea comes from a Linux-kernel principle: *data has a clear static owner, reached through
that owner — never a global registry*. In real code the owned value is usually a workspace:

```julia
const _WS_F64 = Workspace{Float64}()
const _WS_F32 = Workspace{Float32}()
_ws(::Type{Float64}) = _WS_F64
_ws(::Type{Float32}) = _WS_F32

# the anti-pattern it replaces
const _WS = IdDict{Type, Any}()
_ws(::Type{T}) where {T} = get!(() -> Workspace{T}(), _WS, T)
```

**Why no other check catches it.** A warm dict hit allocates nothing (measured: 0 bytes). Narrow
its result — a type assert, or a concretely-typed dict — and `@assert_typestable`,
`@assert_noalloc` and `@assert_noboxing` all pass. The cost is pure latency, about **130 ns**
per call, so only a benchmark or a structural lint finds it.

It hides from IR inspection too: when `T` is a static parameter the optimizer folds `get!` into
raw `jl_eqtable_*` foreigncalls, so the recognizable pattern is gone from optimized IR. That's
why [`static_ownership_suggestions`](@ref) reads **unoptimized** typed IR instead.

**Why `juliac --trim` needs it.** A static build keeps only calls it can resolve to a concrete
method while compiling. One method per type resolves trivially — one callee, a `const` body,
inlined away. A dict lookup does not: the trimmer can see which `get!` runs, but never what
comes out of the table, because that association lives in mutable memory rather than in the type
system.

Allocation splits the same way: the dict allocates on first miss, so an all-paths proof sees a
reachable allocation forever, even though steady state is clean. The `const` owner allocates
once at module load, leaving the hot path provably allocation-free with no exemptions.

**Why it is advice, not a proof.** A `Dict` is sometimes the right tool — a config table parsed
once, an open-ended memo cache. The idiom's own escape hatch is a `Dict` fallback for a
rare-type tail (Example 2 below), which is itself a runtime lookup. A hard gate swept over a
whole package would break the build on the fallback the idiom recommends.

**Two tools, for two different jobs.** StrictMode gives you a precise tool and a broad one, and
they don't overlap in scope (different guarantee names, no shared registry entry):

| | [`@assert_owned`](@ref) | [`static_ownership_suggestions`](@ref) |
|---|---|---|
| Use it to… | pin a **specific, known-hot** call and guard it forever | **discover** every occurrence across a whole package |
| Failure mode | hard `StrictViolation` — breaks the build | `status = :info` — never a failure, `nfailures` ignores it |
| Where it runs | one call site you write by hand, like [`@assert_inlined`](@ref) | `audit(MyPkg; static_ownership_suggest = true)`, a whole-module/whole-registry sweep |

Use `@assert_owned` the way you'd use `@assert_inlined`: on a call you've already identified as
hot and want a permanent regression guard on. Use `static_ownership_suggestions` (or
`audit(...; static_ownership_suggest = true)`) when you don't yet know where the pattern shows
up and want a package-wide pass that can't break anything while you look — the same relationship
[`inline_suggestions`](@ref) has to `@assert_inlined`.

**Why `@assert_owned` isn't swept in by default.** `@strict f(x)` does run it on the call you
named, but as a warning. Keep the *throwing* form scoped to calls you assert by hand; don't add
it to `register_strict!`'s guarantee list or a `@strict module`'s default set. The sanctioned
escape hatch — a `Dict` fallback for a rare-type tail that doesn't earn its own `const` — is
*also* a runtime dict lookup, and a broad sweep would flag (and, since `@assert_owned`
hard-fails, break the build on) it. A narrow, opt-in `@assert_owned` on known-hot calls avoids
that; the advisory sweep is built for the "show me everywhere, break nothing" case.

### Example 1 — the anti-pattern, caught both ways

```@example guide
struct Workspace{T} end
const _WS = IdDict{Type, Any}()
_ws(::Type{T}) where {T} = get!(() -> Workspace{T}(), _WS, T)

only(static_ownership_suggestions(_ws, (Type{Float64},)))    # advisory: an :info finding, not a throw
```

```julia
@assert_owned _ws(Float64) types = (Type{Float64},)
# ERROR: StrictViolation (@owned): guarantee not satisfied
#   target:  _ws(Float64)
#   reason:  hot path resolves a runtime AbstractDict lookup (static-ownership violation): …
```

The dispatch fix satisfies both — `@assert_owned` passes, and the advisory sweep has nothing
left to say:

```@example guide
const _WS_F64 = Workspace{Float64}()
const _WS_F32 = Workspace{Float32}()
_ws2(::Type{Float64}) = _WS_F64
_ws2(::Type{Float32}) = _WS_F32

@assert_owned _ws2(Float64) types = (Type{Float64},)   # passes: dispatch, no lookup
```

```@example guide
static_ownership_suggestions(_ws2, (Type{Float64},))   # empty: nothing left to suggest
```

### Example 2 — whole-package discovery, and the sanctioned fallback

The realistic shape combines dispatch for the hot types with a `Dict` fallback for a rare-type
tail. That's the case `@assert_owned` would break the build on if swept broadly, and the case
the advisory sweep is built to surface without breaking anything:

```@example guide
module Workspaces
    using StrictMode
    struct Ws{T} end
    const WS_F64 = Ws{Float64}()
    const WS_F32 = Ws{Float32}()
    const WS_FALLBACK = IdDict{Type, Any}()
    get_ws(::Type{Float64}) = WS_F64      # hot path: dispatch, no lookup
    get_ws(::Type{Float32}) = WS_F32      # hot path: dispatch, no lookup
    get_ws(::Type{T}) where {T} = get!(() -> Ws{T}(), WS_FALLBACK, T)   # rare types, off the hot path
end

Workspaces.get_ws(Float64)
Workspaces.get_ws(BigFloat)   # exercises the sanctioned fallback

fs = audit(Workspaces; static_ownership_suggest = true)
nfailures(fs)   # 0 — only the fallback is flagged, and an advisory finding never fails a sweep
```

### Example 3 — real packages doing this

This isn't a StrictMode-specific idiom; it's how Julia packages that care already solve the
"per-type registry" problem.

**TypeContracts.jl** — a separate interface-contract package. The obvious design for
`@contract AbstractShape begin ... end` is a global `Dict{Type,ContractSpec}` mutated by the
macro and queried by the checker. TypeContracts deliberately has no mutable registry at all:
`@contract I` instead *emits methods* —

```julia
@generated function TypeContracts.interface_trait(::Type{I}, ::Type{T}) where {T}
    return TypeContracts._build_trait_expr(I, T, arg_lists, fns)   # contract data baked in at macro-expansion time
end
```

— plus a `_contract_specs(::Type{I})` method holding the spec. The generic fallback,
`interface_trait(::Type{I}, ::Type{T}) where {I,T} = NotImplemented{I}()`, makes "not
registered" a dispatch outcome too, not a `haskey` branch. The payoff: method definitions
serialize into the precompile cache and survive package reloads (a dict would be wiped, needing
an `__init__` re-registration step); there are no world-age problems; and `interface_trait` is
`juliac --trim`-safe because there is no runtime registry lookup for the trimmer to fail to
prove — just ordinary, statically-resolvable methods.

**Julia Base — `IteratorSize`/`IteratorEltype`** (`base/generator.jl`). A textbook per-type
trait registry, shipped as pure dispatch:

```julia
IteratorSize(x) = IteratorSize(typeof(x))
IteratorSize(::Type) = HasLength()                                 # default
IteratorSize(::Type{<:Tuple}) = HasLength()
IteratorSize(::Type{<:AbstractArray{<:Any, N}}) where {N} = HasShape{N}()
```

Packages "register" by defining their own `Base.IteratorSize(::Type{MyIter}) = HasShape{2}()`
method rather than inserting into a table. `IteratorSize(Vector{Int})` const-folds to
`HasShape{1}()`, and `collect`'s dispatch on it specializes completely; a `Dict{Type,...}`
version would put an eqtable probe inside every `collect` call and be opaque to inference.

One caveat so the idiom isn't over-applied: dispatch-per-type means one compiled specialization
per type. For a handful of known-hot types that's the whole point; for an unbounded, genuinely
dynamic key population it's compile-time and method-table bloat instead — the honest answer
there is a `Dict`, or the hybrid fallback shape in Example 2. Static ownership isn't "never use
a `Dict`" — it's "the hot, statically-known associations belong in the method table, where the
compiler can see them."

### Dev-time feedback: `steady_state_report`

`@test_steady_state` gates in the test suite. For the same property while you are editing, there is
a report:

```julia
ws = Workspace()
steady_state_report(solve!, ws, A, b)                  # SteadyStateReport: steady
steady_state_report(scratch, ws; fresh_task = true)    # a per-task initializer shows up here
```

It returns what it measured and never raises. Like [`memsafe_report`](@ref) it takes **values** and
runs the call, so it sits outside the value-free `findings`/`audit` pipeline and does not belong at
a `src` call site — put it in a probe, a dogfood block, or a REPL session.

There is deliberately no `@assert_steady_state`. Every `@assert_*` macro is a call-site annotation
backed by the value-free scan, and this property cannot be settled that way: it needs real argument
values and has to run the call twice, which at a `src` call site would mean real work on every
call.

A `steady` report covers the calls that ran, so choose the shapes you measure the way you would
choose benchmark sizes — a later call with a larger problem allocates again and is outside what the
measurement says.

**A positive figure is checked against a control before it is believed.** `@allocated` counts
allocation for the whole **process**, not for the measured call, so a task running beside the
measurement is charged to the kernel. Measured here: one task allocating in a loop put 2,120 bytes
— and over a 2 ms window, 3 MB — onto a call that allocates nothing. So whenever the figure is
positive, an allocation-free window of the same duration is measured too; anything *it* records was
allocated by something else, and the verdict is then `inconclusive` rather than a count:

```julia
r = steady_state_report(solve!, ws, A, b)
StrictMode.steady(r)         # allocated nothing
StrictMode.inconclusive(r)   # something else in the process was allocating; nothing is attributable
```

`@test_steady_state` **fails** on an inconclusive measurement: "could not measure" and "is fine"
must never read alike. A zero needs no control — another task's allocation can only add to the
figure, so `steady` is trustworthy however busy the session is. Julia has no per-task allocation
counter, so a quiet process is the only way to get an attributable positive number.

## `@test_no_gc_pause` — no collection runs while the call does

Allocation-freedom is necessary and not sufficient. Julia's collector stops the world: when any
thread triggers a collection, every other thread is paused at its next safepoint, however clean its
own code is. So a kernel that `@test_noalloc` proves allocates nothing is still stopped by an
allocating neighbor, and no analysis of the kernel can see why — the cause is not in the kernel.

Measured, because there is nothing else to do. The call is warmed, then run `samples` times, and
the collector's own counters say whether a collection landed inside a call.

```julia
@test_no_gc_pause gemm!(C, A, B)                                   # no collection in the window
@test_no_gc_pause gemm!(C, A, B) samples = 2000 max_q99_ms = 1.0   # and a tail-latency budget

gc_pause_report(gemm!, C, A, B)                                 # the full distribution, never raises
```

`max_collections = 0` is the default, because that is what the name asserts. `max_q99_ms` adds a
latency budget on top; leave it unset and only the collection count is gated, which is the half
that does not depend on the machine.

### What the report shows

The verdict alone cannot be acted on, so [`GcPauseReport`](@ref) carries the per-call distribution
— median, q99, max, and how many calls ran more than `slow_factor` times the median. An uninterrupted region
has a q99 close to its median; a region interrupted by collections has a long tail, and that shape
is the signal.

`process_bytes` is the allocation recorded while the worst call ran, in the **whole process**.
Julia's allocation counters are global, so a thread the call never touches contributes to them.
That is deliberate here — it sizes the pressure the rest of the process put on the collector — but
it is not the call's own allocation. Neither is `@allocated`, which reports a neighbor's bytes too;
`@test_noalloc` is what answers that question, because it reads the code rather than a counter.

### What it cannot promise

It covers the calls that ran, in the process they ran in, under whatever else that process was
doing. A run with no pauses on an idle machine says nothing about a busy one, so measure under the load
the kernel will actually meet. It also cannot cover a thread that stayed idle during the window.

A *static* proof that every thread is allocation-free inside a declared window is not reachable
from a package: it would need the whole program, and Julia has no construct that names such a
window. This gates a measurement of it instead, and says so.

## `test_layers` — a declared direction of dependency

Julia has no orphan rule, and should not: extending `Base.show` for your own type is how the
ecosystem composes. What the language cannot know is a project's intended **direction of
dependency** — that the kernel layer must not reach up into the application layer, that two sibling
layers must not extend each other. Declare it and `StrictModeTest.test_layers` checks it.

```julia
test_layers(
    App    => (Engine, Kernel),
    Engine => (Kernel,),
    Kernel => (),
)
```

Two independent rules. **Extension follows the declaration**: a method may only extend a function
owned by a layer its own layer declared. **No layer reads another layer's implementation**: a
qualified access to a name the owning layer does not mark `public` or `export` is a violation
whichever way the declaration points, because a public name is the interface and anything else
cannot be changed without breaking the reader.

Only the declared modules are judged, and that is what keeps the check usable. Measured on
StrictMode itself, the underlying analysis returns 66 improper accesses — essentially all of them
deliberate reads of `Base` and `Core` internals that this package exists to perform. None is a
layer violation, because `Base` and `Core` are not layers. For that wider question use
`ExplicitImports.check_all_qualified_accesses_are_public` and its siblings directly; the access
half here reuses that package rather than re-implementing it.

A module absent from the graph is not judged, so the graph is also the opt-in, and a submodule
answers to the layer it sits beneath.

## `test_no_unsafe` — a fence a module declares

Rust spells this `#![forbid(unsafe_code)]`. Julia cannot: `ccall` and `unsafe_load` are ordinary
calls any module may make, and the language is right not to forbid them. So a module that must stay
inside the guarantees declares it, and the scan reports every method that leaves them.

```julia
unsafe_report(MyKernels)                             # the escapes, as findings
test_no_unsafe(MyKernels)                            # …and fail if there are any
test_no_unsafe(MyKernels; allow = (:unsafe_load,))   # one reviewed read, the rest held
```

It looks for `ccall`, `@cfunction`, `pointer`, any function whose name begins with `unsafe_`, the
pointer intrinsics (`pointerref`, `pointerset`), `llvmcall`, `cglobal`, the C allocator
(`Libc.malloc`, `Libc.free`), a pointer made from an integer (`Ptr{T}(addr)`), and a `memoryrefnew`
or `getfield` whose bounds check is a literal `false`. A function counts wherever the method names
it: `map(unsafe_load, ps)`, `unsafe_load.(ps)`, a splat, a keyword call and a local alias are
reported like the plain call. [`unsafe_report`](@ref) lists each construct with the name `allow`
takes.

`allow` is per construct, so excusing a pointer read still holds a `ccall` elsewhere — a deliberate
escape ends up recorded where the policy is written rather than silently tolerated. An `allow` entry
that names no construct raises, listing the accepted names.

### Why it reads unoptimized IR

An `@inline` helper around a pointer load inlines into its caller. Measured on exactly that shape: a
scan of **optimized** IR finds the pointer load in the innocent caller's body, so it would report a
method that contains no unsafe code of its own while the method that actually wrote it looks clean.
The unoptimized scan names the helper. The same reasoning governs
[`@assert_trusted`](@ref) and the static-ownership sweep.

A `ccall` lowers its arguments through `cconvert` and `unsafe_convert`. Those *are* the `ccall`, not
two further things to fix, so they are suppressed beside it.

### `@inbounds`

Reported as `:inbounds`. It is the one construct in this scan that trades a thrown `BoundsError` for
silent undefined behavior, so a module declaring itself free of unsafe code wants it named.

It leaves no statement in lowered or typed IR — it is carried in the per-statement `ssaflags` — so it
is read from there rather than from the statement list. An explicit `@inbounds` sets the flag; a
plain index, `@simd`, `@fastmath`, `@boundscheck`, a comprehension and a broadcast do not.

A `Base.@propagate_inbounds` method is clean on its own, and the finding lands on the caller that
wrote `@inbounds` — the method that made the claim is the method that answers for it.

```julia
unsafe_report(MyKernels; allow = (:inbounds,))   # the annotations are proved and tested
```

Use that `allow` only where the in-range property holds for a reason you can state, and the suite
runs under `--check-bounds=yes` so every annotation is neutralized and a stray index raises.

## `test_latency` — the time paid before the call runs

Every guarantee above is about the code a call runs. Load time, and the compile tax on the first
call of a signature, are paid before that — and both are properties of a **cold process**, so a
warmed session cannot measure them and nothing in typed IR predicts them.

```julia
latency_report(:MyPkg; calls = ["MyPkg.solve!(ws, b)"])     # measure, never raises
test_latency(:MyPkg; max_load_ms = 400)                     # a pinned host, a real budget
```

The measurement runs in a child that inherits the active project, so what it reports is the
environment under test. The precompile cache is built first by default, since a load time that
halves on a rerun is not a budget.

**Both budgets are opt-in.** A wall-clock threshold depends on the machine: the same package loads
at different speeds on a laptop, a shared runner and a pinned host, so a default would fail honest
code on a slow box and pass a regression on a fast one. With no budget given, `test_latency`
measures and returns — use it that way to record the numbers before choosing them.

### The cause, when the numbers move

`test_latency` measures what a user of *your* package feels. **Invalidations are paid by downstream
code**: your package can load quickly and still discard precompiled `Base` or dependency code that
a consumer then rebuilds, and no measurement of your package alone can see that.

That probe lives in `StrictMode/bench/invalidations.jl` rather than in `StrictModeTest`:

```console
julia --project=bench bench/invalidations.jl        # report
julia --project=bench bench/invalidations.jl 20     # …and exit non-zero above 20
```

It is a script and not a gate because the analysis needs SnoopCompile, which pulls in 61 packages —
nearly all of them for flame graphs and LLVM snooping that this never calls. Julia cannot load part
of a package, so making it a `StrictModeTest` dependency would put all 61 in every consumer's test
environment. Copy the script into your own `bench/` environment to run it on your package.

Run on StrictMode it reports **11** invalidations, attributed to inserting
`Dates.is_valid_toml_value` — a stdlib interaction reached through `TOML`, not StrictMode's own
code. That attribution is the point: a count alone tells you something regressed, and the tree tells
you where to look.

## `@assert_memsafe` — deterministic out-of-bounds detection

[`@assert_memsafe`](@ref) catches an out-of-bounds array read or write
in an unsafe hand-vectorized kernel *deterministically*, instead of the way these bugs usually
surface — flakily, once in a long benchmark run, only when the next page happens to be unmapped.

The motivating shape: a masked SIMD load reads a full lane width at a tile pointer, up to `W-1`
elements past a partial-row tile's valid region — via a raw pointer (`unsafe_load`, a
`VecElement`/LLVM-intrinsic vector load, or equivalent), not `getindex`. That kernel is
type-stable, allocation-free, and `--trim`-tolerated; every other guarantee in this package
passes it, because none of them model runtime memory addresses. A benchmark on ordinary heap
arrays (whose trailing page happens to be mapped) may never trip it at all.

```julia
function masked_load_kernel!(out::Vector{Float64}, a::Vector{Float64})
    n = length(a)
    p = pointer(a)
    @inbounds for i in 1:n
        out[i] = a[i] + unsafe_load(p, i + 1)   # raw-pointer read one element past `a`'s end
    end
    return nothing
end

@assert_memsafe masked_load_kernel!(zeros(8), rand(8))
# ERROR: StrictViolation (@memsafe): guarantee not satisfied
#   reason:  deterministic out-of-bounds access — the guarded probe subprocess was killed by
#            SIGSEGV. Child's own signal report (names the faulting op): …
```

**Why not just `julia --check-bounds=yes`?** Use it when you can — for a plain `@inbounds a[i]`
overrun it turns the bug into a catchable `BoundsError`, and a `@test_throws BoundsError` under
that flag beats this whole harness.

It cannot help here: the flag re-enables the bounds branch inside `getindex`/`setindex!`/
`checkbounds` lowering, and `unsafe_load`, `unsafe_store!`, raw `Ptr` arithmetic and SIMD vector
loads never go through `checkbounds` at all, so it has no effect on them. (Checked at the
`@code_llvm` level: `getindex` compiles a bounds branch, `unsafe_load` compiles none.) That's
the access pattern the bug above uses — the reason `@assert_memsafe` is a separate tool rather
than a wrapper around a flag.

How it works:

- `Array` arguments are copied into `mmap` buffers that end flush against a `PROT_NONE` guard
  page, so a one-element overrun faults on **every** run — not only when the allocator happens
  to leave the next page unmapped.
- The probe runs in a subprocess, the only way to catch an out-of-bounds **read**: that is a
  fatal fault and cannot be caught in-process.
- A **poisoned canary** classifies writes. The bytes past the data carry a per-buffer,
  position-dependent pattern, read back before the child touches the guard page, so a store past
  the end is reported at its exact offset. This is needed because a write fault destroys its own
  backtrace (`unknown function (ip: …)`, zero frames).
- Arguments holding the same array share one guarded buffer, so a kernel with an
  aliasing-dependent path sees the aliasing it was called with.

There is no in-process mode: an in-process probe can only use the canary, and a load past the
end disturbs no canary, so its clean verdict would be indistinguishable from no overrun at all —
in exactly the case this harness exists for.

See [`memsafe_report`](@ref)'s docstring for the full scope (`Array`
arguments only, end-of-buffer overruns only — no interior or underrun detection). Arguments the
harness cannot guard — a `view`, an `Adjoint`, a struct carrying arrays in its fields — are
listed in the report's `unguarded` field, so a clean verdict over a partially covered call does
not read like a clean verdict over a fully covered one; [`@assert_memsafe`](@ref) rejects the
ones the caller can materialize outright.

## `@assert_trusted` — check data from outside before using it

Data from a socket, a file, `ARGS`, or a device has not been checked by anyone yet. The bug this
prevents is a length field read *from* that data and then used as an index.

Wrap it where it arrives, in [`Untrusted`](@ref):

```julia
frame = Untrusted(read(sock, n))
```

That changes its type, so nothing written for `Vector{UInt8}` accepts it. `sum(frame)` and
`frame[1]` are `MethodError`s; `frame.x` throws. You can pass it around, and that is all.
Wrapping costs nothing — same layout as the payload, no allocation — and the type is still there
in a shipped build.

One function opens it, and its name says so:

```julia
function parse_header(u::Untrusted{Vector{UInt8}})
    b = unsafe_trust(u)                          # the one way through
    length(b) >= 4 || throw(ArgumentError("short header"))
    n = Int(b[1]) | Int(b[2]) << 8
    n <= length(b) - 2 || throw(ArgumentError("length field exceeds buffer"))
    return Header(n, copy(@view b[3:2+n]))       # copy: the caller still owns that buffer
end
trust_boundary!(parse_header)                    # this function is allowed to do that
```

[`@assert_trusted`](@ref) then fails on any *other* function that reads a payload:

```julia
peek(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))

@assert_trusted peek(frame)
# ERROR: StrictViolation (@trusted): guarantee not satisfied
#   reason:  reads an `Untrusted` payload outside a trust boundary (unsafe_trust) — 1 site(s)
```

One wrapper, one door, one place to get it right:

```text
   read(sock, n)          parse_header              the rest of your code
        │                       │                            │
  ┌─────┴──────┐      ┌─────────┴──────────┐       ┌─────────┴─────────┐
  │  Untrusted │ ───▶ │ unsafe_trust, then │ ────▶ │   plain values    │
  │  {Vector}  │      │  check, then copy  │       │  safe to index    │
  └────────────┘      └────────────────────┘       └───────────────────┘
   nothing works        the one function            everything works
   on it out here       allowed to open it
```

Two limits, both real.

**The type does most of the work on its own.** An `Untrusted{T}` matches no method written for
`T`, in a shipped build as much as in tests. The check only covers the deliberate way out:
`unsafe_trust` and `getfield` can be called from anywhere, and no type design in Julia can stop
that.

**Registering a boundary is a promise, not a proof.** Nothing verifies that `parse_header`
really checks what it read, or that it copied instead of handing back the caller's buffer. Both
matter, and both are on you.

The idea is the Linux kernel's `__user` annotation: a pointer from userspace gets its own type,
`copy_from_user` is the crossing that checks and copies, and `__force` is the one cast around
it. The kernel's marker disappears unless a separate checker is run, which is why it so often
isn't. `Untrusted` is a real type, so it holds either way.

## `@assert_noescape` — a handle that must not leave its scope

Some values are valid only inside the frame that obtained them: a borrow from an arena, a pointer
into a slab, a token for a held lock. If one leaves, the result is a use-after-free rather than a
slow path. The compiler's own escape analysis answers this question, and `:noescape` is how to ask
it.

Declare the type, then assert the function:

```julia
register_scoped!(ArenaHandle)

@assert_noescape compute!(arena, A, b)     # passes: the handle stays inside
@assert_noescape leak(arena)               # fails: it is returned
```

Nothing is registered by default, so the guarantee passes trivially until a type is declared
scoped. The finding names the type that left.

### What it can decide

Only a handle CREATED in the frame carries a verdict. The escape state of a value returned by a
call is assumed rather than computed — the analysis treats an uncached callee as escaping its
arguments — so a handle from a producer that did not inline reads as escaping whatever it does.
Reporting that as an escape would be a false positive, and reporting it as clean would be worse, so
it is reported as undecided, naming the fix: mark the producer `@inline`, or assert the guarantee
where the handle is created. An `@inline` accessor, the usual shape for a borrow, gives a real
verdict.

### What it covers, and the half it does not

It catches the value **leaving the frame** — returned, stored to a global or a field, or captured
by a closure. All three are escapes and all three are reported.

It does **not** catch a handle that stays inside the frame and is used after its scope has ended.
That is not an escape, and the analysis will correctly call it clean. Rejecting that needs a
syntactic check at macro-expansion time, where the end of the block is visible. The two cover
different halves and neither subsumes the other, so a package with a scope macro should keep both.

### Why registration is by type

Registration names the handle's **type**, not the function that produces it. The escape analysis
has to run on IR after inlining to mean anything, and a small `borrow!` inlines into its caller,
taking the callee boundary with it. The type survives that; the boundary does not.

### Why it reports rather than gates

It cannot see through a callee it did not analyze, and that limit has a measured consequence. A
handle wrapped in a `view` reads as not-provably-confined **even when the view is never used**: the
wrapper is scalar-replaced out of existence, while the handle it was built from stays marked
unconfined, so a frame that leaks a view and a frame that merely takes one are indistinguishable.
Neither direction of the analysis separates them — assuming callees are clean misses the real leak
instead.

Wrapping a borrow before use is ordinary, so gating on that verdict would fail correct code in the
shape this exists for. It reports instead, and has no proving counterpart: treat a failure as a
lead to check by hand, not as a fact. What it answers soundly is a BARE handle — created in the
frame, used there, not wrapped — and for that the verdict is trustworthy in both directions.

## `@assert_noalias` — a written argument must not overlap a read one

A kernel that writes one argument while reading another is written on the assumption that the two
are distinct. When they overlap, the answer depends on the order the elements happen to be visited,
so the same call can give a different result under another loop order, another blocking, or another
Julia version. `LinearAlgebra.mul!` states this as a documented precondition; most hand-written
kernels carry it silently.

```julia
A = rand(8, 8); C = similar(A)

@assert_noalias mul!(C, A, A)              # ok: A may alias itself, only C is written
@assert_noalias mul!(A, A, A)              # fails: the destination is also an input
@assert_noalias mul!(C, A, view(C, :, 1))  # fails: the view reads what C writes

@assert_noalias mutates=(1, 2) swap!(x, y) # neither the name nor one position is enough
```

### It reads values, not a signature

This is the only check here that does. Whether two arrays overlap is a property of the arrays, not
of their types, so there is nothing for the value-free engine to answer. `:noalias` is therefore
absent from [`StrictMode.guarantee_names`](@ref): it cannot be swept by [`audit`](@ref) or declared
on a [`@strict_function`](@ref), and a declaration naming it is rejected rather than silently
skipped.

The oracle is `Base.mightalias` — Julia's own predicate, the one `Base.unalias` uses to decide
whether to copy. It resolves wrappers to the memory underneath, so a `view`, a `reshape` and a
`reinterpret` of a buffer are all compared against the buffer rather than by wrapper type. Disjoint
slices of one workspace are accepted, which matters: a blocked kernel carving tiles out of shared
scratch is the normal case, and a predicate that compared only the parent would reject every one of
them.

`Base.mightalias` reads `Base.dataids`, which an array type has to define. A wrapper struct around
a `Vector` that defines none answers with its own identity, and never matches the vector it holds.
So an array type without a `dataids` method, and an argument that is not an array at all (a
workspace struct, a factorization, a closure), is read through its fields, three levels down, and compared by
the buffers found there.

An array type built on a pointer (a plain-data struct whose one `Ptr{T}` field for its `T`
elements, or whose only `Ptr` field, holds its data) is compared by where its elements lie.
`Base.mightalias` answers `false` for every plain-data array, and a view names its parent's start
as its data, so neither can say whether such an array and a view overlap. The layout can, and the
type states it the way Julia's strided-array interface asks: by defining `Base.strides`. With it,
the pointer, the size and the strides place every element, and a view of the array with range
indices is placed the same way. A vector, a strided vector and a matrix with contiguous columns
are compared element by element, so two submatrices with a leading dimension whose spans
interleave are told apart; any other layout is compared by its span. The type's other fields — a
library handle, the vector that keeps the memory alive — are not memory it covers, so two arrays
that share one share no element.

```julia
struct PtrMat <: AbstractMatrix{Float64}
    p::Ptr{Float64}; m::Int; n::Int; ld::Int
end
Base.strides(a::PtrMat) = (1, a.ld)   # without this, only where the elements start is known
```

Two arrays that overlap raise. An overlap with a buffer held in a field of a non-array argument
warns: the memory is shared, but nothing says the kernel reads that field.

What cannot be placed exactly, and may meet the other argument's memory, warns that the arguments
may share memory, and never raises. That covers an array built on a pointer with no
`Base.strides`, placed only within the allocation its pointer points into (any other such array,
or any array whose layout is known but whose allocation is not, may be in the same one); a view
whose indices are not ranges, placed within its parent; a layout compared by its span; and a raw
pointer that is not an array's data, such as a field of a struct that is not an array, which says
where memory starts and not how far it reaches. Such a pointer is reported when it equals another
pointer or points into memory another argument reaches.

### Which arguments count as written

From the name: a trailing `!` means argument 1, Julia's convention. A number in that position is
not taken for the written argument when the call also takes an array: `scale!(2.0, v)` and
`scale!(big(2.0), v)` are both rejected until `mutates` names the position. Anything else must say so with
`mutates = (…)`. A call that gives neither, or an empty `mutates`, is **rejected**, not passed — "nothing is written" would
compare no pair and accept every call, and a check that cannot fail is worse than no check. Where
the callee is written as a plain name the rejection happens at macro expansion, before the call
runs.

The convention is not the whole truth: `ldiv!(F, B)` writes its second argument, and `axpy!(a, x, y)`
its third. A written position that holds no memory — the scalar `a` — compares nothing, so that call
raises an `ArgumentError` asking for `mutates = (3,)` in place of passing. For a two-argument call
the default still compares the right pair, since there is only one.

### What it cannot promise

Overlap is checked for the call that runs, not for every call the method could receive. So this
narrows the property one site at a time; it does not prove it once for all callers. Rust decides
the same question at compile time for every caller, through borrow checking. Julia has no construct
that can, which is why this is a run-time assertion that compiles away rather than a static
guarantee — and why [`@assert_noescape`](@ref), which answers the *confinement* half of the same
question, is a separate check.

A call that satisfies the assertion allocates nothing and costs about 2 ns per pair, so it is
affordable on a hot path. At a call site whose arguments infer to `Any` — a non-`const` global —
the argument tuple is heap-allocated by the call itself, before any check sees it.

## `@assert_concurrency_safe` — a shared argument the call must not write

A plan, a table of coefficients or a workspace description is often built once and handed to many
tasks. That is safe only while no call writes it. [`@assert_concurrency_safe`](@ref) checks one
call for a write to its shared argument, to anything reached through that argument, or to a
mutable `const` global. The shared argument is the first unless you say otherwise. Arguments the
call is meant to write, such as the output or a scratch buffer each task owns, are not checked.

```@example guide
struct FilterPlan
    taps::Vector{Float64}
end

function apply_filter!(plan::FilterPlan, x::Vector{Float64})
    for i in eachindex(x, plan.taps)
        x[i] *= plan.taps[i]            # reads the plan, writes only x
    end
    return x
end

@assert_concurrency_safe apply_filter!(FilterPlan(ones(4)), ones(4))
```

A plan that records something about each call is the usual way to break it:

```julia
mutable struct CountingPlan
    taps::Vector{Float64}
    calls::Int
end

function apply_counted!(plan::CountingPlan, x::Vector{Float64})
    plan.calls += 1                     # every task sharing the plan writes this field
    for i in eachindex(x, plan.taps)
        x[i] *= plan.taps[i]
    end
    return x
end

@assert_concurrency_safe apply_counted!(CountingPlan(ones(4), 0), ones(4))
# ERROR: StrictViolation (@concurrency_safe): guarantee not satisfied
#   target:  apply_counted!(CountingPlan(ones(4), 0), ones(4))
#   reason:  writes state that concurrent tasks share (the plan argument, or a global) — NOT safe
#            to run concurrently (1 write(s) the scan read, 0 site(s) it could not rule out):
#              Writes the scan read (1):
#              [write 1] writes field `calls` of the plan argument directly (`setfield!`) — the
#                  plan is mutated during apply
#                    at …
```

The message lists what the scan read first, each entry marked `[write n]`, then atomic writes as
`[atomic n]`, then the sites it could not rule out as `[undecided n]`. Only a `[write n]` entry
makes the call raise, so in a long report those are the ones to fix.

The fix is to move what the call writes out of the shared object: return the count, or keep it in
an argument that each task owns.

When the first argument is the output, name the shared one with `self = N`:

```julia
@assert_concurrency_safe self=2 apply_into!(out, plan, x)   # `plan` is shared; `out` may be written
```

### What the scan follows

The scan reads the call's optimized IR, marks every reference derived from the shared argument,
and reports a store through one. A scalar read out of the plan, such as `plan.n::Int`, is a copy
and is not marked. A marked value is followed into a callee that was not inlined, down to
`max_depth` calls (4 by default), into a closure built from it, and into the body of a task that
captures it, so a `Threads.@spawn` inside the call is read too.

A struct built around the plan is a different object. A method that wraps its plan in a fresh
struct and fills in that struct's own fields passes.

A Base function that was not inlined is read the same way when its name ends in `!` (`sort!`,
`reverse!`, `delete!`) or when what it returns can be a reference into an argument (`get`,
`reshape`, `unsafe_wrap`). Its body says which argument it writes and whether its result is the
plan's memory or a copy, so `sort!(plan.buf)` and `get(plan.cache, k, x)[1] = v` are writes, and
`copyto!(out, plan.buf)`, `mul!(out, plan.A, x)` and `sort!(copy(plan.buf))` are not.

A lock, a condition, an event, a channel or a semaphore held by the plan is not marked. What
`lock(plan.lk)` writes inside the lock is the synchronization, not shared data. A `Threads.Atomic`
is marked: `Threads.atomic_add!(plan.ctr, 1)` and `plan.ctr[] = v` are atomic writes to shared
state, and warn as `@atomic plan.count += 1` does. The same holds for a constant global
`Threads.Atomic`: an atomic write to one is reported as an atomic write to process-global state,
and warns. A global handed to a helper is followed into it, as the plan is, so
`bump!(HITS)` is reported where `bump!` does the write. When atomic writes to a global are all
that was found, the report says that, and that the plan argument is not written.

### Throw or warn

Each finding is judged on its own, by how sure the scan is.

It throws on a write it read: a store through the shared argument, a store into a mutable `const`
global, a marked value at the destination of one of the Base functions the scan knows to mutate
(`push!`, `resize!`, `copyto!`, `fill!`), or a marked buffer as the destination of `memmove`,
`memcpy` or `memset`. One such finding is enough to throw, whatever else was
found.

It warns on what it could not rule out: a marked value passed to a call that dispatches at run
time, a task whose body it could not read, a call chain that reached `max_depth` before the
scan saw a store, or a marked pointer handed to a foreign function. The last follows Go's rule for
cgo: a C function is assumed to write through every pointer it is given, and the scan cannot read
it. That includes every BLAS and LAPACK routine, so `mul!(out, plan.A, x)` on `Float64` matrices
warns that `dgemv` received a pointer into the plan. The warning says so: "cannot establish that the plan argument is read-only —
sharing it across concurrent tasks is unproven, not disproven". For a chain that is too deep,
raise `max_depth` or assert on the inner method.

An atomic write, such as `@atomic plan.count += 1`, also warns. It cannot tear, but two calls that
share the plan still both change it, and the scan cannot tell whether they are meant to. The warning
says what was read: "makes atomic writes to the plan argument".

### Limits

The scan does not model aliasing: if the scratch buffer you pass shares memory with something the
plan owns, a write to the scratch passes. A Base function whose name does not end in `!` and
whose result holds no reference is treated as a read, so `write(plan.io, x)` passes. Which part of a captured array a task writes depends on
values, so a task that writes its own slice of a shared output is reported. And the verdict covers
the argument types of this call only.

`StrictModeTest` has no stronger answer for this guarantee. AllocCheck, JET and TrimCheck do not
decide whether an argument is written, so both packages run this scan. Pair it with a test that
runs the call from several tasks.

[`audit`](@ref) also sweeps `:concurrency_safe` over a module. A sweep cannot be told which
argument is shared, so it reads the first; Promise scope below describes what that means for a `!`
method.

## `@assert_no_threadid_state` — no per-thread state held across a suspension

A buffer indexed by `Threads.threadid()` looks private to the task that uses it, and it is until
the task is suspended. Julia does not preempt a task, but at a `yield`, a `wait`, a `fetch`, a
blocking `lock` or a `take!` on a channel it can move the task to another thread, or run another
task on this one. A slot chosen before that point and used after it may then be in use by two
tasks. [`@assert_no_threadid_state`](@ref) fails on that:

```julia
function count_work!(counts::Vector{Int})
    i = Threads.threadid()
    yield()                             # the task can resume on another thread
    counts[i] += 1                      # `i` names a thread the task may have left
    return counts
end

@assert_no_threadid_state count_work!(zeros(Int, Threads.nthreads()))
# ERROR: StrictViolation (@no_threadid_state): guarantee not satisfied
#   reason:  threadid-indexed mutable state (2 site(s)):
#              [1] holds per-thread (`Threads.threadid()`-indexed) state across `yield`, which can
#                  suspend the task: another task can then run on this thread and use the same state
#              [2] writes mutable state indexed by `Threads.threadid()` (`memoryrefset!`) — unsafe
#                  under task migration; index by a captured task-local id or a per-task buffer
#                  instead
```

The fix is to give each task its own slot, chosen where the task starts and passed down:

```@example guide
function bump_slot!(counts::Vector{Int}, slot::Int)
    counts[slot] += 1
    return counts
end

@assert_no_threadid_state bump_slot!(zeros(Int, 4), 1)
```

A write to `buf[threadid()]` passes when there is no suspension point between choosing the slot
and the last use of it, because no other task can run on the thread in between.

### What it detects

The scan reports a store to `buf[threadid()]`, whether the index is written in place or held in a
local. It also reports a store into an object loaded out of such a slot, as in
`buf[threadid()].field = …`, `buf[threadid()][i] = …` and `rand(rngs[threadid()])`. A slot's value
passed to a callee that was not inlined counts when the callee writes it, or returns it and the
caller then writes it. Suspension points are looked for in callees too.

A thread id stored into another array and read back later is not tracked.

A lock chosen by thread, `lock(locks[threadid()])`, is reported although it is not a data race,
because taking the lock writes a field of an object chosen by `threadid()`. Choosing a lock by
thread gains nothing once tasks can move, so the report is still worth reading.

The check throws when the scan read the suspension, and the message says the call "can suspend the
task". When the suspension is inside a callee the scan could not read in full, it warns, and the
message says "may suspend the task (not read in full)".

[`audit`](@ref) sweeps `:no_threadid_state` with nothing written at the call site. A signature for
which the compiler proves the `notaskstate` effect passes without a scan. The guarantee is not
part of [`@strict`](@ref).

## `test_calls` — every call resolves

A call with no matching method raises a `MethodError` only when it runs. If it sits on a branch no
test takes, the suite passes. The other gates miss it too: they ask whether code allocates or
dispatches at run time, and a call that cannot resolve does neither. `StrictModeTest.test_calls`
runs JET's call analysis over every signature of a module that has compiled, and throws one
`StrictViolation` that lists every call that does not resolve.

```julia
module MyPkg
label(x::Int) = "n = $x"
describe(x::Int) = x >= 0 ? label(x) : label(x, "negative")   # no two-argument `label`
end

MyPkg.describe(3)        # compiles describe(::Int); the negative branch never runs

test_calls(MyPkg)
# ERROR: StrictViolation (@test_calls): guarantee not satisfied
#   target:  MyPkg
#   reason:  StrictMode: 1 finding(s), 1 failing.
#              [✗ calls SM0204] describe (Int64) — MethodErrorReport(no matching method found
#              `label(::Int64, ::String)`: Main.MyPkg.label(x::Int64, "negative"))
#                  at …
#                  → a call on this path cannot resolve, so reaching it raises rather than
#                    returning. Fix the call, or — when a guard makes the path unreachable and
#                    inference cannot prove it — exclude the function by name with
#                    `exempt = (:describe,)` and say why in a comment.
```

The fix here is to define the method or correct the call.

Two kinds of JET report are gated: a call with no matching method, and a read of a name that is
not defined. JET's other kinds are dropped, because most of them are reports on correct code, such
as a function that checks its arguments and throws.

Like `test_compiled`, it sees only signatures that have compiled, so run the kernels before
calling it. `only` and `exempt` filter by function name.

It also reports a guard that inference cannot follow. The common case is
`isnothing(ref[]) && (ref[] = build())` followed by a second read of `ref[]`: the check narrows
the first read and not the second, so each use of the value is reported. Binding the read to a
local once removes the report and the type instability behind it. Where that is not possible,
`exempt = (:name,)` excludes the function.

`test_calls` always throws. It is a `StrictModeTest` driver, the analysis is JET's, and StrictMode
has no reporting form of it.

## `@golden` — a result that must not change

[`@golden`](@ref) records the result of an expression in a file the first time it runs, and
compares against that file on every later run. Use it for a port or an optimization that must not
change the numbers. It returns the result either way.

```@example guide
golden_dir = mktempdir()
x = [0.1, 0.2, 0.3]

@golden "running_total" cumsum(x) dir = golden_dir record = true   # no file yet: records
@golden "running_total" cumsum(x) dir = golden_dir                 # file present: compares
```

A result that differs fails, naming the first element that does:

```julia
@golden "running_total" cumsum(reverse(x)) dir = golden_dir
# ERROR: StrictViolation (@golden): guarantee not satisfied
#   target:  running_total
#   reason:  exact mismatch at index 1: expected 0.1, got 0.3 (ULP distance: 7205759403792793).
#            Use `ulps=N` for tolerance or delete the golden to re-record.
```

If the change is a bug, fix the code. If it is intended, delete the file, or run once with
`STRICTMODE_RECORD_GOLDEN=1`, which re-records every `@golden` in the run. The third case is a
reordered SIMD reduction: the compiler chooses the order in which vector lanes are combined, so a
sum can move by one unit in the last place (ULP) between Julia versions or CPUs. `ulps = 1`
accepts that much per element.

The comparison is `===` on each element by default, so `0.0` and `-0.0` differ.

Without `dir`, the file is `golden/<name>.golden` next to the file that contains the call. Commit
it. When the `CI` environment variable is set and the file is missing, `@golden` throws rather
than recording, because recording would compare nothing and pass. `record = true` at the call
site, or `STRICTMODE_RECORD_GOLDEN=1`, allows recording there.

For a problem with several valid outputs, `validator = f` replaces the file with a predicate on
the result:

```julia
@golden "shortest" format_float(x) validator = s -> parse(Float64, s) === x
```

### Limits

`@golden` records what the code produced on the first run, so it cannot tell you whether that
result was right. It compares one result for one input and says nothing about inputs you did not
run.

It accepts a real scalar and an array of `Float32`, `Float64`, `ComplexF32` or `ComplexF64`. Any
other type, an integer array included, is an error. A real scalar is stored as a `Float64`, so two
integers that round to the same `Float64`, such as `2^60` and `2^60 + 1`, compare equal.

A mismatch always throws, because `@golden` compares values it has in hand. It also runs when
checks are disabled: it tests correctness, so `disable_checks!()` does not remove it.

## `test_threadcount_invariant` — the same bits at every thread count

A threaded kernel that splits its work by `Threads.nthreads()` can return a different answer on a
machine with a different number of cores. The answers agree to rounding, so a test with a
tolerance passes on both. [`threadcount_invariant_report`](@ref) runs a call in a fresh Julia
process at each thread count and compares the bytes of the results.
`StrictModeTest.test_threadcount_invariant` is the form that fails a test suite.

```julia
# in MyPkg: the chunk boundaries move with the thread count, and so does the rounding
function psum(x)
    chunks = Iterators.partition(eachindex(x), cld(length(x), Threads.nthreads()))
    return sum(fetch.([Threads.@spawn sum(view(x, c)) for c in chunks]))
end

test_threadcount_invariant(
    :MyPkg, "MyPkg.psum(x)";
    setup = "using Random; Random.seed!(1); x = rand(10^6)",
    witness = "MyPkg.pool_jobs() > 0", threads = (1, 4),
)
# ERROR: StrictViolation (@test_threadcount_invariant): guarantee not satisfied
#   target:  MyPkg.psum(x)
#   reason:  at -t 4 the result differs from the one at -t 1, first at byte ….
```

The fix is to make the split independent of the thread count: a fixed chunk length, with the
partial results combined in a fixed order.

```julia
chunks = Iterators.partition(eachindex(x), 4096)
```

Julia fixes the thread count when the process starts, so `call` and `setup` are strings of code.
Each is evaluated in a child process after `using MyPkg`.

### The witness

A call that never uses more than one thread returns the same bits at every thread count. Whether
the threaded path ran can only be observed from inside the package, so `witness` is code that
returns `true` when it did, such as a check on a counter that the package's pool increments.
`test_threadcount_invariant` throws an `ArgumentError` when no witness is given. It fails when the
witness returns `false` at a count above one, and when no process had more than one thread.

The witness is not checked: the test runs the code it is given.

### Limits

Only the input that `setup` builds is compared. `setup` must build the same input in every
process, so seed random data. The result needs a fixed bit pattern: an `isbits` value, an array of
them, or a tuple of those.

`threadcount_invariant_report` returns a [`ThreadcountInvariantReport`](@ref) and does not throw
when results differ; it prints which counts differ and whether a witness was given.
`test_threadcount_invariant` throws, because it compares bytes it has read. The default is every
count from 1 to `Sys.CPU_THREADS`, one Julia process each, so pass a shorter `threads` where start
time matters.

## Promise scope

The checks fall into three groups, and the group decides how much a verdict is worth.

**Gating — these throw.** Each one reads compiled output, or the type the compiler assigned, so the
verdict is an observation: [`@assert_typestable`](@ref), [`@assert_owned`](@ref),
[`@assert_inlined`](@ref), [`@assert_vectorized`](@ref), [`@assert_no_spill`](@ref),
[`@assert_trusted`](@ref), [`@assert_no_threadid_state`](@ref). So do the two that take values and
run the call: [`@assert_memsafe`](@ref) and [`@assert_noalias`](@ref).

**Reporting — these warn.** Each one infers something it cannot see, so a failure is a lead:
`:noalloc` and `:noboxing` (typed IR cannot see what LLVM later removes), `:no_scalar_loops` (SLP
output forges the signal the check looks for), `:trim_compatible` (the static scan does not model
juliac's reachability limit, and juliac compiles a patched `Base`), and `:noescape` (a handle wrapped
in a `view` reads as unconfined even when the view is never used), and `:concurrency_safe` (a callee
it could not follow might treat the shared argument as read-only, or might not). `StrictModeTest`
gates the first four unconditionally, which is what that package is for. `:concurrency_safe` is the
exception: no backend answers whether an argument is written, so both tiers run the same scan and
the proof tier inherits its uncertainty rather than removing it.

**The dividing line is certainty, and it can be drawn per finding.** StrictMode throws only where it
is sure and warns where its verdict is a guess; `StrictModeTest` throws by definition, because
AllocCheck, JET and TrimCheck are full analyses rather than a scan. One check can do both, when its
own findings differ in kind. [`@assert_concurrency_safe`](@ref) is the clearest case: a write it
*read* in the typed IR throws, while a callee it could not follow warns — so the guarantee appears
in the reporting list above, and [`@assert_concurrency_safe`](@ref) still raises at a call site on a
write it can actually see. A chain that reached `max_depth` and stopped warns, because the scan never
got to the store; raise `max_depth` or assert on the inner method. The module-sweep paths warn
either way, since nothing there should be able to stop a module loading.
[`@assert_typestable`](@ref), [`@assert_trusted`](@ref) and [`@assert_no_threadid_state`](@ref)
split their own signals the same way.

**Informational — these never fail.** The module sweeps: [`dispatch_report`](@ref),
[`unsafe_report`](@ref), [`throw_report`](@ref), [`bang_report`](@ref),
[`alias_guard_report`](@ref), [`resource_leak_report`](@ref), [`conversion_report`](@ref),
[`specialization_report`](@ref), [`pool_balance_report`](@ref), [`inline_suggestions`](@ref),
[`static_ownership_suggestions`](@ref), and the measured ones —
[`steady_state_report`](@ref), [`gc_pause_report`](@ref), [`latency_report`](@ref),
[`kernel_report`](@ref), [`register_report`](@ref), [`spill_report`](@ref), [`mca_report`](@ref),
[`memsafe_report`](@ref). Thirteen of the seventeen `@assert_` guarantees are also swept by
[`audit`](@ref) with nothing written at the call site; the four that are not need actual argument
values, or an optional dependency, or a set of effects only the caller can name.

**[`audit`](@ref) is the second step, not the first.** It never throws on a violation (an invalid
argument, such as an unknown guarantee or an `only` entry that matches no function, does raise) and returns no exit status, so
it is not a gate — it is what you run *after* a warning or a failing test, to see the whole picture
around the one site that complained. The gate is the `@assert_` at the call site, or a
`StrictModeTest` driver in your suite; `audit` is how you work out what to change. That is also why
a guarantee can be swept without being safe to enforce everywhere: `:concurrency_safe` is swept, so
`audit` reports it, but it is deliberately absent from the `:all` policy set.

Two consequences of a sweep having nowhere to say *which* argument holds the shared object, both
measured in the field rather than reasoned about:

- **A `!` method gets `:info`, not `:fail`.** The name declares that argument 1 is written, so
  finding that write is reading the convention back rather than finding a defect. The suggestion
  names the fix — `@assert_concurrency_safe self=N f(…)` at a call site, where you can say which
  argument is actually shared. On one package this was 92 of 134 sweep failures; on another, 755 of
  762. The name says nothing about global state, so a `!` method still gets `:fail` when the scan
  reads a write to a constant global.
- **An `isbits` first argument reports nothing at all.** A copy cannot be written through, so the
  guarantee holds trivially — and seeding it as shared taints every index derived from it, which
  made a store into a buffer the method allocated *itself* read as a write to the shared object.

One property is out of scope: **bit-for-bit agreement with a reference implementation**. `@golden`
and `test_threadcount_invariant` compare a kernel with its own earlier output, or with its own
output at another thread count. Neither compares it with other code.

SIMD reduction order is LLVM-codegen-defined: the lane-combine order for a vector reduction — how
four `<4 x double>` lanes are collapsed to a scalar, for example — is chosen by the compiler and may
differ from a reference implementation, even when both produce IEEE-correct results. A ~1-ULP
difference between your kernel and a Rust or C reference is expected behavior and *not* a StrictMode
failure.

When testing numerical correctness against a reference, use tolerance-aware comparisons for SIMD
reductions. Exact matching remains valid for deterministic operations (non-reduction arithmetic,
memory copies, index computations). See also [the golden-harness methodology](cookbook.md) in the
cookbook for a practical port workflow.

## Compared with Rust

Rust is the usual reference point for "the compiler enforced it", so it is worth saying precisely
what the comparison is about — and memory safety is not it.

### Safety is not the axis

In Julia, memory safety holds for all code, always. Use-after-free, double-free and dangling
references cannot happen, because nothing frees anything while a reference exists. The borrow checker
does not buy safety *over* a garbage collector; it buys the same safety *without a runtime*, and adds
deterministic release.

The ways out of Julia's safety are a short list rather than a mode: `@inbounds`, `ccall`, `pointer`,
`pointer_from_objref`, and the `unsafe_` functions. [`unsafe_report`](@ref) fences exactly that list,
and `allow` excuses **one construct at a time** — `allow = (:unsafe_load,)` keeps a reviewed pointer
read while every other escape still fails. Rust's `#![forbid(unsafe_code)]` is the same idea at crate
granularity: all of it or none of it.

### The cost of all-or-nothing

Inside `unsafe`, Rust's aliasing and lifetime guarantees become the programmer's responsibility for
that whole region, and there is no way to give up one property and keep the rest. This matters most
in exactly the code StrictMode is for: high-performance numeric kernels reach for unchecked indexing
and SIMD intrinsics, so the proof is switched off where the performance work happens.

StrictMode inverts that. Safety is never what is at stake, so a guarantee is something you opt into,
per signature, for the property you actually need:

| you want | you ask for | and safety |
|---|---|---|
| no GC pause in a hot loop | [`@assert_noalloc`](@ref), [`gc_pause_report`](@ref) | unchanged |
| the vector code you think you wrote | [`@assert_vectorized`](@ref), [`@assert_no_spill`](@ref) | unchanged |
| one concrete type per specialization | [`@assert_typestable`](@ref) | unchanged |
| a kernel that stays in its own precision | [`conversion_report`](@ref) | unchanged |
| a static binary | [`@assert_trim_compatible`](@ref) | unchanged |

Nothing in that column is a trade against correctness, and nothing is all-or-nothing: a module can
require allocation-freedom of three kernels and say nothing about the rest. The guarantee is scoped
to where it earns its place, which is why there are seventeen of them rather than one mode.

A garbage collector only pauses code that allocates. Remove the allocation from the hot path — the
property [`@assert_noalloc`](@ref) checks and `StrictModeTest.@test_noalloc` proves — and the pause
goes with it. That is the same end state Rust reaches by construction, reached instead by a check
you can point at one function.

### Safety, flexibility, speed — all three

The position this package takes is a greedy one: safety, flexibility *and* speed, rather than a
choice among them. Each approach gives one of the three away, and it is worth being explicit about
which:

| | safety | flexibility | speed |
|---|---|---|---|
| Julia, plain | by construction, for all code | full — generic code stays generic, no ownership discipline | leaks where a collector pauses, a specialization goes unstable, or a literal widens a kernel |
| Rust | in safe code | **constrained** — every program obeys the rules, needed or not | yes, until a kernel needs `unsafe`, and then the proof stops wholesale |
| Julia with StrictMode | unchanged | unchanged | the properties that cost speed are **named, checked and gated** |

The third row is the only one that gives nothing up, and it is honest about what it delivers:
StrictMode does not make code fast. It makes the difference between the code you wrote and the code
you got *visible*, per property, and fails a build when that difference appears. The speed is still
yours to write; what you gain is that a regression cannot pass quietly.

Flexibility is the axis most easily lost sight of. A Julia kernel written once, generic in `T`,
compiles to the same machine code a hand-specialized version would — and
[`@assert_typestable`](@ref) plus [`@assert_vectorized`](@ref) are how you confirm it did, for each
concrete type, without writing the kernel twice. Nothing has to be given up to ask the question.

### Everyone pays for safety

The disagreement between the two languages is about the currency, not the goal.

**Julia pays with a runtime.** Safety comes by construction: nothing frees anything while a
reference to it exists, so no annotation, lifetime or ownership discipline is required of the
programmer, and a generic function stays generic. The bill is a collector in the process, choosing
its own moment to run.

**Rust pays at compile time.** There is no runtime to carry, but every program obeys a fixed set of
rules whether or not it needs them, and that costs flexibility. A cyclic or self-referential
structure has to be expressed with indices, an arena, or `Rc<RefCell<…>>` — and `RefCell` moves the
aliasing check to run time, where a violation is a panic rather than a compile error. Rust's own
escape hatch for shared mutation is a dynamic check, which is worth remembering when the comparison
is framed as static-versus-dynamic.

**The hot kernel is where both bills come due.** Julia's collector can pause the loop. Rust's checker
is in the way of the indexing and the intrinsics the loop wants, so the kernel reaches for `unsafe` —
and the proof stops for that whole region, including the parts that were never the problem.

StrictMode is the third option, and it is deliberately not a third set of rules. It starts from the
safe baseline Julia already has and lets a program name the property it actually needs, one signature
at a time:

- the hot loop must not allocate, so the collector has nothing to do there and cannot pause it
  ([`@assert_noalloc`](@ref), proved by `StrictModeTest.@test_noalloc`);
- this kernel must vectorize and must not spill ([`@assert_vectorized`](@ref),
  [`@assert_no_spill`](@ref));
- this specialization must be concretely typed ([`@assert_typestable`](@ref));
- this layer must not leave the language's safety at all
  ([`unsafe_report`](@ref), `StrictModeTest.test_no_unsafe`).

None of those is a trade against correctness, and none is a mode. A package can demand
allocation-freedom of three kernels and say nothing about the rest of itself, which is the opposite
of entering `unsafe` to get one unchecked index.

**And the opt-in is free where it matters.** `_gate` is a compile-time branch on a const, so with
[`disable_checks!`](@ref) every `@assert_` expands to the bare call: a shipped application carries no
check, no branch and no dependency. The cost is paid while developing, not while running — which is
the one sense in which this really is cheaper than paying at compile time, because the price is
charged only where somebody asked a question.

### What "safe" claims, precisely

Rust's `safe` is a narrow and precise claim: no undefined behavior in safe code. It is not a claim
that a program cannot deadlock (safe Rust can), cannot leak (`mem::forget` is safe, and `Rc` cycles
leak), cannot race in the general sense (data races are prevented; other race conditions are not), or
cannot panic. The soundness of a safe abstraction also often rests on `unsafe` internals that the
compiler does not verify — it checks the caller, not the proof the author made.

That is worth stating because the word carries more weight in argument than it does in the
specification, and the same caution applies here: Julia's memory safety says nothing about deadlocks,
leaks or logic races either. Neither language's baseline is the whole of correctness, which is why
both end up with tools layered on top.

### Where there is no Rust counterpart

Beyond correctness, `rustc` makes no promise about the machine code it emits, so these axes have
nothing to compare against:

- **type stability** — not a Rust concept, because monomorphization is mandatory there. In Julia it
  is a property each specialization either has or does not.
- **allocation-freedom** — `#![no_std]` removes the allocating API surface; it does not prove that a
  given function allocates nothing. That proof is what AllocCheck gives `StrictModeTest`.
- **vectorization, scalar loops, register spills** — LLVM decides, and neither language promises an
  outcome.
- **static-binary compatibility** — whether `juliac --trim=safe` can resolve every call.
- **GC pause** — Rust has no collector, so an allocating neighbor cannot stop an unrelated kernel.
- **load time and first-call latency** — properties of a cold process, which no typed IR predicts.
- **compiled-specialization count** — a consequence of Julia compiling per concrete type.
- **numeric conversion width** — a bare literal in Julia carries a default type, so one unsuffixed
  constant can widen a whole kernel.

### Identified gaps

Two properties Rust's model covers that this one does not yet. They are listed as open work rather
than as a defense of the design:

- **Data races, at compile time.** `Send` and `Sync` are checked for all code.
  [`@assert_concurrency_safe`](@ref) and [`@assert_no_threadid_state`](@ref) are IR scans instead:
  they find what they can read, and they are field-insensitive, so a task writing a disjoint slice of
  a shared output still reports. Closing this means a property that holds for every caller, which
  typed IR alone cannot give.
- **Release of resources that are not memory.** `Drop` runs at scope exit, on every path. Julia's
  collector decides when, and for a GPU buffer or a file handle that is not a performance question —
  the CPU collector cannot see GPU memory pressure at all.
  [`resource_leak_report`](@ref) finds a handle that outlives its owner and stops short of proving
  release on every path, because that needs post-dominance over the exception control flow and a
  `close` in a helper defeats it.

This is also why the two packages are separate. `StrictMode` reports and depends on no analysis
backend; `StrictModeTest` proves and depends on three. A heuristic that aborts a consumer's precompile
is worse than no check, and a proof costing a 680 MiB dependency does not belong in every user's
package graph.
