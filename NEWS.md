# StrictMode.jl release notes

## v0.3.2

Bugfix, non-breaking.

- **`@assert_noalloc` empirical path no longer false-fails on a `gc_num` accounting artifact (F33).**
  `@allocated` measures the `Base.gc_num().allocd` delta, which can be **nonzero with no real heap
  allocation** — an artifact seen on SIMD / `GC.@preserve`-heavy kernels that AllocCheck and
  `--track-allocation` both prove allocation-free (found dogfooding PureFFT's Butterfly256/512 AVX
  kernels). The `:fast` / `static = false` path previously failed whenever `@allocated > 0`, so it could
  reject provably-clean hot paths. It now **escalates to AllocCheck** when the analysis backend is loaded:
  it fails only if AllocCheck *also* finds a real allocation site; if AllocCheck proves the call clean, the
  number is treated as an artifact and the check passes (with a one-shot `@warn`). With no backend it still
  fails, but the message names the artifact possibility and points at `:full`. Real allocations continue to
  fail through the escalation. See `FEEDBACK.md` F33.

## v0.3.1

Additive, non-breaking: a new opt-in guarantee, a new diagnostic, and an optional weak dependency.


- **`trim_compatible` guarantee** — an exposed, *escalating* `juliac --trim=safe` compatibility guarantee
  (`@assert_trim_compatible` / `:trim_compatible`). In `:fast` (or when `TrimCheck` is not loaded) it runs
  the TypeContracts static IR scan; in `:full` with the new optional **`TrimCheck`** weak dependency it runs
  juliac's authoritative `verify_typeinf_trim` verifier over the exact signature; its output is parsed into
  deduplicated, source-mapped findings via `TypeContracts.TrimDiagnostics` (the same formatter `explain_trim`
  uses). Advisory and **opt-in** (not part of `@strict`). The existing `@assert_trim_safe` / `:trimsafe`
  remain as the static-only subset.

- **`divergence_report(f, types)`** — runs the `:fast` heuristic *and* the `:full` proof and, where they
  disagree on a guarantee, returns an **IP-free** [`StrictDivergence`](@ref): an anonymized signature shape
  (user / 3rd-party types → `T1, T2, …`; `Base`/`Core` names kept), the fired-signal **categories**
  (counts/booleans, never source), the inferred-return category, and all package/Julia versions. Send it to
  the maintainers to fix a heuristic gap. `StrictMode.save_divergence(d, path)` writes it to a file.

- New weak dependency + extension: `TrimCheck` → `StrictModeTrimExt` (the `:full` trim backend).
  `StrictMode.trimcheck_available()` reports whether it is loaded.
