# Migration & cookbook

## From sweep-and-exempt to strict-by-default

Early StrictMode left you to *sweep* a module (`audit(M; sweep=true)`) and then hand-maintain an
`exempt` list of by-design-allocating cold helpers — noisy, and the exemptions lived at the call
site, not with the code. The modern model inverts it: make the module strict in one line and opt
the cold code *out* at its definition.

| Before (sweep-and-exempt) | After (strict-by-default) |
|---|---|
| `audit(M; sweep=true, exempt=[:_plan, :_setup, …])` | `@strict module M … end` + `@strict_exempt` on the cold defs |
| exemptions maintained in the audit call | exemption travels with the definition |
| every method swept (noisy: cold helpers flagged) | only declared-hot violations reported |
| must remember to run the sweep | checked automatically when the module loads |

```julia
# before
module M
    kernel(x) = …
    _plan(n) = collect(1:n)
end
# … and in tests:
audit(M; sweep = true, exempt = [:_plan])

# after
@strict module M
    kernel(x::Int) = …                  # hot, checked
    @strict_exempt _plan(n::Int) = collect(1:n)   # cold, opted out at the definition
end
```

CI still gets the rigorous proof: run `audit(M; sweep = true)` (or `check_all`) in `:full` mode.
Day-to-day, the `:fast` load check and the incremental cache keep it near-instant.

## Performance trap → which guarantee catches it

| Trap | Symptom | Guarantee |
|---|---|---|
| Runtime tuple indexing (`t[i]`, heterogeneous `t`) | `Union` return, silent boxing | `@assert_noboxing` / `@unroll` to fix |
| Type-unstable return | `Union`/`Any` return | `@assert_typestable` |
| Captured-variable boxing | `Core.Box`, lost inference | `@assert_noboxing` |
| Allocating hot loop / `push!` / `collect` | heap traffic, GC pressure | `@assert_noalloc` |
| Allocate scratch but never box | runtime dispatch only | `@assert_noboxing` (allows the buffer) |
| Accidental dynamic dispatch | runtime dispatch | `@assert_noboxing` / `@assert_noalloc` |
| Call that should inline but doesn't | call overhead | `@assert_inlined` |
| Whole module that must stay fast | any of the above | `@strict module` (hot by default) |
| Intentionally-allocating cold helper | by-design allocation | `@strict_exempt` (opt out) |
| A guaranteed-fast function that must never regress | a future edit reintroduces a trap | `@strict_function` |

## Speed knobs

- `enable_checks!(analysis = "fast")` — value-free triage of *all* properties, no AllocCheck/JET
  backend, ~10× cheaper per method. `:full` is the AllocCheck proof for CI.
- The `findings` cache makes a re-`audit` after a one-method edit near-instant
  ([`cache_stats`](@ref) / [`clear_cache!`](@ref)).
- `:fast` `check_all`/`check_compiled`/`audit` run across threads when `Threads.nthreads() > 1`.
