# 0.4 migration aid. The break is silent by construction — every `StrictMode` macro kept its
# spelling, so a consumer's call sites compile and run unchanged and merely stop deciding the build.
# A rename would have been caught by the compiler; this is the tool that stands in for that.

# Guarantee macros whose StrictMode form REPORTS, paired with the StrictModeTest form that proves.
# Keyed by the macro's spelling, which is not derivable from the guarantee symbol (`:trimsafe` is
# `@assert_trim_safe`, and the composites are named for the bundle rather than a guarantee).
const _MIGRATION_MAP = (
    "@assert_noalloc" => "@test_noalloc",
    "@assert_noboxing" => "@test_noboxing",
    "@assert_no_scalar_loops" => nothing,
    "@assert_trim_safe" => "@test_trim_compatible",
    "@assert_trim_compatible" => "@test_trim_compatible",
    "@strict" => "@test_strict",
    "@kernel" => "@test_kernel",
)

"""
    migration_report(pkgdir = pwd(); dirs = ("test", "benchmark", "bench"), io = stdout) -> Int

List every call site under `dirs` whose guarantee stopped gating in 0.4, with the macro that
restores it. Returns the number of sites found.

Only these directories are scanned, deliberately. A `@assert_*` in `src/` is **correct as it
stands**: it runs at the annotated package's own precompile, where `StrictModeTest` is not loadable
by construction, so reporting is the only thing it can do. It is the copies in test and benchmark
suites — where the proofs *are* available and gating is the whole point — that silently became
non-gating.

`@assert_no_scalar_loops` has no proving counterpart (its check is a best-effort LLVM-IR pattern
match with no authoritative oracle), so it is reported for visibility with no replacement.

```julia
using StrictMode
migration_report("~/src/MyPkg.jl")
```
"""
function migration_report(pkgdir::AbstractString = pwd(); dirs = ("test", "benchmark", "bench"), io::IO = stdout)
    root = abspath(expanduser(pkgdir))
    hits = Tuple{String, Int, String, Union{Nothing, String}}[]
    for d in dirs
        sub = joinpath(root, d)
        isdir(sub) || continue
        for (dir, _, files) in walkdir(sub), file in files
            endswith(file, ".jl") || continue
            path = joinpath(dir, file)
            for (n, line) in enumerate(eachline(path))
                startswith(lstrip(line), '#') && continue
                for (from, to) in _MIGRATION_MAP
                    # Word-boundary match so `@assert_noalloc` does not also count
                    # `@assert_noallocations`, and `@strict` does not match `@strict_function`.
                    occursin(Regex("\\Q$from\\E\\b"), line) || continue
                    push!(hits, (relpath(path, root), n, from, to))
                    break                     # one hit per line; the longest name wins by map order
                end
            end
        end
    end
    if isempty(hits)
        println(io, "StrictMode 0.4 migration: nothing to change under $(join(dirs, ", "))/.")
        return 0
    end
    println(io, "StrictMode 0.4 migration: $(length(hits)) call site(s) that no longer gate.\n")
    for (path, n, from, to) in hits
        println(io, "  ", path, ":", n, "  ", from, isnothing(to) ? "   (no proving counterpart)" : "  →  " * to)
    end
    counts = Dict{String, Int}()
    for (_, _, from, _) in hits
        counts[from] = get(counts, from, 0) + 1
    end
    println(io, "\n  by macro: ", join(("$k×$v" for (k, v) in sort!(collect(counts); by = last, rev = true)), ", "))
    println(
        io, "\n  `src/` is deliberately not scanned: a reporting `@assert_*` there is correct, since",
        "\n  StrictModeTest is not loadable at the annotated package's own precompile."
    )
    return length(hits)
end
