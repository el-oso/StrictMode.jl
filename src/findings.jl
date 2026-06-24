# Reporting layer. The drivers (`check`, `check_all`, `check_compiled`) all produce a flat list of
# `StrictFinding`s; formatters render that list for each sink — `:text` for humans (Revise), and
# `:json` / `:jsonlines` / `:github` for agents and CI. One source of truth, many sinks.

"""
    StrictFinding

A single guarantee result for one `(function, signature)`. Flat and serializable so the same
record feeds the human (`:text`) and agent (`:json`) reporting paths.

Fields: `mod`, `func`, `signature`, `guarantee` (`:typestable`/`:noalloc`/`:noboxing`/`:inlined`),
`status` (`:fail`/`:pass`/`:skip`), `file`, `line`, `reason`, `suggestion`.
"""
struct StrictFinding
    mod::Symbol
    func::String
    signature::String
    guarantee::Symbol
    status::Symbol
    file::String
    line::Int
    reason::String
    suggestion::String
end

# Actionable fix hint per guarantee — the structured equivalent of what `@explain` tells a human.
function _suggestion(guarantee::Symbol)
    guarantee === :noboxing && return "boxing / runtime tuple index: use @unroll for fixed-size loops, or dispatch the size into a Val{N} type parameter."
    guarantee === :typestable && return "type instability: annotate the unstable variable, split the method, or push sizes/flags into the type domain (Val). Note: small isbits unions (Union{T,Nothing}, Union{T,Missing}) are accepted — only heap-allocating unions fail."
    guarantee === :noalloc && return "allocation in a hot path: preallocate the buffer, use @views for slices, or @unroll to avoid boxing."
    guarantee === :inlined && return "not inlined: add @inline to the callee, or accept it (inlining is a heuristic)."
    guarantee === :vectorized && return "did not vectorize: try @inbounds @simd / @simd ivdep, or assert on the leaf kernel (SIMD may be in a non-inlined callee). Use kernel_report for arithmetic-intensity diagnostics."
    guarantee === :no_scalar_loops && return "scalar hot loop (FP or integer) in a numeric path: wrap it in @inbounds @simd / SIMD.jl, or reuse an existing vectorized kernel of the same shape — unaudited glue loops leak time between audited kernels (F20/F22)."
    guarantee === :trimsafe && return "trim-unsafe call: make every call statically resolvable — concrete arg/return types, no Any/abstract containers, no runtime reflection (return_types/which/methods). juliac --trim=safe is authoritative."
    return ""
end

_failed(f::StrictFinding) = f.status === :fail

"""
    nfailures(findings) -> Int

The number of failing findings in a `Vector{StrictFinding}` (as returned by [`check`](@ref),
[`check_all`](@ref), [`check_compiled`](@ref), or [`audit`](@ref)). Use it for the exit-code
loop: `exit(nfailures(audit(MyPkg)))`.
"""
nfailures(fs::AbstractVector{StrictFinding}) = count(_failed, fs)

# Single-line REPL display.
function Base.show(io::IO, f::StrictFinding)
    mark = f.status === :fail ? "✗" : (f.status === :pass ? "✓" : "•")
    print(io, "[", mark, " ", f.guarantee, "] ", f.func, f.signature)
    f.status === :fail && print(io, " — ", f.reason)
    return nothing
end

# --- formatters -------------------------------------------------------------------------------

const _FORMATS = (:text, :json, :jsonlines, :github)

"""
    format_findings(io, findings; format = :text, only_failures = false)

Render `findings` to `io` in one of `$(_FORMATS)`. `:text` is the human/REPL rendering; the
others are machine-readable for agents and CI.
"""
function format_findings(io::IO, findings::AbstractVector{StrictFinding}; format::Symbol = :text, only_failures::Bool = false)
    fs = only_failures ? filter(_failed, findings) : findings
    format === :text && return _fmt_text(io, fs)
    format === :json && return _fmt_json(io, fs)
    format === :jsonlines && return _fmt_jsonlines(io, fs)
    format === :github && return _fmt_github(io, fs)
    throw(ArgumentError("unknown format $format; expected one of $(_FORMATS)"))
end

# Convenience: no-IO method returns the rendered findings as a String (so callers can `println`/log
# without building an IOBuffer). Mirrors the usual Julia `sprint`-style ergonomics for `format_*`.
function format_findings(findings::AbstractVector{StrictFinding}; kwargs...)
    io = IOBuffer()
    format_findings(io, findings; kwargs...)
    return String(take!(io))
end

function _fmt_text(io::IO, fs)
    if isempty(fs)
        println(io, "StrictMode: ✓ no findings.")
        return nothing
    end
    nf = nfailures(fs)
    println(io, "StrictMode: ", length(fs), " finding(s), ", nf, " failing.")
    for f in fs
        println(io, "  ", f)
        if _failed(f)
            f.file != "" && println(io, "      at ", f.file, ":", f.line)
            println(io, "      → ", f.suggestion)
        end
    end
    return nothing
end

# Minimal JSON string escaping (no dependency).
function _json_str(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\r'
            print(io, "\\r")
        elseif c < ' '
            print(io, "\\u", lpad(string(UInt16(c); base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return nothing
end

function _json_obj(io::IO, f::StrictFinding)
    print(io, "{")
    pairs = (
        ("module", string(f.mod)), ("function", f.func), ("signature", f.signature),
        ("guarantee", string(f.guarantee)), ("status", string(f.status)),
        ("file", f.file), ("reason", f.reason), ("suggestion", f.suggestion),
    )
    for (k, v) in pairs
        _json_str(io, k)
        print(io, ":")
        _json_str(io, v)
        print(io, ",")
    end
    print(io, "\"line\":", f.line, "}")
    return nothing
end

function _fmt_json(io::IO, fs)
    print(io, "[")
    for (i, f) in enumerate(fs)
        i > 1 && print(io, ",")
        _json_obj(io, f)
    end
    println(io, "]")
    return nothing
end

function _fmt_jsonlines(io::IO, fs)
    for f in fs
        _json_obj(io, f)
        println(io)
    end
    return nothing
end

function _fmt_github(io::IO, fs)
    for f in fs
        _failed(f) || continue
        loc = f.file != "" ? "file=$(f.file),line=$(f.line)" : ""
        println(io, "::error ", loc, "::StrictMode @", f.guarantee, " ", f.func, f.signature, " — ", f.reason)
    end
    return nothing
end
