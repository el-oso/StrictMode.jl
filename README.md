# StrictMode.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://el-oso.github.io/StrictMode.jl/dev/)
[![CI](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/el-oso/StrictMode.jl/actions/workflows/CI.yml)
[![Coverage](https://coveralls.io/repos/github/el-oso/StrictMode.jl/badge.svg?branch=master)](https://coveralls.io/github/el-oso/StrictMode.jl?branch=master)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**The fast path should be the default, and leaving it should be loud, not something you discover
later with a profiler.**

This repository holds two packages: [**StrictMode**](StrictMode) analyzes with a value-free engine
and reports, and [**StrictModeTest**](StrictModeTest) adds the AllocCheck, JET and TrimCheck proofs
and gates your build. Which one runs is the macro you wrote — `@assert_noalloc` is the scan,
`@test_noalloc` is the proof.

Start with the [documentation](https://el-oso.github.io/StrictMode.jl/dev/):
[getting started](https://el-oso.github.io/StrictMode.jl/dev/getting_started),
[guarantees](https://el-oso.github.io/StrictMode.jl/dev/guarantees),
[API reference](https://el-oso.github.io/StrictMode.jl/dev/api).

```julia
using Pkg
Pkg.add("StrictMode")        # analysis and reporting
Pkg.add("StrictModeTest")    # the proofs, in your test/ environment
```

## Development

StrictMode is developed with the assistance of [Claude Code](https://claude.com/claude-code).
Generated code is reviewed before it lands, and the design decisions, the measurements behind them,
and the released behavior are the maintainer's own.

## License

MIT.
