# `@strict` — apply every per-call guarantee at once. Binds the arguments a single time so the
# combined check never double-evaluates side effects. (v0.2 will also fold in `@assert_noboxing`
# and `@assert_inlined`.)

# Build the gated expression for a single `f(args...)` call: type-stable + non-allocating, or
# the bare call when checks are disabled. Factored out so `@verify_strict` can reuse it without
# fragile nested-macro composition.
function _strict_expr(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)
    thunk = Expr(:->, Expr(:tuple), Expr(:block, litcall))

    static = ANALYSIS_MODE === :full
    checked = quote
        $(binds...)
        # (1) type stability (root cause of most surprise allocations, so checked first)
        $(_typestable_check_expr(target, fe, litcall, types))
        # (2) allocation-freedom (also returns the call's value)
        $(_assert_noalloc)($target, $fe, $types, $thunk; static = $static)
    end
    return _gate(checked, esc(call))
end

"""
    @strict f(args...)

Assert *all* StrictMode per-call guarantees for `f(args...)`: type stability
([`@assert_typestable`](@ref)) and allocation-freedom ([`@assert_noalloc`](@ref)). Type
stability is checked first, since instability is the usual root cause of surprise allocations.

Arguments are evaluated once; the macro evaluates to the call's value. Disabled builds expand
to the bare call.

```julia
@strict dot(u, v)        # ok: stable + non-allocating
x = @strict kernel(a, b) # use the result while still guaranteeing the fast path
```
"""
macro strict(ex)
    # `@strict module M … end` marks the whole module (see registry.jl); otherwise it's the
    # per-call guarantee on `f(args...)`.
    Meta.isexpr(ex, :module) && return _strict_module(ex)
    return _strict_expr(ex)
end
