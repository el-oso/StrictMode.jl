```@raw html
---
layout: home

hero:
  name: StrictMode.jl
  text: Loud guarantees for fast Julia
  tagline: Make correct-and-fast the default; make falling off the fast path a loud error.
  actions:
    - theme: brand
      text: Getting Started
      link: /getting_started
    - theme: alt
      text: Guarantees
      link: /guarantees
    - theme: alt
      text: API Reference
      link: /api
    - theme: alt
      text: View on GitHub
      link: https://github.com/el-oso/StrictMode.jl

features:
  - title: Force the fast path
    details: Declarative macros assert no-alloc and type-stable at a call site or a definition — fail loudly when the property does not hold.
  - title: Tell you when you fell off
    details: A thin, unified interface over AllocCheck, JET and @inferred — the silent traps (boxing, instability, hot-loop allocations) become explicit errors.
  - title: Zero cost when disabled
    details: Every check is gated behind a Preferences compile-time flag. Off by default, macros expand to the bare call. Production pays nothing.
---
```

## Why

Julia stays *silent* when your code boxes, fails to inline, becomes type-unstable, or allocates
in a hot loop — Rust errors instead. Each trap is invisible until you profile. StrictMode turns
them into **loud, declarable, opt-in guarantees**.

> This package is the sequel to the JuliaCon 2024 talk *"Why do we need a stricter Julia mode?"*
> The motivating traps came from optimizing a SIMD FFT, where runtime tuple indexing silently
> boxed and cost a **measured 135× slowdown** — invisible until profiled.

```julia
using StrictMode

@assert_noalloc    sum(rand(100))         # fails if the call allocates
@assert_typestable muladd(2.0, 3.0, 1.0)  # fails on type instability
@strict            dot(u, v)              # all per-call guarantees at once
```

Head to [Getting Started](getting_started.md), browse the [Guarantees](guarantees.md) guide, or
jump to the [API Reference](api.md).
