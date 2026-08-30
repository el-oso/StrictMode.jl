# The consumer-layout fixture

The arrangement the tier split exists to serve, in miniature, and the only place in this repo where
it is exercised end to end:

- `ConsumerPkg/Project.toml` depends on **`StrictMode` only** — like a real package's own manifest.
- `ConsumerPkg/src/` carries `@strict_function` declarations, checked at **ConsumerPkg's own
  precompile**, where `StrictModeTest` is not loadable by construction.
- `ConsumerPkg/test/Project.toml` adds **`StrictModeTest`**, so the same declarations can be
  re-proved from the test environment.

Run it as its own step — it needs a real precompile of a second package, so it does not belong in
the main suite:

```bash
julia --project=test/consumer/ConsumerPkg -e 'import Pkg; Pkg.instantiate(); Pkg.precompile()'
cd test/consumer/ConsumerPkg && julia --project=. -e 'import Pkg; Pkg.test()'
```

What it pins:

1. `@strict_function` on an allocating body **warns and lets the module load**. A structural guess
   must not be able to break a consumer's precompile, and the proof is unreachable there.
2. `test_signatures` on that same signature, from the test environment, **throws**.
3. Whether the registration survives into the test process. It currently does **not** — a
   `register_strict!` insert executed at ConsumerPkg's precompile is discarded when the module loads
   from its cached pkgimage, so `registered_strict()` is empty there. The test asserts the loud
   empty-registry warning in that case rather than pinning the bug's current side, so it stays
   correct if the registry leg is ever fixed.
