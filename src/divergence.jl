# IP-free fast↔full divergence report.
#
# StrictMode's `:fast` inference heuristic and `:full` AllocCheck/JET proof can disagree on a guarantee
# (rarely, post-F35: the 2026-07-02 corpus study measured 3 residual `:noboxing` under-reports on
# 552 real specializations, zero elsewhere — but `:fast` remains a heuristic, not a proof). When
# they do, a user wants to send
# us a bug report — but their function is proprietary. `divergence_report` runs *both* modes, and on a
# disagreement captures the verdict plus enough **anonymized** context to reproduce and fix the heuristic:
# the type-signature *shape* (user / 3rd-party types → `T1, T2, …`; only `Base`/`Core` names kept), the
# inferred-return *category*, the fired-signal *categories* (counts/booleans, never source), and all
# package/Julia versions. No source code, no user type names, no field values — provably IP-free.

"""
    StrictDivergence

The result of [`divergence_report`](@ref): an IP-free record of where `:fast` and `:full` disagree.
`isempty(d.diverged)` is `true` when the two modes agree. Safe to send to the StrictMode maintainers —
contains no source, no user type names, and no field values. `show` it, or write it with
`StrictMode.save_divergence(d, path)`.
"""
struct StrictDivergence
    diverged::Vector{Tuple{Symbol, Bool, Bool}}   # (guarantee, fast_failed, full_failed)
    signature::String                             # anonymized, e.g. "Tuple{T1, Vector{Float64}, Int64}"
    return_category::String                       # concrete / abstract / small-isbits-union / union / Any / …
    fast_signals::Vector{String}                  # category labels (no source)
    full_signals::Vector{String}
    versions::Vector{Pair{String, String}}
end

Base.isempty(d::StrictDivergence) = isempty(d.diverged)

# ── anonymizer: keep `Base`/`Core` names + parametric structure; map everything else to stable Tn ──
function _anon_type(@nospecialize(T), reg::Dict{Any, String})
    if T isa TypeVar
        return string(T.name)
    elseif T isa Union
        return "Union{" * join((_anon_type(u, reg) for u in Base.uniontypes(T)), ", ") * "}"
    elseif T isa UnionAll
        return _anon_type(Base.unwrap_unionall(T), reg)
    elseif T isa DataType
        m = T.name.module
        public = (m === Base || m === Core)
        head = public ? string(T.name.name) : get!(() -> "T$(length(reg) + 1)", reg, T.name)
        ps = T.parameters
        isempty(ps) && return head
        return head * "{" * join((_anon_param(p, reg) for p in ps), ", ") * "}"
    else
        return _anon_param(T, reg)
    end
end

# value type-parameters: keep structural numerics; redact possibly-IP symbols/strings
function _anon_param(@nospecialize(p), reg::Dict{Any, String})
    p isa Type && return _anon_type(p, reg)
    (p isa Integer || p isa Bool || p isa Char) && return repr(p)
    p isa Symbol && return ":sym"
    p isa AbstractString && return "\"str\""
    return "val"
end

function _anon_signature(@nospecialize(types::Tuple))
    reg = Dict{Any, String}()
    return "Tuple{" * join((_anon_type(T, reg) for T in types), ", ") * "}"
end

function _return_category(@nospecialize(f), @nospecialize(types::Tuple))
    rts = Base.return_types(f, Tuple{types...})
    length(rts) == 1 || return "inference-multiple($(length(rts)))"
    R = only(rts)
    R === Any && return "Any"
    R === Union{} && return "Union{}(bottom)"
    R isa Union && return Base.isbitsunion(R) ? "small-isbits-union" : "union"
    return isconcretetype(R) ? "concrete" : "abstract"
end

function _fast_signals(@nospecialize(f), @nospecialize(types::Tuple))
    s = _alloc_signals(f, types)
    labels = String[]
    s.alloc && push!(labels, "fast:alloc")
    s.boxing && push!(labels, "fast:boxing")
    return labels
end

function _full_signals(@nospecialize(f), @nospecialize(types::Tuple))
    backend_available() || return ["full:backend-unavailable"]
    tt = Tuple{types...}
    labels = String[]
    try
        insts, _ = _checked_allocs(f, types)
        n = length(insts)
        n > 0 && push!(labels, "full:alloc-sites=$n")
        any(_be_is_boxing, insts) && push!(labels, "full:boxing")
    catch
        push!(labels, "full:alloc-analysis-error")
    end
    try
        nr = length(_be_opt_reports(_be_opt_result(f, tt)))
        nr > 0 && push!(labels, "full:jet-reports=$nr")
    catch
        push!(labels, "full:jet-analysis-error")
    end
    return labels
end

function _dep_version(name::Symbol)
    for (_, m) in Base.loaded_modules
        if nameof(m) === name
            v = pkgversion(m)
            return v === nothing ? "loaded(unknown version)" : string(v)
        end
    end
    return "not-loaded"
end

function _version_block()
    sm = pkgversion(@__MODULE__)
    return [
        "julia" => string(VERSION),
        "StrictMode" => (sm === nothing ? "dev" : string(sm)),
        "AllocCheck" => _dep_version(:AllocCheck),
        "JET" => _dep_version(:JET),
        "TypeContracts" => _dep_version(:TypeContracts),
        "TrimCheck" => _dep_version(:TrimCheck),
    ]
end

"""
    divergence_report(f, types; guarantees = (:typestable, :noalloc, :noboxing, :inlined)) -> StrictDivergence

Run StrictMode's `:fast` heuristic and `:full` proof on `f` for the concrete signature `types`, and
return a [`StrictDivergence`](@ref) capturing every guarantee where the two **disagree** (one says pass,
the other fail). The result is **IP-free** — anonymized signature shape, signal *categories*, and
versions only — so you can send it to us to fix the heuristic.

`isempty(result)` is `true` when the modes agree. `f` is never called.

```julia
d = divergence_report(myfun, (MyType, Vector{Float64}))
isempty(d) || StrictMode.save_divergence(d, "strictmode_divergence.txt")  # email us this file
```
"""
function divergence_report(
        @nospecialize(f), @nospecialize(types::Tuple);
        guarantees = (:typestable, :noalloc, :noboxing, :inlined),
    )
    ff = findings(f, types; guarantees, mode = :fast)
    fl = findings(f, types; guarantees, mode = :full)
    fmap = Dict(x.guarantee => (x.status === :fail) for x in ff)
    lmap = Dict(x.guarantee => (x.status === :fail) for x in fl)
    diverged = Tuple{Symbol, Bool, Bool}[]
    for g in guarantees
        a = get(fmap, g, false)
        b = get(lmap, g, false)
        a != b && push!(diverged, (g, a, b))
    end
    return StrictDivergence(
        diverged, _anon_signature(types), _return_category(f, types),
        _fast_signals(f, types), _full_signals(f, types), _version_block(),
    )
end

function Base.show(io::IO, d::StrictDivergence)
    if isempty(d)
        print(io, "StrictDivergence: none — :fast and :full agree")
        return
    end
    println(io, "StrictDivergence — :fast and :full disagree (IP-free; safe to send to the StrictMode maintainers)")
    println(io, "  signature    : ", d.signature)
    println(io, "                 (Base/Core types kept; user / 3rd-party types anonymized as T1, T2, …)")
    println(io, "  return       : ", d.return_category)
    for (g, a, b) in d.diverged
        println(io, "  ", rpad(string(g), 15), "fast=", a ? "FAIL" : "pass", "   full=", b ? "FAIL" : "pass")
    end
    println(io, "  fast signals : ", isempty(d.fast_signals) ? "(none)" : join(d.fast_signals, ", "))
    println(io, "  full signals : ", isempty(d.full_signals) ? "(none)" : join(d.full_signals, ", "))
    return print(io, "  versions     : ", join(("$k=$v" for (k, v) in d.versions), ", "))
end

"""
    StrictMode.save_divergence(d::StrictDivergence, path) -> path

Write the IP-free [`StrictDivergence`](@ref) report to `path` (plain text) for emailing to the
maintainers. No source, no user type names — only the anonymized signature shape, signal categories,
and versions.
"""
function save_divergence(d::StrictDivergence, path::AbstractString)
    open(path, "w") do io
        show(io, d)
        println(io)
    end
    return path
end
