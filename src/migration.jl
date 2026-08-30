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

# Names 0.4 DELETED. Unlike the macros above these are a hard break wherever they appear — a
# `UndefVarError` at load — so `src/` is scanned for them too. Measured on the consumers to hand:
# three of eight gate a block of `src/` on `analysis_mode()`/`backend_available()`/`fail_mode()`,
# which stops those packages precompiling at all rather than merely stopping them gating.
const _REMOVED_API = (
    "analysis_mode" => "removed — one engine per package; `checks_enabled()` is the on/off switch",
    "backend_available" => "proofs_loaded()",
    "trimcheck_available" => "proofs_loaded()",
    "BackendUnavailable" => "removed — a proof cannot find its backend missing",
    "check_signatures" => "StrictModeTest.test_signatures",
    "check_compiled" => "StrictModeTest.test_compiled (or StrictMode.audit(mod; sweep = true) to report)",
    "check_all" => "StrictModeTest.test_registered",
    "nsuspect" => "removed — status is :pass/:fail/:info",
    "fail_mode" => "removed — throw-vs-warn is a property of the guarantee",
    "exit_on_fail" => "removed — `audit` reports; StrictModeTest's `test_*` drivers gate",
    "set_ignore_barrier!" => "StrictModeTest.set_ignore_barrier!",
    "divergence_report" => "StrictModeTest.divergence_report",
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
function migration_report(
        pkgdir::AbstractString = pwd();
        dirs = ("test", "benchmark", "bench"), srcdirs = ("src", "ext"), io::IO = stdout
    )
    root = abspath(expanduser(pkgdir))
    _scan(sub, pairs) = begin
        out = Tuple{String, Int, String, Union{Nothing, String}}[]
        isdir(sub) || return out
        for (dir, _, files) in walkdir(sub), file in files
            endswith(file, ".jl") || continue
            path = joinpath(dir, file)
            for (n, line) in enumerate(eachline(path))
                startswith(lstrip(line), '#') && continue
                for (from, to) in pairs
                    # Word-boundary match so `@assert_noalloc` does not also count
                    # `@assert_noallocations`, and `@strict` does not match `@strict_function`.
                    # The LEADING boundary is only added for bare identifiers: `\b` before `@`
                    # never matches, since both sides of that position are non-word characters,
                    # which would silently find zero macros.
                    lead = startswith(from, '@') ? "" : "\\b"
                    occursin(Regex(lead * "\\Q$from\\E\\b"), line) || continue
                    # Every distinct name on the line, not just the first: a single guard line can
                    # reference two deleted names (`analysis_mode() === :fast ||
                    # backend_available()` is the shape three consumers actually use), and
                    # reporting one of them sends the reader back for a second pass.
                    push!(out, (relpath(path, root), n, from, to))
                end
            end
        end
        return out
    end

    # Deleted names are fatal wherever they appear, so every directory is scanned for them.
    broken = vcat((_scan(joinpath(root, d), _REMOVED_API) for d in (srcdirs..., dirs...))...)
    # Reporting macros are only a problem where the PROOF was available — a `src/` annotation
    # correctly reports, since StrictModeTest is not loadable at that package's own precompile.
    disarmed = vcat((_scan(joinpath(root, d), _MIGRATION_MAP) for d in dirs)...)

    if !isempty(broken)
        println(io, "StrictMode 0.4: $(length(broken)) use(s) of DELETED API — these will not load.\n")
        for (path, n, from, to) in broken
            println(io, "  ", path, ":", n, "  ", from, "  →  ", to)
        end
        println(io)
    end
    if isempty(disarmed)
        println(io, "StrictMode 0.4 migration: nothing to change under $(join(dirs, ", "))/.")
    else
        println(io, "StrictMode 0.4: $(length(disarmed)) call site(s) that no longer gate.\n")
        for (path, n, from, to) in disarmed
            println(io, "  ", path, ":", n, "  ", from, isnothing(to) ? "   (no proving counterpart)" : "  →  " * to)
        end
        counts = Dict{String, Int}()
        for (_, _, from, _) in disarmed
            counts[from] = get(counts, from, 0) + 1
        end
        println(io, "\n  by macro: ", join(("$k×$v" for (k, v) in sort!(collect(counts); by = last, rev = true)), ", "))
        println(
            io, "\n  `$(join(srcdirs, "/"))` is scanned only for deleted API: a reporting `@assert_*`",
            "\n  there is correct, since StrictModeTest is not loadable at that package's own precompile."
        )
    end
    return length(broken) + length(disarmed)
end
