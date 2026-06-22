# `@assert_typestable` — fail on type instability. Two layers:
#   - return-type concreteness via `Base.return_types` (no heavy deps) — both modes.
#   - internal optimization failures via JET (`:full` mode only), through the backend seam.
# (Routing JET through the backend keeps it a weak dependency; `:fast` mode needs no backend.)

# Cheap return-type check: the inferred return type must be a single concrete type.
function _typestable_fast(target, @nospecialize(f), @nospecialize(types::Tuple))
    rts = Base.return_types(f, Tuple{types...})
    if length(rts) != 1 || !isconcretetype(only(rts))
        rt = isempty(rts) ? "none" : (length(rts) == 1 ? string(only(rts)) : string(rts))
        _fail(:typestable, target, "return type is not concrete (inference): $rt")
    end
    return nothing
end

# Internal-instability check via JET (`:full`). Requires the analysis backend.
function _assert_opt(target, @nospecialize(f), @nospecialize(types::Tuple))
    _require_backend()
    r = _be_opt_result(f, types)
    isempty(_be_opt_reports(r)) || _fail(:typestable, target, sprint(show, r))
    return nothing
end

# The type-stability *check* expression (no value), branched on the active analysis mode. Shared
# by `@assert_typestable` and `@strict`.
function _typestable_check_expr(target, fe, litcall, types)
    base = :($(_typestable_fast)($target, $fe, $types))
    ANALYSIS_MODE === :full || return base
    return quote
        $base
        $(_assert_opt)($target, $fe, $types)
    end
end

"""
    @assert_typestable f(args...)

Fail unless `f(args...)` is type stable.

Both [`analysis_mode`](@ref)s check that the inferred return type is a single concrete type, using
`Base.return_types`. On top of that, `:full` runs JET's optimization analysis to catch instability
or runtime dispatch hiding inside the call, which is the part that needs the AllocCheck+JET backend.
Each argument is evaluated once, the macro returns the call's value, and disabled builds expand to
the bare call.

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

    checked = quote
        $(binds...)
        local _val = $litcall
        $(_typestable_check_expr(target, fe, litcall, types))
        _val
    end
    return _gate(checked, esc(call))
end
