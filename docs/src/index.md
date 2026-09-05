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
    details: Say what you want at a call site or a definition — this call must not allocate, this one must stay type-stable — and hear about it the moment it does not hold.
  - title: Catch the silent traps
    details: Two packages. StrictMode reads inferred types and typed IR, and warns. Add StrictModeTest and AllocCheck, JET and TrimCheck prove the same properties and fail your build. Boxing and quietly allocating loops stop being invisible.
  - title: Zero cost when disabled
    details: Checks sit behind a Preferences flag, on by default so dev and test need no setup. Turn it off for a shipped application and each macro compiles to the bare call.
---
```

## Why

Julia will let your code box a value, miss an inline, drift into a type instability, or allocate in
a hot loop — without saying a word. You find out with a profiler, later. StrictMode lets you ask for
those properties out loud, and hear about it the moment one breaks.

## Two packages

Know this first — it decides which macro you write.

**[StrictMode](guarantees.md)** goes in your `Project.toml`. It reads inferred types and typed IR,
needs no other package, and **reports**: it warns where it is guessing, so nothing here breaks your
build.

**[StrictModeTest](proof_tier.md)** goes in your `test/Project.toml`. It brings AllocCheck, JET and
TrimCheck, and **gates**: a violation fails CI. Your users never install those backends just to use
your package.

```text
         write @assert_noalloc          write @test_noalloc
                  │                             │
              StrictMode                  StrictModeTest
           reads typed IR                asks AllocCheck
                  ↓                             ↓
              warns  ⚠                       throws  ✗
         while you iterate                   in your tests
```

The macro you write picks the side. There is no mode to switch.

```julia
@assert_noalloc kernel!(C, A, B)     # StrictMode: the scan — warns
@test_noalloc   kernel!(C, A, B)     # StrictModeTest: AllocCheck's proof — throws
```

> StrictMode grew out of a JuliaCon 2024 talk, *"Why do we need a stricter Julia mode?"* The traps
> that motivated it turned up while tuning a SIMD FFT, where indexing a tuple with a runtime value
> quietly boxed and cost a measured **135× slowdown** — the kind of thing you only ever find by
> profiling.

```julia
using StrictMode

@assert_noalloc    sum(rand(100))         # warns if the call looks like it allocates
@assert_typestable muladd(2.0, 3.0, 1.0)  # throws on an inconcrete return type
@strict            dot(u, v)              # the guarantees a hot path wants, together
```

From here you can follow [Getting Started](getting_started.md) for a walkthrough, read through the
[Guarantees](guarantees.md) one by one, or skip to the [API Reference](api.md).
