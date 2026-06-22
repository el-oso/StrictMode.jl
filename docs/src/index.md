```@raw html
---
layout: home

hero:
  name: StrictMode.jl
  text: Loud guarantees for fast Julia
  tagline: Fast by default, and loud the moment you slip off it — not something you discover by profiling.
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
  - title: Ask for the fast path
    details: Say what you want at a call site or a definition — this call should not allocate, this one should stay type-stable — and get an error the moment it doesn't.
  - title: Catch the silent traps
    details: A thin layer over AllocCheck, JET, and @inferred. The things Julia normally lets slide, like boxing or a hot loop that quietly allocates, become errors you can actually see.
  - title: Zero cost when disabled
    details: Every check sits behind a Preferences flag, off by default. When it's off the macros vanish into the bare call, so a production build carries none of it.
---
```

## Why

Julia will happily let your code box a value, miss an inline, drift into a type instability, or
allocate inside a hot loop, and it won't say a word. Rust would have stopped you at compile time.
In Julia each of these stays invisible until you go hunting for it with a profiler. StrictMode lets
you ask for those properties out loud: declare what you expect, and hear about it right away when
something breaks the promise.

> StrictMode grew out of a JuliaCon 2024 talk, *"Why do we need a stricter Julia mode?"* The traps
> that motivated it turned up while tuning a SIMD FFT, where indexing a tuple with a runtime value
> quietly boxed and cost a measured **135× slowdown** — the kind of thing you only ever find by
> profiling.

```julia
using StrictMode

@assert_noalloc    sum(rand(100))         # fails if the call allocates
@assert_typestable muladd(2.0, 3.0, 1.0)  # fails on type instability
@strict            dot(u, v)              # all per-call guarantees at once
```

From here you can follow [Getting Started](getting_started.md) for a walkthrough, read through the
[Guarantees](guarantees.md) one by one, or skip to the [API Reference](api.md).
