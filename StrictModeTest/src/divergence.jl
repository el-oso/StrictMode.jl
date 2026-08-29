# IP-free scan-vs-proof divergence report.
#
# StrictMode's value-free scan and this package's AllocCheck/JET proof can disagree on a guarantee
# (rarely, post-F35: the 2026-07-02 corpus study measured 3 residual `:noboxing` under-reports on
# 552 real specializations, zero elsewhere — but the scan remains a heuristic, not a proof). When
# they do, a user wants to send
# us a bug report — but their function is proprietary. `divergence_report` runs *both* engines, and on a
# disagreement captures the verdict plus enough **anonymized** context to reproduce and fix the heuristic:
# the type-signature *shape* (user / 3rd-party types → `T1, T2, …`; only `Base`/`Core` names kept), the
# inferred-return *category*, the fired-signal *categories* (counts/booleans, never source), and all
# package/Julia versions. No source code, no user type names, no field values — provably IP-free.

"""
    StrictDivergence

The result of [`divergence_report`](@ref): an IP-free record of where the scan and the proof disagree.
`isempty(d.diverged)` is `true` when the two engines agree. Safe to send to the StrictMode maintainers —
contains no source, no user type names, and no field values. `show` it, or write it with
`StrictModeTest.save_divergence(d, path)`.
"""
struct StrictDivergence
    diverged::Vector{Tuple{Symbol, Bool, Bool}}   # (guarantee, scan_failed, proof_failed)
    signature::String                             # anonymized, e.g. "Tuple{T1, Vector{Float64}, Int64}"
    return_category::String                       # concrete / abstract / small-isbits-union / union / Any / …
    scan_signals::Vector{String}                  # category labels (no source)
    proof_signals::Vector{String}
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

function _scan_signals(@nospecialize(f), @nospecialize(types::Tuple))
    s = StrictMode._alloc_signals(f, types)
    labels = String[]
    s.alloc && push!(labels, "scan:alloc")
    s.boxing && push!(labels, "scan:boxing")
    return labels
end

function _proof_signals(@nospecialize(f), @nospecialize(types::Tuple))
    labels = String[]
    try
        insts, _ = _checked_allocs(f, types)
        n = length(insts)
        n > 0 && push!(labels, "proof:alloc-sites=$n")
        any(_is_boxing, insts) && push!(labels, "proof:boxing")
    catch
        push!(labels, "proof:alloc-analysis-error")
    end
    try
        nr = length(_opt_reports("divergence", f, types))
        nr > 0 && push!(labels, "proof:jet-reports=$nr")
    catch
        push!(labels, "proof:jet-analysis-error")
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
    sm = pkgversion(StrictMode)
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

Run StrictMode's value-free scan and this package's proof on `f` for the concrete signature `types`, and
return a [`StrictDivergence`](@ref) capturing every guarantee where the two **disagree** (one says pass,
the other fail). The result is **IP-free** — anonymized signature shape, signal *categories*, and
versions only — so you can send it to us to fix the heuristic.

`isempty(result)` is `true` when the engines agree. `f` is never called.

```julia
d = divergence_report(myfun, (MyType, Vector{Float64}))
isempty(d) || StrictModeTest.save_divergence(d, "strictmode_divergence.txt")  # email us this file
```
"""
function divergence_report(
        @nospecialize(f), @nospecialize(types::Tuple);
        guarantees = (:typestable, :noalloc, :noboxing, :inlined),
    )
    ff = StrictMode.findings(f, types; guarantees)
    fl = _proof_findings(f, types, guarantees)
    # `_failed`, not a hand-written status comparison: one predicate decides what counts, and treating
    # that as "did not flag" would report a divergence for every one of them — the exact inverse of
    # what this function is for. What matters here is whether the engine flagged the call at all.
    fmap = Dict(x.guarantee => StrictMode._failed(x) for x in ff)
    lmap = Dict(x.guarantee => StrictMode._failed(x) for x in fl)
    diverged = Tuple{Symbol, Bool, Bool}[]
    for g in guarantees
        a = get(fmap, g, false)
        b = get(lmap, g, false)
        a != b && push!(diverged, (g, a, b))
    end
    return StrictDivergence(
        diverged, _anon_signature(types), _return_category(f, types),
        _scan_signals(f, types), _proof_signals(f, types), _version_block(),
    )
end

function Base.show(io::IO, d::StrictDivergence)
    if isempty(d)
        print(io, "StrictDivergence: none — the scan and the proof agree")
        return
    end
    println(io, "StrictDivergence — the scan and the proof disagree (IP-free; safe to send to the StrictMode maintainers)")
    println(io, "  signature    : ", d.signature)
    println(io, "                 (Base/Core types kept; user / 3rd-party types anonymized as T1, T2, …)")
    println(io, "  return       : ", d.return_category)
    for (g, a, b) in d.diverged
        println(io, "  ", rpad(string(g), 15), "scan=", a ? "FAIL" : "pass", "   proof=", b ? "FAIL" : "pass")
    end
    println(io, "  scan signals : ", isempty(d.scan_signals) ? "(none)" : join(d.scan_signals, ", "))
    println(io, "  proof signals: ", isempty(d.proof_signals) ? "(none)" : join(d.proof_signals, ", "))
    return print(io, "  versions     : ", join(("$k=$v" for (k, v) in d.versions), ", "))
end

"""
    StrictModeTest.save_divergence(d::StrictDivergence, path) -> path

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
