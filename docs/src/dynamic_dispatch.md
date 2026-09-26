# [Dynamic dispatch](@id dynamic-dispatch)

A dynamic dispatch is a call Julia resolves at run time instead of at compile time. It buys
flexibility and costs static resolution: no inlining across it, no constant folding through it, a
boxed result, and `juliac --trim=safe` rejects it. Outside a hot loop that trade is usually fine.
Inside one it is expensive, and the numbers below say how expensive.

This page explains when a call goes dynamic, how to see it
([`dispatch_report`](@ref)), and which fixes actually work. Every figure here was measured on Julia
1.13.0; the fixtures live in `StrictMode/test/dispatch_test.jl`.

## The cost, measured

The same work over 1000 elements, dispatching once per element:

| Container | Time | Allocated |
|---|---|---|
| `Vector{Op}` — abstract element type | 24.02 µs | 32 000 B |
| `Vector{Union{O1,O2,O3,O4}}` | **0.58 µs** | **0 B** |
| `Vector{O1}` — concrete | **0.58 µs** | **0 B** |

A `Union` element type is as fast as a concrete one here, because inference enumerates the members
and emits one branch each. That is *union splitting*, and it is static code.

One dispatch is cheap. A thousand are not: dispatching once and then looping inside a specialized
method measured no slower than a fully static loop.

## What makes a call dynamic

Inference resolves a call while at most `max_methods` methods match it — **3** by default, from
`Base.Compiler.InferenceParams()`. The fourth matching method turns the call dynamic:

| Situation | Result | Return type |
|---|---|---|
| Argument typed as a `Union` of concrete types (2–6 members tested) | union split, static | concrete |
| Argument typed abstractly, **1–3** methods match | static, branches inlined | concrete |
| Argument typed abstractly, **4+** methods match | **dynamic dispatch** | `Any` |
| The same 4-method case with `Base.Experimental.@max_methods 4` in the module | static again | concrete |

Two consequences are worth knowing before reading any finding.

**The declaration is not the cause.** `f(x::Op)` called with a concrete `O1` is specialized and
static — Julia specializes on the argument's *actual* type. Instability comes from a value whose
type the caller does not know: an element of an abstractly typed container, an abstract field, or a
non-`const` global.

**The cliff is non-local.** A call matching exactly 3 methods is static today. A fourth method added
*anywhere in any package* makes it dynamic, with no edit to the calling code.
[`dispatch_report`](@ref) lists those call sites under "AT THE LIMIT" for exactly this reason.

## The causes StrictMode names

A `:typestable` finding names the declaration to edit, not just that the body is unstable:

| Cause | What it means | Fix |
|---|---|---|
| `captured_variable` | a closure captured a reassigned local, so it lives in a `Core.Box` and every read is `Any` | assign once, bind a fresh one with `let`, or hold the state in a typed `Ref` |
| `nonconst_global` | reads an untyped non-`const` global, which infers as `Any` | make it `const`; for changing state, `const x = Ref(v)` or a typed binding `global x::Int` |
| `abstract_field` | reads a field declared with an abstract type, including `::Function` | parametrize the struct: `struct S{T}; x::T; end` |
| `abstract_eltype` | a payload of an abstractly typed container flows into the body — `Vector{Any}`, `Dict{String,Any}`, `Ref{Any}`, a loosely typed `Tuple` | give the container a concrete payload type, or a `Union` of the concrete types it holds |
| `reflection` | calls `return_types`, `invokelatest`, `which`, `methods` | compute the type at the call site, or move the query to load time |
| `runtime_type_parameter` | builds a type from a value known only at run time (`ntuple(f, n)`, `Val(n)`) | push that value into the type domain at the boundary |
| `method_count` | more methods match the call than `max_methods` | fewer methods, a `Union` of concrete types, or raise the limit where the callee lives |

Order matters, because instability propagates. A widened global makes every downstream call match a
huge method set, so the global is named and the method count is not: the first cause reported is the
root, not its symptoms. A cause is reported only for a body that is actually unstable — declaring
`f(v::Vector{Real})` and calling `length(v)` is perfectly stable, and gets no finding and no cause.

## Raised limits are honored

`Base.Experimental.@max_methods N` can raise the limit for a module or a function.
[`dispatch_report`](@ref) reads the limit that applies to each callee, so a four-method call in a
module that raised the limit to four is reported as *at the limit*, not as dynamic — and a
three-method one there is not flagged at all.

## What does not work

Two fixes that sound right and are not:

- **`f(s::S) where {S<:Shape}`** — measured: the return type stayed `Any` and the call stayed
  dynamic. A type parameter cannot recover a type the caller never had.
- **A function barrier, as a stability fix** — the outer frame still returns `Any` and still holds
  one dynamic call. A barrier is worth it to stop dispatching *per element*, not to make the caller
  stable, and a dynamic call already lands in a specialized method, so the gain is only where the
  dispatch would otherwise repeat.

## Trim compatibility

`:trim_compatible` is stricter than speed. juliac's verifier rejects a call it cannot resolve, and it
also rejects a call whose union split exceeds its reachability limit (`max_union_splitting`, 4). So a
wide `Union` can fix speed and still fail a trimmed build. For code that must trim, prefer a concrete
element type, or keep the `Union` small.

## Seeing where you stand

```julia
julia> using StrictMode

julia> dispatch_report(MyPkg)
MyPkg — dispatch (max_methods = 3)

DYNAMIC (1)
  total(Vector{Shape})       shapes.jl:10    area — 4 methods match, limit 3

AT THE LIMIT (1)
  measure(Vector{Shape})     shapes.jl:22    area — 3 methods match, limit 3 — one more flips it

CLEAR: 14 specialization(s) with no dynamic or at-the-limit call
```

The sweep covers what has actually compiled, exactly like [`audit`](@ref)`(mod; sweep = true)`. A
function called only with concrete arguments is reported as clear, because that is what its compiled
code does.

## In an audit

`audit(MyPkg; sweep = true)` carries the same sites as informational findings
(`guarantee = :dispatch`, `status = :info`), so an agent or a CI job reads them as JSON alongside the
guarantees. They never count as failures: a dynamic call may be exactly what you intended, and an
at-the-limit call is not wrong at all today — but neither is visible any other way, which is why they
are on by default. Pass `dispatch_suggest = false` to skip the pass; it costs one extra typed-IR read
per specialization (17.8% of a 10,974-specialization sweep, which reported no findings at all).
