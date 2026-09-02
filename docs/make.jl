using Documenter
using DocumenterVitepress
using StrictMode
# `StrictModeTest` is deliberately absent: every live `@example` block here uses StrictMode's own
# value-free engine, which is what a reader gets from a plain `[deps] StrictMode`. The `@test_*`
# surface is shown as non-executed `julia` blocks.

makedocs(;
    modules = [StrictMode],
    sitename = "StrictMode.jl",
    authors = "el_oso",
    format = DocumenterVitepress.MarkdownVitepress(
        devbranch = "master",
        devurl = "dev",
        repo = "github.com/el-oso/StrictMode.jl",
        sidebar_drawer = true
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
