# Guarantees

Every example here is live. The docs are built with checks enabled, so the analysis runs as the
page is generated. Calls that pass are shown as real `@example` blocks; calls that are meant to
fail are shown as annotated code, so the build itself stays green.

```@example guide
using StrictMode
```

## `@assert_noalloc` — no heap allocations

For this one, StrictMode hands the call to [AllocCheck.jl](https://github.com/JuliaLang/AllocCheck.jl)
and asks it to prove there's no way the call can allocate. Dynamic dispatch and boxing both show up
as allocations, so they get caught here as well.

```@example guide
dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]

@assert_noalloc dot3((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
```

When static analysis can't run on a call, `static = false` falls back to measuring it directly
with `@allocated`, after a warmup pass:

```julia
@assert_noalloc static = false stream_step!(buffer, x)   # measures @allocated, not a static proof
```

An allocating hot loop gets turned away:

```julia
function grow_and_sum(n)
    v = Int[]              # allocates
    for i in 1:n
        push!(v, i)        # …and grows
    end
    return sum(v)
end

@assert_noalloc grow_and_sum(10)
# ERROR: StrictViolation (@noalloc): guarantee not satisfied
#   target:  grow_and_sum(10)
#   reason:  call provably allocates (… site(s)): …
```

## `@assert_noboxing` — forbid boxing, allow buffers

[`@assert_noboxing`](@ref) is the easygoing cousin of `@assert_noalloc`. It only objects to the
allocations that come from type uncertainty: boxing (the runtime-tuple-index trap, or a captured
variable wrapped in a `Core.Box`) and dynamic dispatch. Honest typed heap allocations are fine by
it. Reach for it on a hot path that's allowed to allocate a working buffer but must never box.

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

That same call doesn't get past `@assert_noalloc`, which forbids allocation of any kind:

```julia
@assert_noalloc fill_sum(3)
# ERROR: StrictViolation (@noalloc): call provably allocates … Vector{Float64} …
```

Boxing and dynamic dispatch, though, are still out:

```julia
boxy(t) = (s = 0.0; for i in 1:3; s += t[i]; end; s)   # heterogeneous tuple, runtime index
@assert_noboxing boxy((1, 2.0, 3.0f0))
# ERROR: StrictViolation (@noboxing): call boxes / dynamically dispatches …
#   Allocating runtime call to "jl_get_nth_field_checked" …
```

Because it has to classify each allocation, it always runs the static AllocCheck analysis, and so
it ignores the `:fast` [`analysis_mode`](@ref).

## `@assert_typestable` — concrete, stable types

This one pairs two checks: `Test.@inferred` insists the return type is concrete, and
`JET.@report_opt` insists there's no instability or runtime dispatch hiding inside.

```@example guide
affine(x) = 2x + 1

@assert_typestable affine(3.0)
```

Runtime tuple indexing, the trap that keeps coming up, produces a `Union` return type and boxes.
It doesn't pass:

```julia
state = (1, 2.0, "three")     # heterogeneous tuple
component(s, i) = s[i]        # i is a runtime value → Union{Int,Float64,String}

@assert_typestable component(state, rand(1:3))
# ERROR: StrictViolation (@typestable): guarantee not satisfied
#   target:  component(state, rand(1:3))
#   reason:  return type is not concretely inferrable: …
```

## `@assert_inlined` — keep the call on the fast path (best-effort)

[`@assert_inlined`](@ref) fails unless the compiler actually inlined the call. To find out,
StrictMode compiles a tiny wrapper around it and reads the optimized IR: if the call is still
sitting there as an `:invoke`, it wasn't absorbed, and the assert fails.

Inlining is a heuristic, not a promise, so this one is best-effort by nature. A failure only means
the compiler chose not to inline under the current settings, which may or may not matter to you.
That's why it isn't part of [`@strict`](@ref).

```julia
@inline   hot(x) = x * x + 1
@assert_inlined hot(3.0)        # ok: small, inlined

@noinline cold(x) = x * x + 1
@assert_inlined cold(3.0)
# ERROR: StrictViolation (@inlined): call to `cold` was not inlined — it survives as an `:invoke` …
```

## `@strict` — every per-call guarantee at once

[`@strict`](@ref) checks type stability first, since that's usually what's behind a surprise
allocation, and then allocation-freedom. It returns the call's value, so you can drop it in around
an expression you already have:

```@example guide
saxpy(a, x, y) = a .* x .+ y

result = @strict saxpy(2.0, (1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
```

## `@strict_function` — verify a definition at load time

Put it on a definition and StrictMode checks that definition against its declared argument types,
at precompile or module-load time. A clean one loads like any other:

```@example guide
@strict_function scaled(a::Float64, x::NTuple{3, Float64}) = a .* x

scaled(2.0, (1.0, 2.0, 3.0))
```

If some later edit makes it allocate or go unstable, the module won't load at all. It's the same
forcing function you'd get from Rust's compiler:

```julia
@strict_function leaky(n::Int) = sum(collect(1:n))   # collect allocates
# ERROR: StrictViolation (@strict_function): call provably allocates …

@strict_function maybe(x::Int) = x > 0 ? x : 1.0     # Union{Int,Float64} return
# ERROR: StrictViolation (@strict_function): return type is not concrete …
```

Signatures with abstract argument types or varargs can't be pinned down statically. Those emit a
one-time warning and fall back to call-site [`@strict`](@ref) checks instead.

## Interfaces + performance with TypeContracts

[`@strict_contract`](@ref) declares a [TypeContracts.jl](https://github.com/el-oso/TypeContracts)
interface that also carries performance guarantees, and [`@verify_strict`](@ref) checks both sides
of an implementation: that it has the right methods, and that those methods are fast.

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

An implementation that has the right methods but allocates is turned down:

```julia
struct SlowMetric end
score(::SlowMetric, xs::AbstractVector{<:Real}) = sum(collect(xs))   # allocates

@verify_strict SlowMetric begin
    score(SlowMetric(), [1.0, 2.0, 3.0])
end
# ERROR: StrictViolation (@noalloc): guarantee not satisfied …
```

## `@unroll` — force the fast path

The assert macros tell you after the fact that you boxed. [`@unroll`](@ref) keeps it from
happening in the first place. When a loop's trip count is known at macro time, it unrolls the loop
completely and swaps the loop variable for a literal on each pass, so `t[i]` becomes
`t[1]; t[2]; …`. A heterogeneous tuple then gets indexed type-stably, with no boxing. Unlike the
asserts it isn't gated behind the checks flag; the unrolling always happens.

This is the trap that started the whole project. The naive loop is type-stable, returning a
concrete `Float64`, and it still allocates, because the runtime tuple index boxes. It's the exact
thing `@assert_noalloc` is there to catch:

```@example guide
htup = (1, 2.0, 3.0f0)

function naive(t)
    acc = 0.0
    for i in 1:3
        acc += t[i]          # runtime index over a heterogeneous tuple → boxes
    end
    return acc
end

function unrolled(t)
    acc = 0.0
    @unroll for i in 1:3
        acc += t[i]          # → acc += t[1]; t[2]; t[3]   (literal, no boxing)
    end
    return acc
end

(naive(htup), unrolled(htup), @allocated(naive(htup)), @allocated(unrolled(htup)))
```

Both give the same answer, but only the naive loop allocates, so the guarantee passes for the
unrolled version and not the other:

```@example guide
@assert_noalloc unrolled(htup)
```

```julia
@assert_noalloc naive(htup)
# ERROR: StrictViolation (@noalloc): call provably allocates …
#   [2] Allocating runtime call to "jl_get_nth_field_checked" in ./tuple.jl:33
```

When the size lives only in a type, you can lift it into the type domain with [`staticval`](@ref)
and splice the literal into `@unroll` from a `@generated` method:

```julia
@generated function tuple_sum(t::Tuple)
    N = length(t.parameters)
    quote
        acc = zero(promote_type(t.parameters...))
        @unroll for i in 1:$N        # $N is a literal inside the generated body
            acc += t[i]
        end
        acc
    end
end
```

## `@explain` — tell me *why*

When an assert fails, you usually want to know why, not just that it did. [`@explain`](@ref)
gathers `@code_warntype`, JET's `@report_opt`, and AllocCheck into a single [`StrictReport`](@ref),
and unlike the asserts it never throws. It just returns the report, which the REPL prints for you;
assign it if you want to poke at the individual fields.

A clean call comes back all green:

```@example guide
clean(a, b) = 0.5a + 0.5b

@explain clean(2.0, 4.0)
```

And the runtime tuple-index trap gets pulled apart: the non-concrete return type, the boxing
allocation site, the `@code_warntype` body, and a verdict for each guarantee:

```julia
state = (1, 2.0, "three")
component(s, i) = s[i]

@explain component(state, rand(1:3))
# StrictMode @explain — component(state, rand(1:3))
#
#   Return type:    Union{Float64, Int64, String}  ✗ not concrete
#   Allocations:    ✗ 1 site(s) (AllocCheck):
#     [1] Allocating runtime call to "jl_get_nth_field_checked" in ./tuple.jl:33 …
#
#   Verdict:
#     ✗ @assert_typestable would fail
#     ✗ @assert_noalloc would fail
```
