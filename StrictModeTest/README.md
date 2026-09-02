# StrictModeTest.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/StrictMode.jl/dev/)
[![CI](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE)

**The proofs for [StrictMode](../StrictMode).** Add it to your test environment and the same
guarantees stop being guesses.

```julia
# test/Project.toml:  [deps] StrictMode, StrictModeTest
Pkg.add("StrictModeTest")
```

## Why it's a separate package

StrictMode runs fast heuristics on Base's own inference, so it needs no analysis backend and can
warn without ever breaking your build. That's what you want in `src`, where a false alarm would stop
your package precompiling.

Once you're in `test/` you can afford the real thing. StrictModeTest pulls in AllocCheck, JET and
TrimCheck, and its checks throw, so a violation fails the build. Keeping them apart means your users
never install the heavy backends just to use your package.

## Which one runs

Whichever macro you wrote. There's no mode to switch and nothing ambient deciding for you:

```julia
@assert_noalloc kernel!(C, A, B)     # StrictMode's scan — warns
@test_noalloc   kernel!(C, A, B)     # AllocCheck's all-paths proof — throws
```

| warns (StrictMode) | throws (StrictModeTest) | what does the proving |
|---|---|---|
| `@assert_noalloc` | `@test_noalloc` | AllocCheck, over every path |
| `@assert_noboxing` | `@test_noboxing` | AllocCheck, boxing instances only |
| `@assert_typestable` | `@test_typestable` | inference, plus `JET.@report_opt` |
| `@assert_trim_compatible` | `@test_trim_compatible` | juliac's own `verify_typeinf_trim` |

## Gating more than one call

You can prove a list of signatures, or sweep whatever your package actually compiled:

```julia
test_signatures([(dot3, (NTuple{3,Float64}, NTuple{3,Float64}))])
test_compiled(MyPkg)                      # everything that compiled
test_compiled(MyPkg; exempt = r"^_plan")  # …minus the cold helpers
test_registered()                         # re-prove every @strict_function declaration
```

Each one collects all the failures and raises once, so a single method it can't analyze doesn't hide
the rest. `proof_audit(MyPkg)` gives you the same findings without throwing, and `divergence_report`
compares the scan against the proof when you want to know where they disagree.

It refuses to load if StrictMode's checks are turned off. With them off nothing registers, and a
sweep would pass by checking nothing at all.

## Documentation

- [API reference](https://el-oso.github.io/StrictMode.jl/dev/api#The-proof-tier-StrictModeTest) — the proof tier
- [Guarantees](https://el-oso.github.io/StrictMode.jl/dev/guarantees) — what each check means
- [Automating checks](https://el-oso.github.io/StrictMode.jl/dev/automating) — sweeps and CI

## License

MIT.
