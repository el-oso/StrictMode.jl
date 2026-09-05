using Documenter
using DocumenterVitepress
using StrictMode
using StrictModeTest
# Both packages are documented here, since both are registered. The live `@example` blocks still
# use StrictMode's own value-free engine — that is what a reader gets from a plain `[deps]
# StrictMode` — and the `@test_*` surface stays in non-executed `julia` blocks, so nothing in these
# pages depends on the proof tier running.

makedocs(;
    modules = [StrictMode, StrictModeTest],
    sitename = "StrictMode.jl",
    authors = "el_oso",
    format = DocumenterVitepress.MarkdownVitepress(
        devbranch = "master",
        devurl = "dev",
        repo = "github.com/el-oso/StrictMode.jl",
        sidebar_drawer = true,
        # The repository root is not a package, so Documenter cannot read a version from it.
        inventory_version = string(pkgversion(StrictMode))
    ),
    # Grouped rather than flat: ten top-level entries overflowed the navbar. Only the two entry
    # points a first-time reader needs stay at the top level; the rest nest one level down.
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Learn" => [
            "Key Concepts" => "concepts.md",
            "Tutorial" => "tutorial.md",
            "Cookbook" => "cookbook.md",
        ],
        "Reference" => [
            "Guarantees" => "guarantees.md",
            "StrictModeTest" => "proof_tier.md",
            "API Reference" => "api.md",
        ],
        "In practice" => [
            "Automating checks" => "automating.md",
            "Performance diagnostics" => "performance_diagnostics.md",
            "Agentic feedback" => "agents.md",
        ],
    ],
    checkdocs = :exports,
    warnonly = [:missing_docs],
    remotes = nothing,
    doctest = false,
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/el-oso/StrictMode.jl",
    devbranch = "master",
    push_preview = true,
)
