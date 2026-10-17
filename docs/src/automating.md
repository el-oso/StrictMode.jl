# Automating checks

Scattering `@assert_*` macros across call sites is precise, but it gets tedious fast. This page
covers the higher-level options. Quick reference for which to reach for:

| I want to… | Use |
|---|---|
| Check one call at a call site | `@assert_*` / `@strict` / `@kernel` |
| Check one function against its declared types | `@strict_function` |
| Mark a whole module strict | `@strict_policy` (or `@strict module … end`) |
| Programmatically report on `(f, types)` | `findings` |
| Programmatically **gate** on `(f, types)` | `StrictModeTest.test_signatures` |
| Whole-package report | `audit` |
| Whole-package CI gate | `StrictModeTest.test_compiled` / `test_registered` |
| Fail on anything UNdeclared | `StrictModeTest.test_coverage` |
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

You should not have to annotate every function by hand. `@strict_policy` makes the whole module
strict on its own: every definition is checked by default, and you opt the occasional cold helper
out with [`@strict_exempt`](@ref).

```julia
module Kernels
using StrictMode

include("dot.jl")      # covered: the check reads this module's METHODS, not its body text
include("saxpy.jl")    # covered

@strict_exempt plan(n::Int) = collect(1:n)   # cold setup code — intentionally allocates

@strict_policy (:typestable, :noalloc)      # last, so everything above it is checked
end
```

It reads the module's methods rather than rewriting its body, which is why definitions inside an
`include`d file are covered.

### Opting parts of it out

`@strict_policy` opts the whole module **in**; `@strict_exempt` opts sections **out**. The subject
can be a region or a whole file, and either can be narrowed to one guarantee:

```julia
@strict_exempt reason = "plan-time setup" begin      # a cold region, one marker
    plan(n::Int) = collect(1:n)
    build_table(x) = Dict(:a => x)
end

@strict_exempt :noalloc reason = "allocates the workspace once" begin
    make_workspace(n::Int) = Workspace(Vector{Float64}(undef, n))
end

@strict_exempt reason = "plan-time file" include("plan.jl")   # everything that file defines
```

The `include` form calls the file's own `include`, so relative paths resolve as they would have,
and it finds the definitions by comparing the module's methods before and after — which is why a
nested `include` inside `plan.jl` is covered too.

A guarantee named before the subject narrows the exemption. The subject is the **last** positional
argument, which is what keeps `@strict_exempt :foo` meaning the function `foo`.

Naming one guarantee rather than exempting the function is the right tool for a workspace or arena
allocator, not merely a tidier one. It has to allocate, so `:noalloc` must go — but its concrete
return type is the whole reason its callers can be fast, and `:typestable` stays on to protect it.
Measured on two allocators that are both excused for allocating: one that picks its element type
from a VALUE still fails `:typestable`, because callers would get a `Union` and dispatch on it,
while a concretely typed one passes. A whole-function exemption hides exactly that.

Where a file mixes hot and cold code and you would rather not list the cold parts, scope the policy
by name instead:

```julia
@strict_policy :default only = r"^kernel_"    # check the kernels, leave the rest alone
```

`@strict module … end` is the wrapping spelling of the same check, for a module you are writing
from scratch:

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

## The coverage gate — default-deny

The drivers above check what was *declared* (registry) or what *ran* (sweep) — neither notices a
method that was never brought under StrictMode at all. That is the hole an opt-in leaves: a
missing declaration and a deliberate exemption read exactly the same. The coverage gate closes it
by making absence a failure.

```julia
# in your test suite: declarations are the manifest, the gate enforces completeness
StrictMode.register_strict!(MyPkg.kernel!, (Vector{Float64},); guarantees = (:typestable, :noalloc))
test_registered()                     # the declared guarantees hold…
test_coverage(MyPkg)                  # …and nothing is undeclared
```

`audit(mod; require = :all)` reports the same thing without raising.

Two scopes:

| | counts |
|---|---|
| `require = :public` | undeclared exported/`public` **functions** |
| `require = :all` | undeclared **methods**, foreign-function methods included |

`:all` reads the global method table rather than the module's names, so a `Base.size` or
`Base.getindex` method the package defines is counted — those are frequently its hottest code, and
no walk over the module's own bindings can see them. Measured on StrictMode itself: 476 methods,
of which a binding walk finds 457, and 13 of the ones it reports belong to foreign functions.

Keyword wrappers, closures and default constructors are not counted — none of them is a method a
declaration could name — and one `:info` finding reports how many were left out, so the gate
cannot quietly narrow its own scope.

A new method now cannot ship silently unchecked: either it is declared with its guarantees, or it
is opted out **visibly** (`@strict_exempt` / the `exempt` kwarg) where a reviewer can see it.

### What counts as covered

A declaration names a **signature**, and a guarantee can only be checked for a signature that
names concrete types — a generic definition infers to `Any`. So the gate asks per signature, not
per method:

- A method that has compiled concrete signatures is covered only when **every one of them** is
  declared. `gen(x::T) where {T<:Real}` called with `Float64` and `Int32` has two; declaring
  `(Float64,)` leaves `(Int32)` reported, because nothing checked it.
- A method nothing has compiled yet has no signature to name, so the gate falls back to asking
  whether any declaration speaks for the method at all.

Coverage therefore follows what actually ran. A signature that appears for the first time in a
later run is reported then — which is the point: it was not checked before either.

!!! note
    The gate reports whether a declaration *exists*. Whether the guarantees then *hold* is
    `test_registered`'s job. Measured on StrictMode: 79 of its 476 methods have a dispatch-tuple
    signature of their own; the rest are generic and need their instantiations listed
    (`signatures = [(T1, …), …]`) to be proved as well as counted.

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
