# Key concepts

StrictMode's guarantees enforce properties that Julia performance relies on. This page explains
what those properties are and why they matter — useful background before the
[Guarantees](guarantees.md) reference.

## Type stability

A function is **type-stable** when the compiler can determine the return type from the argument
types alone, without running the function. With a known concrete return type, the compiler
generates tight machine code and can chain optimizations across calls.

**Type instability** produces a `Union` or `Any` return. Every downstream operation then needs to
check the type at runtime before it can do anything useful:

```julia
function pick(items, i)
    items[i]          # items = (1, 2.0, "three") → return is Union{Int64,Float64,String}
end
```

The compiler can't predict which branch will run, so downstream code pays a dispatch tax on
every use of the result. `@assert_typestable` and `@strict` catch this.

## Boxing

**Boxing** is what happens when the compiler can't eliminate a Union: it wraps the value in a
heap-allocated container so it can be passed around as an opaque object. Unboxing later costs a
heap lookup and a runtime type-check per value.

In a tight numeric loop, the difference between boxed and unboxed is often 100× or more. The
most common cause is indexing a heterogeneous tuple with a runtime index:

```julia
t = (1.0, 2, "three")
for i in 1:3
    x = t[i]    # x is boxed — the compiler doesn't know which element type it gets
end
```

The fix is `@unroll`, which replaces the runtime index with compile-time literals:

```julia
@unroll for i in 1:3
    x = t[i]    # expands to t[1], t[2], t[3] — each a known concrete type
end
```

`@assert_noboxing` and `@assert_noalloc` catch boxing. `@explain` identifies which access is the
source.

## Dynamic dispatch

**Dynamic dispatch** is a function call resolved at runtime instead of compile time. It happens
when the compiler doesn't know the concrete type of the receiver, so it can't select the method
at compile time and must look it up during execution.

```julia
function apply(f, x)
    f(x)    # if f's concrete type is unknown, every call pays a table lookup
end
```

In hot loops, even one dynamic dispatch per iteration can dominate. Type-unstable code usually
triggers it: once a value's type is a Union, everything downstream dispatches dynamically.
`@assert_noboxing` catches it because the JIT-level evidence is the same boxing pattern.

## SIMD vectorization

Modern CPUs process 4–16 floating-point values per instruction (AVX-512: 8 doubles at once).
**SIMD vectorization** — Single Instruction, Multiple Data — is the compiler generating those
instructions automatically for loops over contiguous data.

Things that block it: data-dependent branches, non-sequential memory, function calls the
compiler can't inline, and type instability. A loop that looks vectorized often isn't.

`@assert_vectorized` checks that the compiled output actually contains vector instructions.
`kernel_report` explains *why* a vectorized kernel is still slow — arithmetic intensity,
alignment, register pressure.

## How they interact

These four issues cascade. A single root cause can trigger all of them:

1. A heterogeneous tuple gets indexed at runtime → **type instability**
2. The compiler can't track the type → the value is **boxed**
3. Downstream operations can't select a method statically → **dynamic dispatch**
4. The loop carries an opaque value → **no SIMD**

Fixing the root cause (often the type instability) eliminates all four. `@explain` shows which
layer is the actual source, and `@strict` / `@kernel` confirm all four are resolved.
