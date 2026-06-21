# `@assert_typestable` — fail on type instability. Two complementary checks:
#   1. `Test.@inferred` guarantees the *return* type is concrete (catches the classic
#      `Union{...}`/`Any` return).
#   2. `JET.@report_opt` catches *internal* optimization failures — runtime dispatch, boxing
#      of captured variables, the runtime-tuple-indexing trap — even when the return type is fine.

_inferred_details(err) = "return type is not concretely inferrable:\n" * sprint(showerror, err)

"""
    @assert_typestable f(args...)

Fail unless `f(args...)` is fully type stable.

Combines `Test.@inferred` (the return type must be concrete) with `JET.@report_opt` (no
internal type instability or runtime dispatch). On failure it reports the offending variable /
dispatch from JET's analysis. Each argument is evaluated once; disabled builds expand to the
bare call.

```julia
@assert_typestable muladd(2.0, 3.0, 1.0)   # ok
@assert_typestable pick(heterogeneous_tuple, i)   # throws: Union from runtime tuple index
```
"""
macro assert_typestable(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)

    checked = quote
        $(binds...)
        # (1) return-type stability (@inferred returns the value or throws)
        local _val = try
            Test.@inferred $litcall
        catch err
            err isa StrictViolation && rethrow()
            $(_fail)(:typestable, $target, $(_inferred_details)(err))
            $litcall   # warn-mode: still produce the value
        end
        # (2) internal optimization failures (dispatch / boxing / instability)
        let _r = JET.@report_opt($litcall)
            if !isempty(JET.get_reports(_r))
                $(_fail)(:typestable, $target, sprint(show, _r))
            end
        end
        _val
    end
    return _gate(checked, esc(call))
end
