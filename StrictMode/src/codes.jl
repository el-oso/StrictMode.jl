# A stable code per finding KIND, so a verdict can be looked up, linked, and matched across runs.
#
# The key is `(guarantee, cause)`, never the reason text: a reason is assembled at the call site and
# two reports of the same problem do not read alike, while the pair is fixed. `cause` is `nothing`
# for a guarantee that has only one way to fail.
#
# A published code is permanent. Renumbering would break every saved report and every link that
# refers to one, so a kind that goes away leaves a gap in the table rather than freeing its number.

# Ranges keep related kinds together: 1–99 guarantee verdicts, 100–199 the declarations that cause
# a type instability, 200–299 the gate's own findings, 300–399 advisories.
const _CODES = Dict{Tuple{Symbol, Union{Nothing, Symbol}}, Symbol}(
    (:typestable, nothing) => :SM0001,
    (:noalloc, nothing) => :SM0002,
    (:noboxing, nothing) => :SM0003,
    (:owned, nothing) => :SM0004,
    (:inlined, nothing) => :SM0005,
    (:vectorized, nothing) => :SM0006,
    (:no_scalar_loops, nothing) => :SM0007,
    (:no_spill, nothing) => :SM0008,
    (:trim_compatible, nothing) => :SM0009,
    (:trusted, nothing) => :SM0010,
    (:noescape, nothing) => :SM0011,
    (:noalias, nothing) => :SM0012,
    (:typestable, :captured_variable) => :SM0101,
    (:typestable, :nonconst_global) => :SM0102,
    (:typestable, :abstract_field) => :SM0103,
    (:typestable, :abstract_eltype) => :SM0104,
    (:typestable, :reflection) => :SM0105,
    (:typestable, :runtime_type_parameter) => :SM0106,
    (:typestable, :method_count) => :SM0107,
    (:coverage, nothing) => :SM0201,
    (:exemption, nothing) => :SM0202,
    (:unevaluated, nothing) => :SM0203,
    (:dispatch, nothing) => :SM0301,
    (:inline_suggestion, nothing) => :SM0302,
    (:static_ownership, nothing) => :SM0303,
    (:advisory, nothing) => :SM0304,
)

# One line saying what the code IS, for a reader who has only the code. The fix comes from
# `_suggestion`/`_cause_suggestion`, which the macros and the findings already use, so a code and a
# message can never disagree about the remedy.
const _CODE_MEANING = Dict{Symbol, String}(
    :SM0001 => "the inferred return type is not concrete, so every caller dispatches on it at run time",
    :SM0002 => "the method allocates on at least one path",
    :SM0003 => "a value is boxed, or a call dispatches at run time",
    :SM0004 => "owned scratch is reached through a runtime dictionary lookup instead of a fixed field",
    :SM0005 => "the callee was not inlined and survives as a call",
    :SM0006 => "the loop body contains no vector instructions",
    :SM0007 => "a numeric loop stayed scalar",
    :SM0008 => "a vector register was spilled to the stack and reloaded",
    :SM0009 => "a call cannot be resolved statically, so `juliac --trim` cannot keep it",
    :SM0010 => "the payload of an `Untrusted` value is read outside a registered boundary",
    :SM0011 => "a scoped value escapes the frame that obtained it — valid only inside that frame",
    :SM0012 => "an argument the call writes shares memory with one it reads, so the result depends on the order the elements are touched",
    :SM0101 => "a closure captured a local that is reassigned, so it is held in a `Core.Box`",
    :SM0102 => "a non-`const` global is read, and its type can change between reads",
    :SM0103 => "a struct field is declared with an abstract type",
    :SM0104 => "a container's element type is abstract, so indexing it dispatches",
    :SM0105 => "reflection is called, and its result is not known until run time",
    :SM0106 => "a type is built from a value known only at run time",
    :SM0107 => "the call matches more methods than `max_methods`, so inference gives up on it",
    :SM0201 => "a method or signature has no declared guarantee and no exemption",
    :SM0202 => "an exemption covers this, or the proofs say it is no longer needed",
    :SM0203 => "the analysis could not be evaluated, which counts as a failure rather than a pass",
    :SM0301 => "the call site dispatches at run time, or sits at exactly `max_methods`",
    :SM0302 => "the callee might be worth `@inline`",
    :SM0303 => "a type- or symbol-keyed registry lookup could be static ownership instead",
    :SM0304 => "an advisory pass could not be computed for this signature",
)

# The code for a verdict, or `nothing` when the kind is not in the table. A guarantee with a known
# cause gets the cause's code, which is the actionable one; otherwise the guarantee's own.
function _code(guarantee::Symbol, cause::Union{Nothing, Symbol} = nothing)
    if !isnothing(cause)
        c = get(_CODES, (guarantee, cause), nothing)
        isnothing(c) || return c
    end
    return get(_CODES, (guarantee, nothing), :SM0000)
end

"""
    StrictMode.explain(code) -> String

What a diagnostic code means, and what to do about it. `code` is a `Symbol` or a string, as printed
in a finding: `explain(:SM0104)`, `explain("SM0104")`.

```julia
julia> print(StrictMode.explain("SM0104"))
SM0104 — typestable (cause: abstract_eltype)
…
```

A code names a KIND of finding, so it is the same across runs and across machines, which a reason
sentence is not: a reason is assembled per call site. [`StrictMode.codes`](@ref) lists every code.
"""
function explain(code::Symbol)
    meaning = get(_CODE_MEANING, code, nothing)
    isnothing(meaning) && throw(
        ArgumentError(
            "unknown diagnostic code :$code. `StrictMode.codes()` lists every code; a code is " *
                "never reused, so one missing here was never published."
        )
    )
    guarantee, cause = _code_kind(code)
    io = IOBuffer()
    print(io, code, " — ", guarantee)
    isnothing(cause) || print(io, " (cause: ", cause, ")")
    println(io)
    println(io)
    println(io, "  ", meaning, ".")
    fix = isnothing(cause) ? _suggestion(guarantee) : _cause_suggestion(cause)
    if fix != ""
        println(io)
        println(io, "  Fix: ", fix)
    end
    println(io)
    print(
        io, "  Tier: a finding's `tier` says what it is worth — `:report` is StrictMode's ",
        "value-free\n  scan, whose allocation verdicts are structural guesses, and `:proof` is ",
        "StrictModeTest's\n  AllocCheck/JET/TrimCheck, which its drivers gate on."
    )
    return String(take!(io))
end

explain(code::AbstractString) = explain(Symbol(code))

# The `(guarantee, cause)` a code was issued for.
function _code_kind(code::Symbol)
    for (k, v) in _CODES
        v === code && return k
    end
    return (:unknown, nothing)
end

"""
    StrictMode.codes() -> Vector{Tuple{Symbol, Symbol, Union{Nothing, Symbol}}}

Every diagnostic code, as `(code, guarantee, cause)`, sorted by code.
[`StrictMode.explain`](@ref) describes one.
"""
codes() = sort!(
    [(v, k[1], k[2]) for (k, v) in _CODES], by = first
)
