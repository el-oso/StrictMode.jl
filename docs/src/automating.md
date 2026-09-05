# Automating checks

Scattering `@assert_*` macros across call sites is precise, but it gets tedious fast. This page
covers the higher-level options. Quick reference for which to reach for:

| I want to… | Use |
|---|---|
| Check one call at a call site | `@assert_*` / `@strict` / `@kernel` |
| Check one function against its declared types | `@strict_function` |
| Mark a whole module strict | `@strict module … end` |
| Programmatically report on `(f, types)` | `findings` |
| Programmatically **gate** on `(f, types)` | `StrictModeTest.test_signatures` |
| Whole-package report | `audit` |
| Whole-package CI gate | `StrictModeTest.test_compiled` / `test_registered` |
| Live feedback while editing | `watch` + Revise |

(For wiring `audit` into an AI agent or CI pipeline, see [Agentic feedback](agents.md).)

## The function API — `findings` and `test_signatures`

[`findings`](@ref) runs the guarantees on a `(function, signature)` pair and returns the results.
It's an ordinary function call over *types*, so it never has to parse a call expression — reach for
it when you already have a signature in hand, or when you're building tooling on top. (The macros
accept keyword-argument calls and an explicit `types = (…)` signature override directly, so you
rarely need it just to work around syntax — see [Guarantees](guarantees.md).)

```@example auto
using StrictMode

dot3(a, b) = a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
findings(dot3, (NTuple{3,Float64}, NTuple{3,Float64}))   # all :pass
```

Nothing actually runs here; the analysis works purely from the types. That means it is happy even
with calls you wouldn't want to execute for real — a `10000×10000` signature costs nothing.

`findings` never throws: it is the data half of the API, and the caller decides what a finding is
worth. To **gate** on the same signatures, add `StrictModeTest` to the test environment. Its
`test_signatures` takes the same list, runs AllocCheck and JET instead of the value-free scan, and
throws a `StrictViolation` collecting every failure:

```julia
using StrictMode, StrictModeTest
test_signatures([
    (dot3, (NTuple{3,Float64}, NTuple{3,Float64})),
    (kernel, (Matrix{Float64}, Vector{Float64})),
]; guarantees = (:typestable, :noalloc, :noboxing, :inlined))
```

## Strict by default — one switch, not per-function

You shouldn't have to annotate every function by hand. `@strict module … end` makes the whole
module strict on its own: every definition is checked by default, and you opt the occasional cold
helper out with [`@strict_exempt`](@ref).

```julia
@strict module Kernels        # one declaration disciplines the whole module
    dot3(a::NTuple{3,Float64}, b::NTuple{3,Float64}) = a[1]*b[1] + a[2]*b[2] + a[3]*b[3]   # hot
    saxpy(a::Float64, x::NTuple{4,Float64}, y::NTuple{4,Float64}) = a .* x .+ y            # hot

    @strict_exempt plan(n::Int) = collect(1:n)   # cold setup code — intentionally allocates
end
```

A hot definition whose return type is not concrete stops the module from loading, while
the cold `plan` is skipped everywhere: by the load check, by `audit`, by `test_registered`, and by
the sweep. The load check uses the value-free engine, so it needs no AllocCheck or JET backend and
stays affordable to run on every load — which is also why an allocation verdict there only warns.

If you'd rather mark a single function than a whole module, [`@strict_function`](@ref) registers
and verifies one definition at a time.

### Auto-check at load

When a strict-marked module loads and checks are enabled, StrictMode runs its checks on its own and
a non-concrete return type stops the module from loading. This is the "checks happen as you
compile" behavior. It's
gated on `checks_enabled`, so a production build pays nothing, and the analyzers are already warmed.

### Re-check on demand

```julia
audit(:registered)            # report on the whole mark-once registry, returns the findings
registered_strict()           # the registry: (f, types) => (; guarantees)

# …and from the test environment, where StrictModeTest supplies the proofs:
test_registered()             # re-prove every registered signature; throws on any failure
```

## Usage-driven sweep

This is the hybrid option: check whatever concrete method instances a module actually compiled,
whether that was during your tests, a run, or precompilation. No annotations needed.

```julia
using MyPkg
# … exercise MyPkg (run your tests / a workload) …
audit(MyPkg; sweep = true, guarantees = (:noalloc, :noboxing))   # report
test_compiled(MyPkg; guarantees = (:noalloc, :noboxing))          # prove and gate
```

Coverage is only as good as what actually ran, and the walk through compiler reflection is
best-effort and defensive. In return, it needs no marks at all.

## The coverage gate — `audit(mod; require = :public)`

The drivers above check what was *declared* (registry) or what *ran* (sweep) — neither notices
a new public function that was never brought under StrictMode at all. The coverage gate closes
that hole: it fails (one `guarantee = :coverage` finding, `status = :fail`) for every
exported/`public` function of the module that is neither registered nor exempted.

```julia
# in your test suite: registration is the manifest, the gate enforces completeness
StrictMode.register_strict!(MyPkg.kernel!, (Vector{Float64},); guarantees = (:typestable, :noalloc))
test_registered()                                 # the declared guarantees hold…
@test nfailures(audit(MyPkg; require = :public)) == 0   # …and nothing public is undeclared
```

A new public function now cannot ship silently unchecked: either it gets registered with its
guarantees, or it is opted out **visibly** (`@strict_exempt` / the `exempt` kwarg) where a
reviewer can see it. Scope with `only`/`exempt` exactly as in the sweep above.

## Live feedback with Revise — `watch`

Load [Revise](https://github.com/timholy/Revise.jl) next to StrictMode and you get a live loop:
after each edit, the strict registry is re-checked and any violations print straight to the REPL.
It's the closest thing to a compiler looking over your shoulder as you type.

This is StrictMode on its own — `watch` runs the value-free scan and nothing else. It is a REPL loop
in your package's own environment, where `StrictModeTest` is not a dependency and the proofs are
not available; adding it would change nothing here anyway. Iterate against the scan, and let the
test suite prove it.

```julia
using Revise, StrictMode
# … using MyPkg, which marks its kernels strict …
StrictMode.watch()             # start the loop
# edit a kernel so it boxes, save:
#   StrictMode: 1 finding(s), 1 failing.
#     [✗ noalloc] dot3(NTuple{3,Float64}, NTuple{3,Float64}) — allocates (1 site(s))
#         → preallocate the buffer, use @views for slices, or @unroll to avoid boxing.
StrictMode.unwatch()           # stop
```

`watch` is the feedback path for a human at a REPL. An AI agent wants something different: a
one-shot, structured result it can parse. That's [`audit`](@ref), and it has its own page in
[Agentic feedback](agents.md).
