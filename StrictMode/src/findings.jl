# Reporting layer. Every driver — StrictMode's `findings`/`audit` and `StrictModeTest`'s `test_*` —
# produces a flat list of
# `StrictFinding`s; formatters render that list for each sink — `:text` for humans (Revise), and
# `:json` / `:jsonlines` / `:github` for agents and CI. One source of truth, many sinks.

"""
    StrictFinding

A single guarantee result for one `(function, signature)`. Flat and serializable so the same
record feeds the human (`:text`) and agent (`:json`) reporting paths.

Fields: `mod`, `func`, `signature`, `guarantee` (`:typestable`/`:noalloc`/`:noboxing`/`:owned`/
`:inlined`/…), `status`, `file`, `line`, `reason`, `suggestion`, `tier`.

`status` is one of:
- `:pass` / `:fail` — a verdict to act on. A guarantee the analysis could not evaluate is `:fail`
  carrying the error text, never `:pass`: "could not check" and "is fine" must not render the same.
- `:info` — advisory, never a failure ([`inline_suggestions`](@ref)/[`static_ownership_suggestions`](@ref)).

`policy` names where the requirement was written — the `@strict_policy` or `@strict_function` line
that asked for this guarantee — and is empty for a declaration made by a plain `register_strict!`
call, which is a function and cannot see its caller. A reader who can see the rule can narrow it,
turn it off, or exempt the method; one who cannot has to go looking for it.

`tier` says how much a `:fail` is worth, and it is a field because a finding outlives the session
that made it: `:report` is StrictMode's value-free engine, whose allocation verdicts are structural
guesses that nothing gates on, and `:proof` is `StrictModeTest`'s AllocCheck/JET/TrimCheck, which
its drivers do gate. A saved `:jsonlines` file read by another process, or by another session, has
no other way to tell a guess from a proof.

[`key`](@ref) is the identity of a finding across runs, and [`findings_diff`](@ref) compares two
runs by it.
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
    tier::Symbol
    code::Symbol
    policy::String
end

# The reporting tier and the guarantee's own code are the defaults, so the shorter forms keep their
# meaning: every construction site inside StrictMode is a value-free verdict, and a site that has
# narrowed the cause passes the cause's code instead (see `StrictMode._code`).
StrictFinding(mod, func, signature, guarantee, status, file, line, reason, suggestion, tier) =
    StrictFinding(
    mod, func, signature, guarantee, status, file, line, reason, suggestion, tier,
    _code(guarantee), ""
)

StrictFinding(
    mod, func, signature, guarantee, status, file, line, reason, suggestion, tier, code
) = StrictFinding(
    mod, func, signature, guarantee, status, file, line, reason, suggestion, tier, code, ""
)

StrictFinding(mod, func, signature, guarantee, status, file, line, reason, suggestion) =
    StrictFinding(mod, func, signature, guarantee, status, file, line, reason, suggestion, :report)

# Actionable fix hint per guarantee — the structured equivalent of what `@explain` tells a human.
# A `:typestable` suggestion narrowed to the declaration that caused the instability. The numbers
# come from the measured comparison in `docs/src/dynamic_dispatch.md`.
function _cause_suggestion(cause::Symbol)
    cause === :captured_variable && return "a closure captured a local that is reassigned, so it is held in a `Core.Box`: assign the captured value once (or bind a fresh one with `let`), or hold the mutable state in a concretely typed `Ref`."
    cause === :nonconst_global && return "make the binding `const`; for state that must change, `const x = Ref(value)` or a typed binding (`global x::Int`) keeps the read concrete. Passing the value in as an argument works too."
    cause === :abstract_field && return "parametrize the struct so the field has a concrete type: `struct S{T}; x::T; end`. A field holding a callable is the same problem — parametrize it rather than declaring `::Function`."
    cause === :abstract_eltype && return "give the container a concrete element type, or a `Union` of the concrete types it holds — a `Union` element type splits statically (measured over 1000 elements: 0.58 µs / 0 B, against 24.02 µs / 32 kB for an abstract one). Keep the `Union` small if the call must also stay trim-compatible."
    cause === :reflection && return "reflection cannot be resolved statically: compute the type at the call site, or move the query to load time."
    cause === :runtime_type_parameter && return "the type is built from a value known only at run time: push that value into the type domain at the boundary (`Val(n)` created once from a literal, or a type parameter on the caller) so the size/flag is a compile-time constant."
    cause === :method_count && return "reduce the methods matching this call to `max_methods` or fewer, narrow the argument to a `Union` of concrete types, or raise the limit where the callee lives with `Base.Experimental.@max_methods N`. Adding `where {T<:Abstract}` does NOT help — it cannot recover a type the caller does not have."
    return ""
end

function _suggestion(guarantee::Symbol)
    guarantee === :noboxing && return "boxing / runtime tuple index: use @unroll for fixed-size loops, or dispatch the size into a Val{N} type parameter."
    guarantee === :owned && return "runtime AbstractDict lookup on owned scratch (static-ownership violation): replace the keyed dictionary probe with a const-dispatched, per-concrete-type accessor (a Ref/field owned by the type)."
    guarantee === :trusted && return "payload of an Untrusted value read outside a trust boundary: move the read into a validating function that returns a plain value, and register it with `trust_boundary!`."
    guarantee === :typestable && return "type instability: annotate the unstable variable, split the method, or push sizes/flags into the type domain (Val). Note: small isbits unions (Union{T,Nothing}, Union{T,Missing}) are accepted — only heap-allocating unions fail."
    guarantee === :noalloc && return "allocation in a hot path: preallocate the buffer, use @views for slices, or @unroll to avoid boxing."
    guarantee === :inlined && return "not inlined: add @inline to the callee, or accept it (inlining is a heuristic)."
    guarantee === :vectorized && return "did not vectorize: try @inbounds @simd / @simd ivdep, or assert on the leaf kernel (SIMD may be in a non-inlined callee). Use kernel_report for arithmetic-intensity diagnostics."
    guarantee === :no_scalar_loops && return "scalar hot loop (FP or integer) in a numeric path: wrap it in @inbounds @simd / SIMD.jl, or reuse an existing vectorized kernel of the same shape — unaudited glue loops leak time between audited kernels."
    guarantee === :no_spill && return "vector register spill: reduce the live accumulator/tile count (register-block a smaller tile), or split the kernel into multiple passes. See register_report for zmm-saturation diagnostics."
    guarantee === :trim_compatible && return "trim-incompatible call: make every call statically resolvable — concrete arg/return types, no Any/abstract containers, no runtime reflection (return_types/invokelatest/which/methods). StrictModeTest's @test_trim_compatible runs the same verifier; with `set_juliac_patches!(true)` it checks the patched Base juliac compiles, and without it some code juliac builds clean is rejected here."
    return ""
end

_failed(f::StrictFinding) = f.status === :fail

"""
    nfailures(findings) -> Int

The number of failing findings in a `Vector{StrictFinding}` (as returned by [`findings`](@ref),
[`audit`](@ref), or `StrictModeTest`'s `test_*` drivers).
"""
nfailures(fs::AbstractVector{StrictFinding}) = count(_failed, fs)

"""
    StrictMode.key(f::StrictFinding) -> Tuple{Symbol, String, String, Symbol}

The identity of a finding across runs: `(mod, func, signature, guarantee)`. It survives an edit to
the code the finding is about, which is what makes two runs comparable — `reason` and `line` do not,
and are the thing a comparison reports as changed.

`file`/`line` cannot serve: a `:typestable` finding carries no location at all, and a `:noalloc`
finding carries the allocation *site*, which moves when the body does.
"""
key(f::StrictFinding) = (f.mod, f.func, f.signature, f.guarantee)

"""
    StrictMode.findings_diff(old, new) -> (; fixed, introduced, changed, unchanged)

Compare two runs by [`key`](@ref). `fixed` are findings that failed in `old` and do not in `new`,
`introduced` the reverse, `changed` those failing in both with a different `reason`, and `unchanged`
the rest of the shared failures. Each field is a `Vector{StrictFinding}` taken from `new`, except
`fixed`, which can only come from `old`.

Two sessions can share a baseline this way: write one run with
`format_findings(fs; format = :jsonlines)` and compare the next against it.
"""
function findings_diff(old::AbstractVector{StrictFinding}, new::AbstractVector{StrictFinding})
    oldfail = Dict(key(f) => f for f in old if _failed(f))
    newfail = Dict(key(f) => f for f in new if _failed(f))
    fixed = [f for (k, f) in oldfail if !haskey(newfail, k)]
    introduced = [f for (k, f) in newfail if !haskey(oldfail, k)]
    changed = StrictFinding[]
    unchanged = StrictFinding[]
    for (k, f) in newfail
        haskey(oldfail, k) || continue
        push!(oldfail[k].reason == f.reason ? unchanged : changed, f)
    end
    return (; fixed, introduced, changed, unchanged)
end

# Single-line REPL display.
function Base.show(io::IO, f::StrictFinding)
    mark = f.status === :fail ? "✗" : f.status === :pass ? "✓" : "•"
    print(io, "[", mark, " ", f.guarantee)
    # The code only earns its space where there is something to look up.
    f.status === :pass || print(io, " ", f.code)
    print(io, "] ", f.func, f.signature)
    f.status !== :pass && f.reason != "" && print(io, " — ", f.reason)
    return nothing
end

# Multi-line display for a list of findings. This is the whole rendering a caller sees when a
# driver's return value is displayed — a REPL, a log, or an agent reading a tool result — so it
# leads with the counts and the failures, and collapses the passes to a tally. A 400-finding sweep
# printed in full buries the handful of lines that matter.
function Base.show(io::IO, ::MIME"text/plain", fs::AbstractVector{StrictFinding})
    if isempty(fs)
        print(io, "0 StrictMode findings")
        return nothing
    end
    failed = filter(_failed, fs)
    info = filter(f -> f.status === :info, fs)
    npass = length(fs) - length(failed) - length(info)
    print(io, length(fs), "-element Vector{StrictFinding}: ", length(failed), " failing")
    isempty(info) || print(io, ", ", length(info), " informational")
    iszero(npass) || print(io, ", ", npass, " passing")
    for f in Iterators.take(failed, 20)
        print(io, "\n ", f)
        f.file == "" || print(io, "\n     at ", f.file, ":", f.line)
        f.suggestion == "" || print(io, "\n     → ", f.suggestion)
    end
    length(failed) > 20 && print(io, "\n … and ", length(failed) - 20, " more failing")
    isempty(failed) || print(io, "\n(format_findings(fs; format = :json) for the whole list)")
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
    println(io, "StrictMode: ", length(fs), " finding(s), ", nfailures(fs), " failing.")
    for f in fs
        println(io, "  ", f)
        if _failed(f) || f.status === :info
            f.file != "" && println(io, "      at ", f.file, ":", f.line)
            f.suggestion != "" && println(io, "      → ", f.suggestion)
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
        ("tier", string(f.tier)), ("code", string(f.code)),
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
        loc = f.file != "" ? "file=$(f.file),line=$(f.line)" : ""
        if _failed(f)
            println(io, "::error ", loc, "::StrictMode @", f.guarantee, " ", f.func, f.signature, " — ", f.reason)
        elseif f.status === :info
            # Informational (e.g. inline suggestions): a GitHub `::notice`, never a CI-failing `::error`.
            println(io, "::notice ", loc, "::StrictMode @", f.guarantee, " ", f.func, f.signature, " — ", f.reason)
        end
    end
    return nothing
end
