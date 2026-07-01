# Automating checks

Scattering `@assert_*` macros across call sites is precise, but it gets tedious fast. This page
covers the higher-level options. Quick reference for which to reach for:

| I want to… | Use |
|---|---|
| Check one call at a call site | `@assert_*` / `@strict` / `@kernel` |
| Check one function against its declared types | `@strict_function` |
| Mark a whole module strict | `@strict module … end` |
| Programmatically check `(f, types)` | `check` / `findings` |
| Whole-package CI sweep | `audit` |
| Live feedback while editing | `watch` + Revise |

(For wiring `audit` into an AI agent or CI pipeline, see [Agentic feedback](agents.md).)

## The function API — `check`

[`check`](@ref) runs the guarantees on a `(function, signature)` pair. It's an ordinary function
call, so it can't collide with broadcasting, nested macros, or keyword arguments the way a macro
might. Reach for it whenever a macro would get in the way, and use it as the programmatic entry
point when you're building tooling on top.

```@example auto
using StrictMode

dot3(a, b) = a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
check(dot3, (NTuple{3,Float64}, NTuple{3,Float64}))   # all :pass
```

Pick the guarantees and the failure behavior:

```julia
check(kernel, (Matrix{Float64}, Vector{Float64});
      guarantees = (:typestable, :noalloc, :noboxing, :inlined),
      fail = :error)          # :error throws, :warn logs, :none just returns the findings
```

Nothing actually runs here; the analysis works purely from the types. That means `check` is happy
even with calls you wouldn't want to execute for real.

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

A hot definition that boxes or allocates stops the module from loading (in `:error` mode), while
the cold `plan` is skipped everywhere: by the load check, by `check_all`, by `audit`, and by the
sweep. The load check itself uses the cheap `:fast` triage, so it needs no AllocCheck or JET
backend and stays affordable to run on every load.

If you'd rather mark a single function than a whole module, [`@strict_function`](@ref) registers
and verifies one definition at a time.

### Auto-check at load

When a strict-marked module loads and checks are enabled, StrictMode runs its checks on its own and
reports according to [`fail_mode`](@ref): `:error` stops the module from loading, `:warn` just logs.
This is the "checks happen as you compile" behavior. It's gated on `checks_enabled`, so a production
build pays nothing, and the analyzers are already warmed.

### Re-check on demand

```julia
check_all()                   # re-check the whole mark-once registry, returns the findings
registered_strict()           # the registry: (f, types) => (; guarantees)
```

## Usage-driven sweep — `check_compiled`

This is the hybrid option: check whatever concrete method instances a module actually compiled,
whether that was during your tests, a run, or precompilation. No annotations needed.

```julia
using MyPkg
# … exercise MyPkg (run your tests / a workload) …
check_compiled(MyPkg; guarantees = (:noalloc, :noboxing))
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
register_strict!(MyPkg.kernel!, (Vector{Float64},); guarantees = (:typestable, :noalloc))
check_all()                                       # the declared guarantees hold…
@test nfailures(audit(MyPkg; require = :public)) == 0   # …and nothing public is undeclared
```

A new public function now cannot ship silently unchecked: either it gets registered with its
guarantees, or it is opted out **visibly** (`@strict_exempt` / the `exempt` kwarg) where a
reviewer can see it. Scope with `only`/`exempt` exactly as in [`check_compiled`](@ref).

## Live feedback with Revise — `watch`

Load [Revise](https://github.com/timholy/Revise.jl) next to StrictMode and you get a live loop:
after each edit, the strict registry is re-checked and any violations print straight to the REPL.
It's the closest thing to a compiler looking over your shoulder as you type.

```julia
using Revise, StrictMode, AllocCheck, JET   # Revise = live loop; AllocCheck+JET = the analysis backend
StrictMode.enable_checks!()    # then restart
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
