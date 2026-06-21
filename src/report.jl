"""
    StrictViolation(kind, target, details) <: Exception

Thrown (in `:error` [`fail_mode`](@ref)) when a StrictMode guarantee fails.

- `kind::Symbol` — which guarantee (`:noalloc`, `:typestable`, `:strict_function`, ...).
- `target` — the call/definition the guarantee was attached to (an `Expr` or string).
- `details::String` — human-readable explanation (allocation sites, instability report, ...).
"""
struct StrictViolation <: Exception
    kind::Symbol
    target::Any
    details::String
end

function Base.showerror(io::IO, e::StrictViolation)
    print(io, "StrictViolation (@", e.kind, "): guarantee not satisfied")
    println(io)
    println(io, "  target:  ", e.target)
    details = isempty(e.details) ? "(no further detail)" : e.details
    print(io, "  reason:  ")
    # Indent multi-line detail blocks so they read as one section.
    print(io, replace(details, '\n' => "\n           "))
    return nothing
end

# Single choke point for every guarantee. Honors the compile-time `fail_mode`.
function _fail(kind::Symbol, target, details::AbstractString)
    v = StrictViolation(kind, target, String(details))
    if FAIL_MODE === :warn
        @warn sprint(showerror, v)
        return nothing
    else
        throw(v)
    end
end
