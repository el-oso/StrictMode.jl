# Changelog

## Unreleased

### `gc_quiet_report` and `@test_gc_quiet` — no collection runs while the call does

Allocation-freedom is necessary and not sufficient. Julia's collector stops the world, so a kernel
`@test_noalloc` proves allocates nothing is still paused at a safepoint by an allocating neighbor,
and no analysis of the kernel can see the cause — it is not in the kernel.

`gc_quiet_report(f, args...)` warms the call, runs it `samples` times, and reports whether a
collection landed inside a call, plus the per-call distribution: median, q99, max, and how many
calls took more than `slow_factor` times the median. It never raises.
`StrictModeTest.@test_gc_quiet` is the gating form, with `max_collections = 0` by default and an
optional `max_q99_ms` latency budget.

The sampling window allocates nothing, so the harness does not create the collections it counts;
it costs about 140 ns per sample.

`process_bytes` is the allocation recorded while the worst call ran, in the whole process rather
than in the call: Julia's allocation counters are global, and `@allocated` reports a neighbor's
bytes too. It sizes the collector pressure the rest of the process contributed; `@test_noalloc`
remains the answer to what the call itself allocates.

A static proof that every thread is allocation-free inside a declared window is not reachable from
a package. This measures it and says so.

### `@assert_noalias` — a written argument must not overlap a read one

A kernel that writes one argument while reading another assumes the two are distinct; when they
overlap, the result depends on the order the elements happen to be visited. `@assert_noalias`
checks that at the call site with `Base.mightalias`, Julia's own predicate, and compiles away with
every other `@assert_*` macro when checks are off.

It is the only check that reads **values** rather than a signature, since whether two arrays
overlap is not a property of their types. So `:noalias` is not in `StrictMode.guarantee_names()`:
it cannot be swept by `audit` or declared on a `@strict_function`, and a declaration naming it is
rejected rather than skipped.

Which arguments are written comes from the name — a trailing `!` means argument 1 — and anything
else must say so with `mutates = (…)`. A call that gives neither is rejected, at macro expansion
where the callee is a plain name: "nothing is written" would compare no pair and pass every call.

Disjoint slices of one workspace are accepted, so a blocked kernel carving tiles out of shared
scratch is not reported. A satisfied assertion allocates nothing and costs about 2 ns per pair.

## 0.5.1

### `:typestable` accepts a constant-type and an always-throwing return

A method inferred to return `Type{Float32}` returns one compile-time constant, and a method
inferred `Union{}` always throws, so it returns nothing at all. Neither is a type instability, but
`isconcretetype` says false to both, and the return-type layer gates — so `@strict_policy :default`
failed to precompile a module holding ordinary trait helpers (`eltype(::Type{S}) = Int`,
`weight_eltype(::F32Format) = Float32`) or an argument-error helper that only throws.

Both now pass. A type-valued return that VARIES still fails: `x > 0 ? Real : Integer` infers
`Union{Type{Integer}, Type{Real}}`, which is the instability the guarantee exists to catch. Issue
#36.

### An exemption covers the closures the exempted function defines

A closure is a method of its own with a mangled name, so `@strict_exempt :noalloc path` left
`#path##0` — the `() -> joinpath(...)` inside `path` — reported anyway. Name matching demangles the
closure form alongside the kwsorter one, so a declaration, an exemption and an `only`/`exempt`
filter all reach the closures a function defines.

### A documented definition keeps its docstring under the macros

`@doc` can only document a bare definition, and `@strict_function`, `@strict_stable` and both
definition forms of `@strict_exempt` expand to a block — so a docstring in front of one aborted the
load with `cannot document the following expression`. Each marks the definition it emits, and the
docstring lands on it.

## 0.5.0

Breaking. An opt-in check that can be forgotten is not a guarantee, so a missing declaration now
fails instead of passing quietly, and `audit` hands back findings instead of printing them.

### A parametric definition no longer breaks `@strict module`

`h(x::T) where {T<:Real} = …` aborted the module load with `UndefVarError: T`: the registration
the macro emits named the signature's type variables, which have no meaning outside the method.
Such a definition is now skipped — its signature could never be a dispatch tuple, which is all the
registry can check — and one warning per module names the definitions left unchecked and how to
check them (`signatures = [...]`, or `@strict_stable`).

### The coverage gate is default-deny, over methods

`audit(mod; require = :all)` and `StrictModeTest.test_coverage(mod)` fail for every method a module
defines that no declaration speaks for and no exempt covers. `require = :public` keeps its narrower
meaning: exported and `public` functions only.

`StrictMode.module_methods(mod)` is the census behind it. It reads the global method table rather
than the module's bindings, so a method the package defines on a *foreign* function — `Base.size`,
`Base.getindex`, `Base.show` — is counted. Those are frequently a package's hottest methods and no
walk over its own names can see them: measured on StrictMode, 476 methods against a binding walk's
457, 13 of them on foreign functions. Keyword wrappers, closures and default constructors are not
counted, and an `:info` finding reports how many were left out.

Coverage is asked per **signature**, not per method. A method that has compiled concrete signatures
is covered only when every one of them is declared: `gen(x::T) where {T<:Real}` called with
`Float64` and `Int32` has two, and declaring one leaves the other reported, because nothing checked
it. A method nothing has compiled has no signature to name, so there the gate asks only whether
some declaration speaks for it.

The gate reports whether a declaration exists, which is a fact. Whether the guarantees hold is
still `test_registered`'s job, and that needs a signature naming concrete types — 79 of
StrictMode's own 476 methods have one of their own, and the rest are generic.

### A declaration survives the declaring package's cached load

`@strict_function` in a package's `src/` runs at that package's own precompile, and the
`register_strict!` insert went into StrictMode — which is already loaded from its own pkgimage by
then, so the mutation was discarded on the package's next cached load. A consumer's test process
therefore saw no declarations however many its source carried, `test_registered` re-proved nothing,
and the new coverage gate called a fully annotated package undeclared.

A declaration now lives in the module that made it, as a `const` of the package, so it is
serialized into that package's own pkgimage. `StrictMode.declarations()` and
`StrictMode.exemptions()` are the unioned views every driver reads: each loaded package's own, plus
whatever this session registered directly. `registered_strict()` / `exempt_strict()` now mean "this
session's", and `StrictMode.clear_declarations!()` empties every store, which is what a test needs
for isolation.

Measured on the `test/consumer` fixture after a cached load: `registered_strict()` is empty,
`declarations()` carries ConsumerPkg's two, and `test_registered` reports `ConsumerPkg: 2`.

### `@strict_policy`, and a module check that sees through `include`

`@strict module … end` rewrote the statements of the module body, so a definition inside an
`include`d file was never registered and never checked — which is nearly all of a real package. The
load check now reads the module's **methods** instead, so those definitions are covered. The check
can only evaluate a method whose own signature is concrete; the rest are the coverage gate's job
from the test environment.

`@strict_policy (:typestable, :noalloc)` declares the same thing without wrapping the `module`
keyword, so adopting it does not mean restructuring a package's main file. Place it last to check
everything above it. Submodules inherit a policy by lookup, so one changed in a parent is never
stale in a child, and a guarantee list may nest — a shared policy can live in one package and be
named by every module that follows it.

### `:noescape` — a handle that must not leave its scope

Some values are valid only inside the frame that obtained them: a borrow from an arena, a pointer
into a slab, a token for a held lock. If one leaves, the result is a use-after-free rather than a
slow path. The escape analysis that `:noalloc` already runs answers this; what was missing was a
way to ask it.

```julia
register_scoped!(ArenaHandle)
@assert_noescape compute!(arena, A, b)
```

What it proves is CONFINEMENT: that the handle provably cannot leave the frame. A pass is
trustworthy. A failure means confinement could not be proved — returned, stored, captured, or
handed to a function the analysis cannot see through, which cannot be told apart because the escape
state of an unanalyzed callee is assumed rather than computed. Measured on the shape it exists for — an isbits, pointer-backed handle
passed by value — with controls on both sides: a frame that keeps its handle and a frame that never
makes one both pass.

Only a handle CREATED in the frame carries a verdict. A handle arriving from a producer that did
not inline is a call result, which is a structural fact read from the IR rather than a verdict, so
it is reported as its own case with the fix named. `Union{}` types a statement whose only outcome
is a throw and is a subtype of every type, so it is excluded explicitly; a union carries a handle
if any member does. Nothing is registered by default, so it passes trivially until a type is
declared scoped. It REPORTS rather than gating, and has no proving counterpart, so treat a failure
as a lead to check by hand. The reason is measured: a handle wrapped in a `view` reads as
not-provably-confined even when the view is never used, because the wrapper is scalar-replaced out
of existence while the handle it was built from stays marked unconfined — so a frame that leaks a
view and one that merely takes a view are indistinguishable, and neither direction of the analysis
separates them (assuming callees clean misses the real leak instead). Wrapping a borrow before use
is ordinary, so gating on that verdict would fail correct code in the shape this exists for. A BARE
handle — created in the frame, used there, not wrapped — is answered soundly in both directions.

Registration is by **type**, not by the function producing the value, because the analysis must run
on IR after inlining and a small `borrow!` inlines into its caller — taking the callee boundary with
it. The type survives that.

It does not cover a handle that stays in the frame and is used after its scope ends. That is not an
escape, and the analysis correctly calls it clean; rejecting it needs a syntactic check where the
end of the block is visible. The halves are complementary, and this closes the one where the value
leaves.

### The escape analysis had stopped running

`:noalloc` suppresses a finding where LLVM would elide an allocation that never escapes its
frame (issue #17), which it decides by running the compiler's escape analysis. That analysis asks
`code_ircode_by_type` to stop after inlining, by name — and an unrecognized pass name is an ERROR,
not a no-op. The name the compiler uses changed, so every call threw, a bare `catch` returned the
conservative answer, and the analysis had not run at all: allocations that measure zero bytes were
reported as real.

The name is now read from the compiler's own published list where it has one, so it follows a
rename rather than being keyed to a version. Measured on issue #17's own reproducer, which
allocates zero bytes: reported as allocating before, clean after, on both supported Julia versions.

The failure was invisible because the fallback is conservative — it only ever declines to suppress
a finding — so the test now asserts a POSITIVE control unconditionally. The previous test accepted
either answer and attributed the miss to a moved internal, which is how a fixable bug stayed
hidden behind a documented degradation. If a future Julia moves this out of reach, that is a red
build and a decision to make.

### Allocation that stops once warmed: a gate and a report

`:noalloc` asks whether allocation is possible on any path, so a workspace pool that allocates
whenever it grows to a new high-water mark can never pass it, and should not: the growth path exists
forever. The property such code really has is about the **call sequence** — warm it and it stops
allocating — which is settled by measuring rather than by inference.

```julia
@test_steady_state solve!(ws, A, b)                 # warmed, then zero bytes
@test_steady_state scratch(ws) fresh_task = true    # fails if it is per-task
```

`fresh_task = true` measures on a newly scheduled task, which is what separates a **pool** from a
**per-task initializer**: a pool at its high-water mark allocates nothing for any caller and passes
either way, while a `OncePerTask` accessor passes on the warming task and fails on a fresh one,
because every new task pays again.

It is a measurement, not a proof, and the docstring says so where it matters: it covers the calls
that ran and says nothing about an argument shape it was not given. It is the counterpart to an
exemption rather than a replacement — mark the function `@strict_exempt :noalloc reason = "…"` so
the allocation is excused where a reader can see it, then assert the real property here.

`steady_state_report(f, args...)` is the development-time counterpart: it measures the same thing,
returns a `SteadyStateReport` and never raises, for use from a probe or a REPL session. Like
`memsafe_report` and `mca_report` it takes VALUES and runs the call, so it sits outside the
value-free `findings`/`audit` pipeline. There is deliberately no `@assert_steady_state`: an
`@assert_*` macro is backed by the value-free scan, and this property needs real arguments and two
actual calls, which at a `src` call site would mean real work on every call.

For a package whose buffers grow to a high-water mark, that pair is the expected spelling rather
than an exception: measured on a downstream library, six registered allocation barriers covered only
three test items, every failure a high-water mark at Julia's own array allocation, reached from
three unrelated entry points.

### Opting sections out: a block, a file, or one guarantee

`@strict_policy` opts a module in; `@strict_exempt` now opts sections of it out at the granularity
the code has.

```julia
@strict_exempt reason = "plan-time setup" begin      # a region, one marker
    plan(n::Int) = collect(1:n)
    build_table(x) = Dict(:a => x)
end

@strict_exempt :noalloc reason = "a factory must allocate" begin
    make_buffer(n::Int) = Vector{Float64}(undef, n)  # still held to type stability
end

@strict_exempt reason = "plan-time file" include("plan.jl")
```

The subject is the **last** positional argument and anything before it names the guarantees to
excuse, which is what keeps `@strict_exempt :foo` meaning the function `foo` — a name is spelled
`:foo` too.

The `include` form calls the file's own `include`, so relative paths resolve as they would have, and
it finds what to exempt by comparing the module's methods before and after rather than by rewriting
the file. A nested `include` inside the exempted file is therefore covered as well.

`@strict_policy` takes `only` and `exempt`, scoping the check by function name — a collection, a
`Regex`, or a predicate, as the module sweeps already took them. That is how one file holds hot
kernels and cold helpers without a submodule: `@strict_policy :default only = r"^kernel_"`. Scoping
by name composes with the census, where a region would be a scope the census does not model.

### Two declarations in one block no longer warn about world age

A module's declaration store is created on first use, and a second declaration in the same
top-level statement read that binding in the world that created it — which Julia 1.12 warns about
and a later version makes an error. The stores this session has found are now remembered, so a
reader never touches a binding created in its own world. A `@strict_exempt begin … end` block emits
one call per definition and hits exactly that.

### A misspelled guarantee is an error

`register_strict!(f, types; guarantees = (:typestabel,))` was accepted and then checked nothing: the
driver never saw the name, so the suite stayed green while the guarantee the author asked for was
never applied. Unknown names are now rejected where they are written, and
`StrictMode.guarantee_names()` lists the valid ones.

### `audit` returns findings; rendering is a separate step

`audit` and `proof_audit` no longer take `format` or `io`. They return the
`Vector{StrictFinding}`, and `format_findings` renders it:

```julia
fs = audit(MyPkg; sweep = true)
print(format_findings(fs; format = :json))
```

A module sweep reaches several hundred findings, whose `:json` rendering runs past 100 kB — pushed
through a log or a tool-result channel on every call, it is truncated before it is read, while
`filter`, `nfailures` and `findings_diff` all work on the value. Passing either keyword now raises
an error naming the replacement rather than a `MethodError`.

Displaying a findings vector prints the counts and the failures, with the passes collapsed to a
tally.

### A finding names the rule that required it

```
[✗ noalloc SM0002] kernel!(Vector{Float64}) — allocates (1 site)
      required by @strict_policy at src/Kernels.jl:14
      → allocation in a hot path: preallocate the buffer, use @views for slices …
```

Only a macro can know that line, because a function cannot see its caller, so
`@strict_function`, `@strict module` and `@strict_policy` record it and every finding from that
declaration carries it in a `policy` field, serialized with the rest. A declaration made by a plain
`register_strict!` call has no line to read and the field is empty — the honest answer rather than a
guessed one.

### Named policy sets

`@strict_policy :default` is `(:typestable, :noalloc, :noboxing)`, which is also what a module with
no policy gets, so the name cannot drift from the behavior. `:hot` adds `:vectorized`,
`:no_scalar_loops` and `:no_spill`; `:all` is every guarantee. A name expands wherever a guarantee
may be written, so `(:default, :vectorized)` composes rather than replacing.

The previous default was the pair without `:noboxing`. Both report rather than gate, so adding it
widens what an unmarked strict module warns about without being able to break a build.

### Every finding carries a diagnostic code

`StrictFinding` has a `code`: a stable name for the KIND of finding, such as `SM0104`. It is keyed
on `(guarantee, cause)` rather than on the reason text, because a reason is assembled at the call
site and two reports of one problem do not read alike, while the pair is fixed. Where the cause is
recognized, the code names it:

```
[✗ typestable SM0104] bad(Vector{AbstractFloat}) — return type is not concrete (inference)
```

`StrictMode.explain("SM0104")` prints what the code means, the same fix the finding carries, and
what the verdict is worth. `StrictMode.codes()` lists all of them. A published code is permanent: a
kind that goes away leaves a gap in the table rather than freeing its number, so a saved report and
a link to one stay valid.

### An exemption is a record, not a name

`@strict_exempt` now records a signature, the guarantees it covers, a reason and its own source
location, instead of a bare function name. Three things follow.

It can be narrowed: `@strict_exempt plan guarantees = (:noalloc,) reason = "builds the plan once"`
excuses the allocation and still holds `plan` to type stability. An exempted guarantee is reported
as `:info` carrying the reason rather than dropped, because an opt-out nobody can see in the output
is indistinguishable from a check that was never asked for.

It can name a method on a **foreign** function: `@strict_exempt Base.length(::Foo) = 1`. That
spelling used to raise `unsupported definition`, which left the methods the census counts with no
way out.

And it can be retired. `StrictModeTest.test_exemptions(mod)` reports an exemption whose guarantee
the **proofs** now satisfy — code that was fixed while the opt-out stayed. Findings are `:info` and
never failures: an exemption is a deliberate human statement, and a red test for tidy-up work is a
new reason to switch the gate off. It lives in the proving tier because only a proof may say this;
the value-free scan is wrong in both directions on allocation, so acting on its opinion would
delete an exemption the proofs then fail.

`exempt_strict()` and `StrictMode.exemptions()` now return `Vector{Exemption}`.

### A finding says which engine produced it

`StrictFinding` carries `tier`: `:report` for StrictMode's value-free scan, `:proof` for
StrictModeTest's AllocCheck/JET/TrimCheck. Both tiers build the same record, so a saved
`:jsonlines` file — read by another process, or another session — had no way to tell a guess from a
proof. It is in the JSON output.

### `audit_changed` — what moved, not everything that is wrong

```julia
d = audit_changed(MyPkg; sweep = true)      # since the last run in this session
print(format_findings(d.introduced; format = :text))

audit_changed(MyPkg; baseline = "strict.bin", update = true)   # record a baseline
audit_changed(MyPkg; baseline = "strict.bin")                  # …diff against it, from anywhere
```

It returns `(; fixed, introduced, changed, unchanged)`, compared by `StrictMode.key` so a finding
survives edits to the code it is about and a new `reason` for the same key reads as `changed`
rather than one `fixed` plus one `introduced`.

Two baselines, because they answer different questions. The in-session one is kept in memory and
replaced each run — the edit-check-fix loop. A file outlives the process, so another session or a CI
job can diff against yours; it is written only when `update = true` is passed, since a run that
silently rewrote it could not be compared twice. A path that does not exist yet reports everything
as `introduced`, which is what a first run should say, and a file that is not a baseline is reported
rather than read as an empty one.

A baseline file is a machine artifact written with `Serialization`, so it round-trips a finding
exactly — including the fields a text format flattens — and is readable only by a StrictMode with
the same `StrictFinding`. For something durable and human-readable, write
`format_findings(fs; format = :jsonlines)`.

### Findings have identity, and two runs can be compared

`StrictMode.key(f)` is `(mod, func, signature, guarantee)`, which survives edits to the code the
finding is about. `findings_diff(old, new)` returns `(; fixed, introduced, changed, unchanged)`,
so one session can hand another a baseline as `:jsonlines` and compare against it.

### A cached verdict notices when a callee changes

The findings cache keys on the checked method, which an edit one level down leaves identical — the
`Method` object and its `primary_world` are untouched — so a caller kept a `:pass` after its callee
started allocating. Measured before the fix: cached `:pass`, uncached `:fail`, for the same code.

Julia does record it, on the compiled code rather than on the method: when a callee changes, the
caller's `CodeInstance` has its `max_world` capped. Each entry now holds the instances its verdict
was read from and is dropped when one of them is invalidated. Measured: the same callee edit now
gives `:fail` from the cache, and holding the validation costs nothing — a warm whole-package
re-audit measured 477.8 ms without the check and 474.8 ms with it.

A method that has never been compiled has no instance to watch, and only there is
`clear_cache!()` still needed. Its docstring says so.

### A trim verdict names the rejected site again

The verdict was read from the verifier's printed output, and that printer reaches into
`Base.Compiler.TrimVerifier` internals which do not all exist on every supported Julia — on 1.13
it raised, the text came back empty, and every rejection collapsed to "verifier output not
recognized" with no site. The verdict is now read from the error objects themselves: the rejected
statement, its line, and the caller chain up to the signature under test.


## 0.4.11

### The heuristic trim note stays out of precompile output

A `@assert_trim_compatible` PASS notes that the static scan is not juliac's verifier. A package
that asserts at precompile — so inference sees its whole call graph before the module closes —
therefore handed that note to everyone who built it, once per package, since `maxlog = 1` counts
per process and each precompile is a fresh one. The note is now emitted only outside output
generation, the same gate the tier banner and the type-stability report already use. A developer
calling the macro in a session or a test still gets it.

## 0.4.10

Four defects in trim verification, all reachable from one gate.

### A verdict names the oracle that produced it

A trim rejection reported itself as `juliac --trim=safe`, and the suggestion called it
authoritative. By default the verifier runs against **stock** Base while juliac compiles a patched
one, so such a rejection can name a construct juliac accepts — and the message sent readers to
rewrite working code. A failure now names the oracle it came from, and a stock verdict points at
`StrictModeTest.set_juliac_patches!(true)` for the question it did not answer.

### The patched child verifies a whole gate, not one signature

Each signature spawned its own Julia process, paying a start, a package load and a patch
application every time. `test_signatures`, `test_compiled` and `test_registered` now verify every
signature they cover in one child. Each signature travels in its own file and is read inside a
`try`, so a function the child cannot resolve costs that one verdict rather than the whole run's.

### The child loads the modules a signature needs

It loaded `parentmodule(f)` — the module that *declared* the generic, not the one that defined the
method. A package extending another package's generic therefore sent the child a module that
cannot resolve the argument types the extending package owns, and the child died deserializing its
own input, falling back to the stock verdict it was spawned to replace. The method's own module and
every module each argument type's spelling depends on are now loaded, each named by the package
`using` can load.

### A finding carries the rejected call site

The site was shown as a bare file name and the finding's own `file`/`line` named the function under
test, so output could not reveal that the rejected construct lived in a dependency — where no
rewrite of the signature can change the verdict. The path is kept whole, and the finding points at
the site.

## 0.4.9

Two false positives a consumer sees on its own code, both reported from
UpdatableFactorizations.jl and both fixed.

### A guarded call site no longer reports StrictMode's own reflection

With checks enabled, a `@strict` or `@assert_*` site leaves a live `:invoke` of `_strict_scan` behind
its per-site flag, and the scan recursed into it like any callee. A scan of the **enclosing** function
then reported the scan's own allocation, boxing, dict lookup and union phi, so `@verify_strict`,
`audit` and `@assert_noalloc` flagged kernels that are clean. Callees whose module root is StrictMode
are now skipped — and not recorded as a barrier, since a barrier grants an allocation exemption
elsewhere while StrictMode's presence in a body says nothing about the caller's own cost.

### An error path is dead even when it is reached by a jump

`ignore_throw()` discounts error paths, but the mask marked only the block that **ends** in the
unreachable return. A `throw`'s message is usually built earlier, in a block that jumps there, so its
`print_to_string` stayed live and the scan reported allocation for text no successful call builds. The
mask now computes reachability: a statement is an error path when no path from it reaches a return
carrying a value. Loops are unaffected — a statement is alive when *some* path from it returns.

Measured on the report's own code (the QR `lowrankupdate!` keyword body, 1833 statements): of its five
`print_to_string` invokes, the rank-deficiency message at statement 1571 was live under the old rule
and is dead under this one, and the dead count goes from 156 to 316.

## 0.4.8

### A type-stability failure names the declaration to edit

`:typestable` findings now identify the cause when one is recognizable, and carry the fix that
matches it instead of the generic "annotate the unstable variable": a non-`const` global, a field
declared with an abstract type, an abstractly typed container whose element flows into the body,
reflection (`return_types`, `invokelatest`, `which`, `methods`), or more matching methods than
inference enumerates. The classifier (`StrictMode._instability_cause`) reads typed IR and the method
table; it needs no backend and runs on both tiers.

### `dispatch_report`

New: where a module dispatches at run time, and where a call sits at exactly `max_methods` matching
methods — static today, dynamic as soon as one more method is defined anywhere, with no edit to the
calling code. The new [dynamic dispatch](https://el-oso.github.io/StrictMode.jl/dev/dynamic_dispatch)
page carries the measured cost (per element over 1000 elements: 24.02 µs / 32 kB with an abstract
element type, 0.58 µs / 0 B with a concrete one or a `Union` of concrete types) and the fixes that
work — including two that do not, a `where {S<:Abstract}` parameter and a function barrier.

### `@test_typestable` no longer fails on an optimizer bail

A JET `OptimizationFailureReport` says inference declined to optimize a recursive frame. It does not
say a type is unknown, and it does not mask a dispatch report — a dynamic call inside the declined
frame is still reported. Such a report is now logged once, naming the frame, instead of failing the
guarantee. Every other JET report kind still fails it.

### `audit` carries dispatch findings

The same sites as informational findings (`guarantee = :dispatch`, `status = :info`, never a failure),
so a JSON audit carries them next to the guarantees. On by default: an at-the-limit call is a hazard
nobody thinks to ask about, since the code looks fine today. Measured on 10,974 PureBLAS
specializations the pass reports nothing and costs 17.8% of the sweep (one extra typed-IR read per
specialization); `dispatch_suggest = false` skips it.

### A bailed frame's own body is scanned for dispatch

JET's dispatch analysis runs on optimized IR, and a frame that produced none cannot report a dispatch
from its own body. Those bodies are now scanned directly, and a runtime dispatch found there fails
`:typestable` like any other.

### The trim gate covers an embedded macro, and stops skipping on 1.13

The consumer trim build proved the load path and `@strict_function` declarations, but nothing reached
a call-site macro inside code the binary compiles — the case the guarantee is about. CI now builds two
binaries: the armed one as before, and a shipping one (`checks_enabled = false`) whose entry calls a
function containing `@strict`. Measured: that source fails with 248 verifier errors while checks are
enabled, and builds and runs with them off, so both halves are pinned.

The step also looked for `juliac.jl` in Julia's share directory and skipped silently when absent —
which is every Julia 1.13, where it moved into the JuliaC.jl app. It now uses the app instead, and a
Julia with neither fails the step rather than passing it.

### Removed

`@assert_trim_safe` and the `:trimsafe` guarantee, deprecated since 0.4.0. Use
`@assert_trim_compatible` and `:trim_compatible`, which run the same scan; `migration_report` names
the replacement.

## 0.4.7

### The tier banner no longer reaches a library's users

Loading any package that uses StrictMode in its own `src` printed the tier banner, about a tool
that package's users did not choose and cannot silence from their own project. The banner now
prints only where StrictMode is named by an environment the session loads from —
`StrictMode.direct_dependency()`, which searches the active project, the explicit paths on
`LOAD_PATH` (`Pkg.test` puts its sandbox there) and the shared `@v#.#` environment. The disabled-
and-CI banner is unchanged: that one reports a run whose checks prove nothing, and it is loud
wherever it happens.

`__init__` stays `juliac --trim`-clean, which is what shapes the search: it reads the
`Base.ACTIVE_PROJECT`/`LOAD_PATH` slots rather than `Base.active_project()`/`Base.load_path()`,
searches each project file's bytes rather than parsing TOML, and reads a fixed-size buffer.

### An immutable stored into a concretely typed slot is no longer reported as allocating

The allocation scan counted every store builtin as a box, so a factorization written straight into
a field — `ls.fact = cholesky!(Symmetric(ls.cap); check = false)` — was reported as allocating
while AllocCheck proved it did not. A slot whose declared type is concrete and
`Base.allocatedinline` takes the value's fields by copy; only a pointer slot (an abstract or
union-typed field, a `Vector{Any}` element) needs the value boxed first, and those stay flagged.

## 0.4.6

### `@test_typestable` no longer fails a target that wakes or yields a task

On Julia 1.13, JET reports an optimization failure inside Base's scheduler (`yield` → `wait` →
`OncePerThread`) for any call graph that reaches `notify` or `yield`. `@test_typestable`,
`test_signatures` and the other drivers failed such a target, and every caller of it, although the
reports were located entirely in Base. An optimization-failure report is now dropped when its
innermost frame lies in a different top-level module from the target. A cycle inside the target's own
package still fails, and so does every other kind of JET report.

A failing finding now names each report's kind and location, for example
`1 JET report(s): RuntimeDispatchReport in MyPkg.f`.

## 0.4.5

### Complex arithmetic is no longer reported as allocating

Optimized IR can name the type of a `:new` with a `GlobalRef` instead of the type itself — complex
division builds `%new(Base.ComplexF64, …)`. The allocation scan treated such a type as unknown and
reported an allocation. It now resolves the name first. On 120 compiled PureBLAS and PureIPM
specializations, the scan agrees with AllocCheck on all 120; 0.4.4 reported 6 `ComplexF64` LAPACK
routines that allocate nothing.

## 0.4.4

### The allocation scan no longer flags `ccall` `Ref`s and passed-down wrappers

The value-free scan counted every non-isbits `:new` in typed IR as a heap allocation unless escape
analysis cleared the whole frame, which it almost never does in library code. Two shapes that
codegen places on the stack were reported as allocating:

- the `Ref` arguments every BLAS/LAPACK wrapper builds for its `ccall`, including the `info` it
  reads back;
- immutable wrappers such as `view`, `Diagonal` and `A'`, passed to a resolved call or returned with
  a concrete type.

Each `:new` is now judged by where its value goes. A value stored into an abstractly typed field is
boxed, as before (`Some{Any}(x)`). An immutable allocates only when it reaches a slot that needs a
box. A mutable object used only by a `ccall` and its own field is a stack `Ref`; any other mutable
still goes through escape analysis. A use the rules do not recognize counts as a box.

On PureOSQP's `admm_step!` and `update_residuals!` across 13 backends, the scan disagreed with
AllocCheck on 18 of 26 signatures; it now agrees on all 26, with no new false negatives. A cold scan
of those signatures is no slower.

## 0.4.3

### The assertion macros are allocation-free

A guarded call measures the same as an unguarded one. Per call, warm, on a 64-element dot product:

| macro | bytes |
|---|---|
| bare call | 0 |
| `@strict` | 0 |
| `@assert_noalloc` | 0 |
| `@assert_typestable` | 0 |
| `@assert_noboxing` | 0 |
| `@assert_owned` | 0 |
| `@assert_inlined` | 0 |

Each check reads only the signature, so it runs once per `(call site, argument signature)` rather
than on every execution (#29).

`StrictModeTest`'s `@test_noalloc` and `@test_typestable` pass on a guarded call whose kernel is
clean, and still fail on one whose kernel is not.

Two checks stay per call, because they read values rather than types:
`@assert_noalloc static = false` measures the call it just made, and `@assert_memsafe` runs the real
arguments through a guarded buffer.

### `Base.return_types` is memoized

Cached on the same terms as the IR scan: identity on the signature, keyed by world age, cleared by
`clear_cache!`.

## 0.4.2

Three consumer-breaking bugs. Anyone on 0.4.0 or 0.4.1 shipping a `juliac --trim` artifact, or
using `@strict_function` on a parametric method, or opting a module in with `@strict module`, wants
this release.

### The load banner broke `juliac --trim` for every consumer (#28)

`__init__` called `_announce_tier`, which wrote the banner with `printstyled`. `juliac --trim`
retains `__init__` as a root, so everything it reaches must be statically resolvable —
`printstyled` routes through `styled_print`/`invoke_in_world`, which the verifier cannot resolve.
`using StrictMode` alone was enough; no macro had to be called, and `checks_enabled = false` only
changed which banner was reachable. Reported from PureBLAS.jl, whose CI builds a real
`--trim=safe --compile-ccallable` artifact.

Measured against juliac's own verifier, and it rules out the obvious fix: `printstyled`, `print`
and `write` are all unresolvable from `__init__`; only a foreigncall verifies clean. The banner now
goes out through `ccall(:jl_safe_printf, …)` and loses its color.

That call passes NO variadic arguments, which matters more than it looks. `jl_safe_printf` is
declared `void jl_safe_printf(const char *fmt, ...)`, and naming an extra argument in the `ccall`
signature describes a non-variadic call: x86-64 SysV passes it in a register and the callee happens
to find it, while the AArch64 Apple ABI passes variadic arguments on the stack. The first attempt
did exactly that and segfaulted every macOS CI job at `using StrictMode`, with Linux and Windows
green. The message is therefore the format string itself, so the banner text must contain no `%` —
pinned by a test.

A `banner` preference was added alongside it:

    [preferences.StrictMode]
    banner = false

Being a compile-time const, that folds `_announce_tier` to `nothing` and leaves `__init__` with no
body at all — for anyone who would rather their load be provably silent than trust that the writer
stays trim-clean. A binary built with `checks_enabled = false` is already silent without it
(measured: zero bytes on stderr).

### `@strict_function` on a parametric method failed to load (#28 audit, F1)

    @strict_function f(x::T) where {T<:Real} = x
    # UndefVarError: `T` not defined

A `where` binds its type variables to the method, not to the enclosing module, and the macro
evaluated the declared argument types at module top level. Checks are on by default, so this failed
in every dev and test environment while working in production.

The types are no longer evaluated when the signature is parametric. Nothing is lost: `Tuple{T}` is
not a dispatch tuple, so the check took its abstract-signature path anyway — it now says so and
points at `signatures = [...]`, which still verifies the concrete instantiations.

### `@strict module` aborted a consumer's precompile on the allocation heuristic (#28 audit, F2)

`_auto_check_module` threw on any failing finding without consulting `_guarantee_gates`, so the
value-free allocation scan — 8.1% false over a 120-specialization corpus (#17) — could stop a module
loading. That is issue #18's shape: fixed for `@strict_function`, left live for the module form,
where the blast radius is every definition in the module rather than one.

It now splits on `_guarantee_gates` exactly as `@strict_function` does: the allocation verdict warns,
and the checks that observe compiled output still throw.

### Also

- `Pkg.test` merges the parent project's preferences into its sandbox, so a package shipping
  `checks_enabled = false` carries it into its own suite and `StrictModeTest.__init__` errors. The
  source comment claimed the opposite; the error message now names the actual remedy
  (`checks_enabled = true` in `test/Project.toml`).
- `signatures = [(T,)]` naming a type with no method reported "return type is not concrete …
  inferred Any[]", which sends the reader looking for an instability that is not there. It now says
  no method matches.

### The gap that let #28 ship twice

CI had no trim build, and the consumer fixture only ran `Pkg.test` in an ordinary process, where
`__init__` is never a trim root. CI now builds that fixture as a real `--trim=safe` executable and
runs it, which covers StrictMode's `__init__`, every transitive dependency's, and whatever the
definition-level macros leave behind in a trimmed image. Verified to fail when the `printstyled`
banner is restored.


## 0.4.1

### `CpuId.cachesize()` throws on aarch64 (Apple Silicon)

It has two failure modes and the extension handled one. It RETURNS `()` on x86 parts CpuId cannot
parse, which `_set_cache_bytes!` already guarded — but it THROWS on a host with no cache leaves at
all, because CpuId's non-x86 `cpuid` is an all-zeros stub, so `hasleaf` is false for both
`0x00000004` and `0x8000001d`. That is every aarch64 host. An exception escaping an extension
`__init__` is fatal during precompilation, so any package depending on both StrictMode and CpuId was
uninstallable on Apple Silicon.

Handling moved to `StrictMode._init_cache_bytes(probe)`, which takes the probe as a function so x86
CI can inject a throwing one — a real `cachesize()` only throws on hardware no runner here has.

Note for 0.3 consumers: this fix is on the 0.4 line only. A package pinning `StrictMode = "0.3.10"`
resolves `[0.3.10, 0.4.0)` and will not see it until it moves to 0.4.

### `@strict_contract` accepts an interface description

It forwarded only two arguments to `TypeContracts.@contract`, so the 3-argument
`(type, description, block)` form failed with a `MethodError` on the macro itself. Per-method
`=> "doc"` and `:optional` ride inside the block and were never affected, which is why the feature
looked half-present rather than missing.

### A union-typed local that boxes is now reported (F39)

A non-isbits union phi is a tagged pointer, so a member that normally lives unboxed must be
heap-boxed to flow through it. The box leaves no `:new` and no allocating `foreigncall` in optimized
IR — its only trace is the phi's own type — so the scan was blind to it, JET is blind to it
structurally (union splitting is not dynamic dispatch), and AllocCheck sees it only at whichever
signature happens to box.

Member count is not the discriminator; representation is. isbits members ride the unboxed payload and
mutable members are already pointers, but an immutable struct holding heap references — `SubArray`,
`Adjoint`, `Transpose` — is boxed on the way in.

The signal rides `:typestable`, not `:noalloc`, and that is deliberate. "This local is union-typed
with a box-on-entry member" is a property of the code as written; "it allocates" is LLVM's call and
moves with inlining — the same fixture measures 16 B/call across a module boundary and 0 B once it
inlines. Folding it into an allocation verdict would red kernels LLVM made free, which is issue #17
again.

Measured on 600 compiled stdlib specializations: it fires on **2** (0.3%), both genuine —
`LinearAlgebra.wrap` builds a `Union{Adjoint, Transpose, Symmetric, Hermitian, Matrix}`, where the
four immutable wrappers box and the `Matrix` does not.

### `:trusted` — foreign data has to be checked before it's used

`Untrusted(x)` marks data from a socket, a file, `ARGS`, or a device. It changes the type, so no
method written for the payload matches it: an ordinary use is a `MethodError`, in a shipped build
too, since the type is never gated away. `unsafe_trust` is the one way out, `trust_boundary!`
registers the function allowed to use it, and `@assert_trusted` fails on any other function that
reads a payload.

This is the Julia form of the kernel's `__user` annotation: a distinct type, a single greppable
cast, and a checker for where that cast appears. Dispatch does most of the work with no checker at
all; the scan covers the part the language cannot, since `getfield` is a builtin callable anywhere.

Detection reads UNOPTIMIZED typed IR — a small boundary inlines under optimization and its
`getfield` then surfaces in an innocent caller's IR. `_unopt_callee` also resolves a callee from a
constant-folded SSA type, without which `Core.getfield` (which lowers to a call through
`getproperty(Core, :getfield)`) was invisible.

### The allocation scan is memoized — `@strict` is 266× faster

`_alloc_signals` ran `code_typed` unconditionally on every call, and the `@assert_*` macros run
their check on every EXECUTION of a call site, not once per site — so a `@strict` inside a loop paid
a full re-inference per iteration. The `_SIGNAL_MEMO` that existed covered only the callee
recursion.

Measured on a 256-element dot product whose bare call is 19.8 ns:

| | before | after |
|---|---|---|
| `_alloc_signals` | 449.9 µs, 13,230 allocs | 255.7 ns, 4 allocs |
| `@strict` | 914 µs, 26,512 allocs | 3.43 µs, 64 allocs |

Cached on the same terms as the inner memo — identity on the signature, keyed by `(depth, world)`,
so any new method definition invalidates — and cleared by `clear_cache!`.

### `@strict` also reports owned scratch

A runtime dict lookup is type-stable and non-allocating on the warm hit, so `:typestable` and
`:noalloc` both pass it; only `:owned` sees it. It **reports** from `@strict` rather than throwing,
because the rule flags any `AbstractDict` accessor — right for a check you name at a call site, too
broad applied to every one, since a value-keyed cache is legitimate. `@assert_owned` still throws
when called directly. `@assert_noboxing` stays out of `@strict`: its rule is a strict subset of
`@assert_noalloc`'s, so it would report the same violations twice.

`@strict` gained this check and still got faster, because both ask at the same depth and now share
one memo entry.

### `@assert_trim_safe` is deprecated

It runs the same scan as `@assert_trim_compatible` under an older name. It warns once per session
and will be removed.

### Patched trim verification runs in a subprocess (#19)

Applying juliac's `juliac-trim-base.jl` is what makes the verifier check the program juliac
actually compiles, and it is the only way to avoid the false FAILs #19 reports — a ≥4-argument
string interpolation on a reachable throw path is rejected without it. But that file stubs
`Base.CoreLogging.current_logger_for_env`, so whichever process applies it stops emitting `@warn`
and `@info` for good: the whole of StrictMode's reporting tier, silent. Observed directly — two
`@test_logs` assertions went empty the moment the patches were applied by default.

`set_juliac_patches!(true)` now runs the patched verification in a child process and reads back
only the verdict, so the caller keeps its logging. This is the isolation TrimCheck's own
`validate_function` gets from a Distributed worker, and the shape `@assert_memsafe` already uses.

The child reports whether the patches were actually applied, and a verdict reached without them is
refused rather than returned. juliac ships no patch files on some builds (1.13.0-rc4), and a silent
fallback there would relabel a stock-Base verdict as a patched one — reinstating exactly the
false-FAIL class this path exists to remove.

Every failure degrades to unpatched in-process verification with a warning naming the cause, never
to a FAIL: "could not verify the way juliac does" is not "trim-unsafe". A closure or a fixture
defined inside a `@testitem` cannot be resolved in a fresh process, so those take that path.

Still off by default — the child costs a Julia start and a package load per verification.

## 0.4.0 — the tier split

**Read this before upgrading.** The breaking change is *silent*: every `StrictMode` macro keeps its
spelling, so your call sites compile and run exactly as before. What changes is that most of them
stop deciding your build. Nothing surfaces that at compile time.

### The one-sentence version

`StrictMode` **reports**; the new companion package `StrictModeTest` **gates**. Which engine a call
site uses is now the macro you wrote — `@assert_noalloc` is the value-free scan, `@test_noalloc` is
AllocCheck's proof — with no mode to switch and no ambient state deciding it.

### If you do nothing

Your suite still runs and still passes. But `@assert_noalloc`, `@assert_noboxing`,
`@assert_no_scalar_loops`, `@assert_trim_safe` and `@assert_trim_compatible` now **warn** where they
used to throw, so a real regression in any of those will no longer fail your build. Everything else
(`@assert_typestable`'s return-type layer, `@assert_memsafe`, `@assert_vectorized`,
`@assert_no_spill`, `@assert_inlined`, `@assert_owned`, `@assert_concurrency_safe`,
`@assert_no_threadid_state`) still throws.

Why: those five infer something they cannot see. The allocation scan reads typed IR, where an
allocation LLVM will later elide is still present — measured 8.1% false positives over 120 compiled
PureBLAS and PureIPM specializations, every one of them 0 bytes. A check that guesses must not be
able to abort a build. The ones that still throw *observe* compiled output rather than inferring
about it.

### To keep gating

Add `StrictModeTest` to your **test** environment and use the `@test_*` surface:

```julia
# test/Project.toml:  [deps] StrictMode, StrictModeTest
using StrictMode, StrictModeTest

@test_noalloc kernel!(C, A, B)     # AllocCheck's all-paths proof — throws
test_compiled(MyPkg)               # gate everything the module actually compiled
```

### Migration table

| 0.3 | 0.4 |
| --- | --- |
| `check(f, types)` | `findings(f, types)` to report, `test_signatures([(f, types)])` to gate |
| `check_all()` | `test_registered()` |
| `check_compiled(mod)` | `test_compiled(mod)` |
| `check_signatures(pairs)` | `test_signatures(pairs)` |
| `audit(mod; exit_on_fail = true)` | `test_compiled(mod)` — `audit` no longer sets an exit status |
| `mode = :fast` / `mode = :full` | removed — the macro name selects the engine |
| `fail_mode` preference | removed — throw-vs-warn is per guarantee |
| `status == :suspect`, `nsuspect` | removed — status is `:pass`/`:fail`/`:info` |
| `status == :skip` | removed — an unevaluable guarantee is `:fail` carrying the error text |
| `backend_available()` | `proofs_loaded()` |
| `BackendUnavailable` | removed — a proof cannot find its backend missing |
| `divergence_report` | moved to `StrictModeTest` |
| `StrictMode.AnalysisError` | `StrictModeTest.AnalysisError` |
| `ignore_barrier` / `set_ignore_barrier!` | moved to `StrictModeTest` |
| `@assert_noalloc static = true` | `@test_noalloc` (the old form now errors, pointing at it) |

If you match on the JSON `status` field, `"suspect"` no longer appears — match `"fail"` alone.

### Other changes

- **`checks_enabled` defaults to `true`.** A test environment needs no `[preferences.StrictMode]`
  block. A shipped application turns checks off with `disable_checks!()`, which is what makes the
  macros compile to bare calls. A preference block that *enables* checks is now redundant; one that
  disables them still works.
- **`StrictModeTest` refuses to load when checks are disabled.** With checks off every `@assert_*`
  is a bare call and nothing registers, so `test_registered()` would sweep an empty registry and
  report success.
- **Both packages announce their tier at load**, because the state worth knowing is not "checks are
  off" but "checks are on and `@assert_noalloc` is no longer a proof" — and those two used to print
  identically.
- **`@explain` stayed in `StrictMode`** and is rebuilt on the value-free engine. `StrictReport`'s
  `opt_result`/`allocs`/`alloc_error` fields are replaced by `signals`, `local_boxing` and
  `scan_error`.
- **`@assert_memsafe` lost `isolate=false`.** An in-process probe can only use the canary, and a
  load past the end disturbs no canary, so its clean verdict was indistinguishable from no overrun
  at all — in exactly the case the harness exists for. The probe always runs in a subprocess now,
  the poison is position-dependent, aliased arguments share one guarded buffer, and arguments the
  harness cannot guard are named in `MemsafeReport.unguarded` instead of being silently skipped.
- `Julia 1.12` is the minimum.

### Fewer false allocation reports (issue #17)

The allocation scan reads typed IR, where an allocation LLVM will later remove is still present, so
a call measuring 0 bytes could be reported as allocating. `Core.Compiler.EscapeAnalysis` on the same
signature now gates both the `:new` and the `Core.memorynew` rules, and
`length(Vector{Float64}(undef, n))` — the issue's own reproducer — comes back clean. Over eleven
hand-built shapes it produces **zero false negatives**: everything that really allocates is still
flagged.

Set expectations honestly, though: on a corpus of 120 compiled PureBLAS and PureIPM specializations
this removed **zero** findings, leaving the false-positive rate at 8.1% either way. 63 of those
frames contain a non-isbits `:new` and the analysis proves the set fully non-escaping in none of
them — it separates small self-contained kernels, not the interprocedural shapes library code is
made of. It is therefore computed on demand, at the first non-isbits `:new` that nothing else has
already flagged; eagerly it doubled a sweep (45.0s vs 21.7s over that corpus), lazily it costs 28.0s.
The number that matters more for anyone tempted to gate on this scan is the other direction: it
misses 23 of the 91 signatures AllocCheck flags, a recall of 75%.

`Core.Compiler.EscapeAnalysis` is a compiler internal with no cross-version stability guarantee, so
any failure inside it falls back to "assume it escapes" — the previous behaviour. A Julia release
that moves it degrades the false-positive rate rather than weakening the guarantee.

### `migration_report` also flags deleted API

Beyond the macros that stopped gating, 0.4 **deleted** names some consumers call directly:
`analysis_mode`, `backend_available`, `trimcheck_available`, `check_all`, `check_signatures`,
`check_compiled`, `nsuspect`, `fail_mode`, `BackendUnavailable`, and the `exit_on_fail` keyword.
Those are a `UndefVarError` at load, not a silent downgrade — and three of the eight consumer
packages measured here gate a block of their **`src/`** on `analysis_mode()` / `backend_available()`,
which stops the package precompiling at all. `migration_report` scans `src/` and `ext/` for deleted
names (fatal anywhere) and `test/`, `benchmark/`, `bench/` for the reporting macros (only a problem
where the proof was available).

### Trim verification: juliac's warnings, and its Base patches

- **Warnings are no longer failures (issue #20).** `TrimVerificationErrors.errors` is a
  `Vector{Pair{Bool, Any}}` whose `Bool` is `warn`, and juliac's own gate fails only on the
  non-warning entries. `@test_trim_compatible` now splits them: a raise carrying nothing but
  warnings is a PASS, and only the real errors reach the site parser, so a warning's call site is
  no longer reported as a failing one.
- **`set_juliac_patches!` (default `false`).** juliac includes `juliac-trim-base.jl` and
  `juliac-trim-stdlib.jl` before trim inference, and without them the verifier rejects code juliac
  builds clean — issue #19, where a ≥4-argument string interpolation on a reachable throw path is
  despecialized to `Vararg{Any}`. Enabling this applies them. It defaults **off** because
  `juliac-trim-base.jl` stubs `Base.CoreLogging.current_logger_for_env`, which silences every
  `@warn` and `@info` for the rest of the session — including the entire StrictMode reporting tier.
  Turn it on only in a process that does nothing but trim verification.

### Trim scan: calls that union-split past the limit (issue #13)

The static scan gained a third rule. `TypeContracts.trim_report` finds dynamic dispatch by asking
whether a call's *result* infers to `Any`; a call left unresolved because its arguments union-split
past `max_union_splitting` infers a perfectly concrete result and was invisible to it, while juliac's
verifier rejects it. `@assert_trim_safe` / `@assert_trim_compatible` now report it, naming the callee
and the specialization count.

No callee size or opacity threshold is involved: a callee small enough to inline leaves no call
behind, and a product within the limit is split before optimization ends, so both safe cases are
excluded by the IR itself. Verified against juliac's verifier on seven shapes, including three
`Union{Nothing,Int}` arguments at one call site — which the verifier genuinely rejects.

### Two ways to check a definition that names no concrete types

A generic declaration cannot be checked as written: `return_types(pick, Tuple{Tuple,Int})` is `Any`,
so verifying it directly would fail every generic function in Julia. `@strict_function` therefore
skipped such definitions entirely, warning and moving on — which left the most common shape in a
library with no guarantee at all. Two additions close that, answering different questions.

- **`@strict_function signatures = [...]`** verifies the same contract against concrete
  instantiations you name, at module load, exactly as a concrete declaration is verified:

  ```julia
  sigs = [(NTuple{3,Float64}, Int), (Tuple{Float64,String}, Int)]
  @strict_function signatures = sigs pick(t::Tuple, i::Int) = t[i]
  # the second entry infers Union{Float64,String}, so the module fails to load
  ```

  Supplying it also silences the abstract-declaration warning, since it answers what that warning
  asks. The definition is untouched.

- **`@strict_stable`** instead checks every specialization callers actually create, and costs
  nothing for the ones that hold. The body moves into a hidden inner function and the public one
  infers its return type; that inference is a compile-time constant, so a stable specialization
  compiles to the same LLVM as the unannotated definition and still inlines into its caller, while
  an unstable one throws as it is compiled.

Reach for the first when the contract is a fixed set of signatures and you want the module to fail
to load. Reach for the second for an entry point whose callers pick the types — accepting that the
verdict then forms per specialization rather than at load, and that inference is not stable under an
open world, so a definition that loaded clean can begin to throw. Only type stability can be
delivered this way; allocation and vectorization are read from compiled output.

### `@test_typestable` sees the union-phi box too (issue #27)

0.4.1 taught StrictMode's scan to flag a union-typed local carrying a member that must be boxed to
flow through it. The proof did not learn it at the same time, which left the reporting tier stricter
than the gating one: `@assert_typestable` reported the class and `@test_typestable` waved it through,
because it checked the return type and then asked JET — and union splitting is not dynamic dispatch,
so JET is silent on it at every signature.

`StrictModeTest` now consults the same signal after its own two layers pass. Both packages move to
0.4.1 together, and StrictModeTest's `[compat]` on StrictMode is pinned to `"0.4.1"` rather than
`"0.4"`: it reaches into StrictMode internals, so a loose bound would let a version pair resolve
that was never tested together.
