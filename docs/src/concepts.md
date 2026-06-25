# Key concepts

StrictMode's guarantees enforce properties that Julia performance relies on. This page explains
what those properties are and why they matter — useful background before the
[Guarantees](guarantees.md) reference.

## Type stability

A function is **type-stable** when the compiler can determine the return type from the argument
types alone, without running the function. With a known concrete return type, the compiler
generates tight machine code and can chain optimizations across calls.

**Type instability** produces a `Union` or `Any` return — the compiler doesn't know which type
it's dealing with until the function actually runs:

```julia
function pick(items, i)
    items[i]          # items = (1, 2.0, "three") → return is Union{Int64,Float64,String}
end
```

```text
JIT compiles pick(items, i):
                    │
      ┌─────────────┴───────────────┐
 return type known              return type unknown
 (always Float64)               (Union / Any)
      │                              │
  Native code:                  Generic slow path:
  vmulsd, vaddsd…               allocate a "box" on the heap
  ~1 ns/call                    check type at runtime
                                 ~100 ns/call
```

`@assert_typestable` and `@strict` catch the unstable path.

## Boxing

**Boxing** is what the compiler does when it can't predict a value's type: it wraps the value in
a heap-allocated container — a "box" — with a type tag, so it can be handled generically at
runtime. Unboxing it later costs a heap lookup and a type-check per value.

```text
Unboxed (type-stable path — fast):
┌────────┬────────┬────────┬────────┐
│  1.0   │  2.0   │  3.0   │  4.0   │  ← raw 64-bit doubles, contiguous in memory
└────────┴────────┴────────┴────────┘

Boxed (type-unknown path — slow):
┌────────┬────────┬────────┬────────┐
│  ptr   │  ptr   │  ptr   │  ptr   │  ← each element is a pointer to a heap object
└───┬────┴───┬────┴────────┴────────┘
    ↓        ↓
┌───────┐ ┌───────┐
│ tag   │ │ tag   │   ← type tag checked at runtime before every use
│ 1.0   │ │ 2.0   │
└───────┘ └───────┘
```

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
    x = t[i]    # expands to t[1], t[2], t[3] — each a known concrete type, no box
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

In hot loops, even one dynamic dispatch per iteration can dominate runtime. Type-unstable code
usually triggers it: once a value is boxed, everything downstream dispatches dynamically.
`@assert_noboxing` catches it because the JIT-level evidence is the same boxing pattern.

## SIMD vectorization

Modern CPUs have special **vector registers** that are wider than a single number. Instead of
holding one `Float64`, they hold 4 or 8 at once. A single CPU instruction can then operate on
all values simultaneously. This is **SIMD** — Single Instruction, Multiple Data.

The two common widths on modern x86 CPUs:
- **AVX2** (most laptops and servers since ~2013): 256-bit registers → 4 doubles or 8 floats per instruction
- **AVX-512** (newer server and desktop CPUs): 512-bit registers → 8 doubles or 16 floats per instruction

```text
Scalar loop — one value per CPU instruction:
  step 1:  a[0] × b[0] → c[0]
  step 2:  a[1] × b[1] → c[1]   ← 4 separate multiply instructions
  step 3:  a[2] × b[2] → c[2]
  step 4:  a[3] × b[3] → c[3]

SIMD loop (AVX2) — 4 values per CPU instruction:
  step 1:  ┌a[0]┐   ┌b[0]┐   ┌c[0]┐
           │a[1]│ × │b[1]│ = │c[1]│   ← 1 vmulpd instruction, same clock cost
           │a[2]│   │b[2]│   │c[2]│
           └a[3]┘   └b[3]┘   └c[3]┘

Result: 4× the arithmetic done in the same number of clock cycles.
```

**Why SIMD matters independently of multi-threading.** Adding threads spreads work across
CPU cores — but each core still processes one value at a time without SIMD. SIMD makes *each
core* faster; threading runs more cores in parallel. They multiply:

```text
4-core CPU with AVX2 (4 doubles/instruction):

  Without SIMD, with 4 threads:   4 cores × 1 double/instr  =  4 doubles per clock
  With SIMD, 1 thread:            1 core  × 4 doubles/instr =  4 doubles per clock
  With SIMD, 4 threads:           4 cores × 4 doubles/instr = 16 doubles per clock  ← full throughput
```

A program that uses threads but not SIMD, running on a 4-core AVX2 machine, is leaving 75% of
its compute unused. Threads and SIMD are complementary — you need both to saturate the hardware.

Julia's compiler generates SIMD instructions automatically — but only when the loop structure
allows it: no data-dependent branches, sequential memory access, no unresolved function calls,
and type-stable element types. A loop that looks vectorized often isn't.

`@assert_vectorized` checks that the compiled output actually contains vector instructions.
`kernel_report` explains *why* a vectorized kernel might still be slow — arithmetic intensity,
alignment, register pressure.

## If you're coming from C, C++, or Java

You already know the underlying model. The Julia concepts map directly to things you've worked
with — the key difference is that Julia infers types rather than requiring declarations.

**Type stability ↔ concrete return types.**

```cpp
// C++: void* return forces a runtime cast — same overhead as Julia's Union return
void* pick_unstable(int i);       // caller must cast; no inlining opportunity
double pick_stable(double x);     // concrete return → inlined, no overhead
```

```java
// Java: Object return means a cast on every use
Object pick(Object[] arr, int i) { return arr[i]; }   // generic, slow
double dot(double[] a, double[] b) { ... }            // concrete, fast
```

In Julia, no declaration is needed — the JIT infers the return type. If it can't
(`Union{Float64,Int64}` for example), you silently get the `void*`/`Object` slow path.
`@assert_typestable` catches that before you hit the profiler.

**Boxing ↔ Java autoboxing.**

```java
// Java: autoboxing int → Integer allocates on the heap in a hot loop
Integer sum = 0;
for (int v : values) sum += v;   // each += boxes and unboxes ← slow

int sum = 0;
for (int v : values) sum += v;   // no boxing ← fast, same as Julia's unboxed path
```

Julia boxes for the same reason Java does: when the JIT can't track the concrete type, it falls
back to a heap-allocated wrapper. `@assert_noboxing` catches it the same way a JVM profiler
flags `Integer` allocations in hot code.

**Dynamic dispatch ↔ virtual calls without devirtualization.**

```cpp
// C++: virtual dispatch is a vtable lookup per call; devirtualization needs a concrete type
struct Base { virtual double f() = 0; };
void hot_loop(Base* b) { b->f(); }     // table lookup every call — can't inline
void hot_loop(Derived* d) { d->f(); }  // concrete type → devirtualized, inlined
```

Julia dispatches the same way. With concrete types the JIT devirtualizes and inlines; with
abstract or Union types it falls back to a runtime lookup. `@assert_noboxing` flags the cases
where devirtualization didn't happen.

**SIMD ↔ `-O3 -march=native` / intrinsics.**

```cpp
// C++: auto-vectorizes given no aliasing, no branches, concrete element type
for (int i = 0; i < n; i++) c[i] = a[i] * b[i];   // → vmulpd with -O3 -march=native
```

Julia's autovectorizer has the same requirements as GCC/Clang. `@assert_vectorized` checks the
compiled IR the same way you'd scan `objdump -d` for `ymm`/`zmm` registers. `kernel_report`
gives the arithmetic intensity and alignment signals you'd get from VTune or `perf`.

The surprise for C++/Java developers: Julia achieves the same performance without declarations,
but the trap is when inference silently fails and nothing tells you. StrictMode is that signal.

## If you're coming from Python or MATLAB

The key insight: Julia looks like Python or MATLAB, but compiles to native machine code — *if*
it can figure out the types. When it can't, it silently falls back to something as slow as a
Python loop.

**Why Julia loops can be fast where Python loops can't.**

In Python, every value is wrapped in a Python object with a type tag. When you write a loop,
the interpreter processes one object at a time, checking types at every step:

```text
Python loop over [1.0, 2.0, 3.0, 4.0]:

iteration 1: unwrap PyObject → check it's a float → multiply → wrap result in new PyObject
iteration 2: unwrap PyObject → check it's a float → multiply → wrap result in new PyObject
...
overhead on every single step
```

NumPy avoids this by storing raw numbers without wrappers, then dispatching to **BLAS** (Basic
Linear Algebra Subprograms) — external C and Fortran libraries that were compiled ahead of time,
ship as static `.so`/`.dll` files, and never change at runtime. They know exactly what types
they'll receive (`double*` arrays), so they can use CPU vector instructions directly. The speed
comes from those pre-compiled routines, not from Python. The limitation: BLAS handles a fixed
set of operations (dot products, matrix multiply, etc.) — you can't add your own.

Julia's JIT generates that same native code for *your own loops* on the fly — no pre-compiled
library required — but only when the types are stable:

```python
# Python loop: slow — interprets one object at a time
def dot(a, b):
    return sum(a[i] * b[i] for i in range(len(a)))

# NumPy: fast — dispatches to BLAS (static pre-compiled C/Fortran), operates on raw doubles
import numpy as np
result = np.dot(a, b)
```

```julia
# Julia: fast when types are stable — JIT generates native code directly
function dot(a::Vector{Float64}, b::Vector{Float64})
    s = 0.0
    for i in eachindex(a)
        s += a[i] * b[i]   # compiles to vmulsd/vaddsd — same as the C inside NumPy
    end
    s
end
```

**Boxing — Python objects vs contiguous arrays.**

```text
Python list [1.0, 2.0, 3.0]:          Julia Vector{Float64} / NumPy float64:

 ptr    ptr    ptr                      ┌──────┬──────┬──────┐
  │      │      │                       │ 1.0  │ 2.0  │ 3.0  │
  ↓      ↓      ↓                       └──────┴──────┴──────┘
┌─────┐┌─────┐┌─────┐                  raw 64-bit doubles, no wrappers
│type ││type ││type │
│ 1.0 ││ 2.0 ││ 3.0 │  ← three separate heap objects, type-checked on every access
└─────┘└─────┘└─────┘
```

When Julia silently boxes values in a loop, it produces the Python-list layout — even though
the source code looks nothing like Python. `@assert_noboxing` catches it.

**SIMD — what makes numeric code fast.**

```text
Without SIMD (what a Python loop does — one number at a time):
  multiply(1.0, 4.0) → 4.0
  multiply(2.0, 5.0) → 10.0    ← one multiplication per CPU instruction
  multiply(3.0, 6.0) → 18.0

With SIMD (what Julia, NumPy, and MATLAB's matrix ops do):
  multiply([1.0, 2.0, 3.0, 4.0], [4.0, 5.0, 6.0, 7.0])
      → [4.0, 10.0, 18.0, 28.0]                          ← four multiplications, one instruction
```

```matlab
% MATLAB: fast because A*B dispatches to BLAS/LAPACK — external libraries
% compiled ahead of time in C and Fortran, shipped as static binaries.
% They know the types (double matrices), so they use vector instructions directly.
C = A * B;        % → BLAS dgemm — highly optimized, static, processes 8+ values per instruction
for i = 1:n       % → scalar loop — MATLAB's own JIT may vectorize, but may not
    c(i) = a(i) * b(i);
end
```

BLAS and LAPACK (Linear Algebra PACKage) are the same pre-compiled static libraries that
power NumPy, MATLAB, R, and most scientific computing tools. They are incredibly fast, but
they only cover a fixed set of dense linear algebra operations.

Julia's JIT generates equivalent native code for *your own loops* — not just matrix multiply —
but only when the loop is type-stable and the memory access is sequential.
`@assert_vectorized` confirms the vector instructions are actually there.

The surprise: a Julia loop can run as fast as MATLAB's `A*B` — or 100× slower — depending
entirely on whether the JIT could infer the types. The source code looks identical either way.
StrictMode is the check that tells you which path you're actually on.

## How they interact

These four issues cascade. A single root cause can trigger all of them:

1. A heterogeneous tuple gets indexed at runtime → **type instability**
2. The compiler can't track the type → the value is **boxed**
3. Downstream operations can't select a method statically → **dynamic dispatch**
4. The loop carries an opaque value → **no SIMD**

Fixing the root cause (often the type instability) eliminates all four. `@explain` shows which
layer is the actual source, and `@strict` / `@kernel` confirm all four are resolved.
