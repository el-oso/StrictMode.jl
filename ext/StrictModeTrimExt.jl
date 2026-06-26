# The authoritative trim backend. Loaded only when `TrimCheck` is present (an *independent* weak
# dependency, separate from the AllocCheck/JET analysis backend). This is the only place that touches
# TrimCheck — it fills `StrictMode._be_trim_validate` and flips `trimcheck_available()` on.
#
# TrimCheck's public API (`@validate` / `validate_function`) only accepts a call-expr or a single-method
# function evaled in `Main` — it can't check an arbitrary concrete `(f, types)`. So we drive its core
# directly: the same `hook_verify_typeinf_trim() do … Compiler.typeinf_ext_toplevel(…, TRIM_SAFE) end`
# that `validate_function` runs, but for our exact signature. Reference TrimCheck's own `Compiler`
# binding (as `validate_function` does) so we hit the same verifier.

module StrictModeTrimExt

using StrictMode
using TrimCheck
using TypeContracts   # core StrictMode dep — its TrimDiagnostics parses the verifier output

# (f, types) -> (passed::Bool, findings::Vector{String}). `types` may be a `Type{<:Tuple}`
# (e.g. `Tuple{Int,Float64}`, as the AllocCheck/JET backend receives) or a plain tuple of types.
function StrictMode._be_trim_validate(@nospecialize(f), @nospecialize(types))
    argtypes = (types isa Type && types <: Tuple) ? collect(types.parameters) : collect(types)
    rts = Base.return_types(f, Tuple{argtypes...})
    if length(rts) != 1
        return (false, ["could not infer a single concrete return type ($(length(rts)) results); " *
            "trim verification needs a fully-inferred signature"])
    end
    ret_type = rts[1]
    Comp = TrimCheck.Compiler
    try
        TrimCheck.hook_verify_typeinf_trim() do
            Comp.typeinf_ext_toplevel(
                Any[Core.svec(ret_type, Tuple{typeof(f), argtypes...})],
                [Base.get_world_counter()],
                Comp.TRIM_SAFE,
            )
        end
        return (true, String[])
    catch err
        if err isa TrimCheck.TrimVerificationErrors
            # Route the raw verifier output through TypeContracts' `TrimDiagnostics` — the same parser
            # `explain_trim` uses — for deduplicated, source-mapped sites (statement + user frame),
            # instead of hand-filtering the raw dump.
            raw = try
                sprint(show, err)
            catch
                ""
            end
            tf = TypeContracts.explain_trim_failure(raw)
            if !tf.recognized || isempty(tf.sites)
                return (false, ["juliac --trim=safe rejected this signature (verifier output not recognized)"])
            end
            findings = String[]
            for s in tf.sites
                # frames are innermost-first ⇒ the outermost frame is the user-relevant call site.
                loc = isempty(s.frames) ? "" :
                    "  [" * basename(last(s.frames).file) * ":" * string(last(s.frames).line) * "]"
                push!(findings, s.statement * loc)
            end
            if length(findings) > 8
                extra = length(findings) - 8
                findings = vcat(findings[1:8], ["… (+$extra more call site(s))"])
            end
            return (false, findings)
        end
        rethrow(err)
    end
end

function __init__()
    StrictMode._TRIMCHECK_AVAILABLE[] = true
    return nothing
end

end # module StrictModeTrimExt
