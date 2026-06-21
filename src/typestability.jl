# `@assert_typestable` — fail on type instability. Two analysis modes (see `analysis_mode`):
#   :full — `Test.@inferred` (return type concrete) + `JET.@report_opt` (no *internal* dispatch /
#           boxing / instability — catches the runtime-tuple-indexing trap even when the return
#           type is fine). Rigorous; for CI.
#   :fast — `Base.return_types` concreteness only (inference, sub-ms once warm). For a tight
#           interactive loop; can miss internal-dispatch-with-concrete-return.

_inferred_details(err) = "return type is not concretely inferrable:\n" * sprint(showerror, err)

# Cheap (:fast) type-stability check: the inferred return type must be a single concrete type.
function _typestable_fast(target, @nospecialize(f), @nospecialize(types::Tuple))
    rts = Base.return_types(f, Tuple{types...})
    if length(rts) != 1 || !isconcretetype(only(rts))
        rt = isempty(rts) ? "none" : (length(rts) == 1 ? string(only(rts)) : string(rts))
        _fail(:typestable, target, "return type is not concrete (inference): $rt")
    end
    return nothing
end

# The type-stability *check* expression (no value), branched on the active analysis mode. Shared
# by `@assert_typestable` and `@strict`.
function _typestable_check_expr(target, fe, litcall, types)
    if ANALYSIS_MODE === :full
        return quote
            try
                Test.@inferred $litcall
            catch err
                err isa StrictViolation && rethrow()
                $(_fail)(:typestable, $target, $(_inferred_details)(err))
            end
            let _r = JET.@report_opt($litcall)
                isempty(JET.get_reports(_r)) || $(_fail)(:typestable, $target, sprint(show, _r))
            end
        end
    else
        return :($(_typestable_fast)($target, $fe, $types))
    end
end

"""
    @assert_typestable f(args...)

Fail unless `f(args...)` is type stable.

In the default `:full` [`analysis_mode`](@ref) this combines `Test.@inferred` (the return type
must be concrete) with `JET.@report_opt` (no internal instability or runtime dispatch), and
reports the offending variable / dispatch on failure. In `:fast` mode it does a cheap
inference-only return-type concreteness check. Each argument is evaluated once; the macro
evaluates to the call's value; disabled builds expand to the bare call.

```julia
@assert_typestable muladd(2.0, 3.0, 1.0)          # ok
@assert_typestable pick(heterogeneous_tuple, i)   # throws: Union from runtime tuple index
```
"""
macro assert_typestable(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)

    # Mode-specific value capture, so `:full` does not execute the call twice (`@inferred`
    # already runs it and yields the value).
    checked = if ANALYSIS_MODE === :full
        quote
            $(binds...)
            local _val = try
                Test.@inferred $litcall
            catch err
                err isa StrictViolation && rethrow()
                $(_fail)(:typestable, $target, $(_inferred_details)(err))
                $litcall   # warn-mode: still produce the value
            end
            let _r = JET.@report_opt($litcall)
                isempty(JET.get_reports(_r)) || $(_fail)(:typestable, $target, sprint(show, _r))
            end
            _val
        end
    else
        quote
            $(binds...)
            local _val = $litcall
            $(_typestable_fast)($target, $fe, $types)
            _val
        end
    end
    return _gate(checked, esc(call))
end
