using Documenter
using DocumenterVitepress
using StrictMode

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
    pages = [
        "Home" => "index.md",
        "Getting Started" => "getting_started.md",
        "Guarantees" => "guarantees.md",
        "Cookbook" => "cookbook.md",
        "API Reference" => "api.md",
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
