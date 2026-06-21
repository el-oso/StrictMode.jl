# Automating checks

Sprinkling `@assert_*` macros at call sites is precise but tedious. This page covers the easier
paths: a function API that never interferes with other macros, marking a whole module once,
automatic checking at load, and a live Revise loop. (For AI agents, see [Agentic feedback](agents.md).)

## The function API — `check`

[`check`](@ref) runs the guarantees on a `(function, signature)` pair. It is a plain function
call, so unlike the macros it can never collide with broadcasting, nested macros, or keyword
arguments — reach for it whenever a macro would get in the way, and as the programmatic entry
point for tooling.

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

Nothing is executed — the analysis is purely from the types — so `check` works even for calls
you would not want to actually run.

## Mark once

Instead of annotating call sites, tag the definitions you care about and let the drivers check
them.

- [`@strict_function`](@ref) already registers each concrete definition it guards.
- **`@strict module … end`** marks a whole module: every definition with a concrete signature is
  registered, and the module is checked automatically when it loads.

```julia
@strict module Kernels        # use at true top level (script / REPL / package)
    dot3(a::NTuple{3,Float64}, b::NTuple{3,Float64}) = a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
    # a definition that boxes or allocates here makes the module fail to load (in :error mode)
end
```

### Auto-check at load

When a strict-marked module loads **and** checks are enabled, StrictMode runs its checks
automatically and reports per [`fail_mode`](@ref) (`:error` → the module won't load; `:warn` →
logs). This is the "automatic when compiling" behavior. It is gated on `checks_enabled`, so a
production build pays nothing, and the analyzers are pre-warmed by the PrecompileTools workload.

### Re-check on demand

```julia
check_all()                   # re-check the whole mark-once registry, returns the findings
registered_strict()           # the registry: (f, types) => (; guarantees)
```

## Usage-driven sweep — `check_compiled`

The hybrid half: check whatever concrete method instances a module **actually compiled** (during
your tests, a run, or precompilation) — no annotation needed.

```julia
using MyPkg
# … exercise MyPkg (run your tests / a workload) …
check_compiled(MyPkg; guarantees = (:noalloc, :noboxing))
```

Coverage is whatever executed, and it is best-effort (it walks compiler reflection defensively),
but it needs zero marks.

## Live feedback with Revise — `watch`

Loading [Revise](https://github.com/timholy/Revise.jl) alongside StrictMode enables a live loop:
after each edit, the strict registry is re-checked and violations print to the REPL — the
"compiler shouts as you code" experience.

```julia
using Revise, StrictMode
StrictMode.enable_checks!()    # then restart
# … using MyPkg, which marks its kernels strict …
StrictMode.watch()             # start the loop
# edit a kernel so it boxes, save:
#   StrictMode: 1 finding(s), 1 failing.
#     [✗ noalloc] dot3(NTuple{3,Float64}, NTuple{3,Float64}) — allocates (1 site(s))
#         → preallocate the buffer, use @views for slices, or @unroll to avoid boxing.
StrictMode.unwatch()           # stop
```

`watch` is the *human* feedback path. An AI agent wants a one-shot, structured result instead —
that is [`audit`](@ref), covered in [Agentic feedback](agents.md).
