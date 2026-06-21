# `@assert_inlined` — fail unless a call is inlined into its caller. Inlining is a compiler
# *heuristic*, not a guarantee, so this is explicitly **best-effort**: it compiles a tiny wrapper
# that calls `f(args...)`, inspects the wrapper's optimized typed IR, and fails if the call to
# `f` survives as an `:invoke` (i.e. it was *not* absorbed). A "not inlined" result is not
# necessarily a bug — it reports the compiler's decision under the current settings.

# Best-effort inlining detection from `(f, types)` alone (no values, no execution): compile a
# wrapper that calls `f`, scan its optimized IR for a surviving `:invoke` to `f`'s method.
# Returns `true` if the call was *not* inlined, `false` if it was, `nothing` if undeterminable
# (e.g. a builtin/intrinsic with no resolvable method — effectively always inlined).
function _inlined_survives(@nospecialize(f), @nospecialize(types::Tuple))
    local m
    try
        m = which(f, types)
    catch
        return nothing
    end
    wrapper = (args...) -> f(args...)
    cts = Base.code_typed(wrapper, types; optimize = true)
    isempty(cts) && return nothing
    for stmt in first(cts).first.code
        if Meta.isexpr(stmt, :invoke)
            # On recent Julia the `:invoke` target is a `CodeInstance` (whose `.def` is the
            # `MethodInstance`); older Julia uses the `MethodInstance` directly.
            a1 = stmt.args[1]
            mi = a1 isa Core.CodeInstance ? a1.def : a1
            mi isa Core.MethodInstance && mi.def === m && return true
        end
    end
    return false
end

function _assert_inlined(target, @nospecialize(f), @nospecialize(types::Tuple))
    if _inlined_survives(f, types) === true
        _fail(
            :inlined, target,
            "call to `$(which(f, types).name)` was not inlined — it survives as an `:invoke` at " *
                "the call site (inlining is a heuristic; this may be expected)."
        )
    end
    return nothing
end

"""
    @assert_inlined f(args...)

Fail unless the call to `f(args...)` is inlined into its caller (**best-effort**).

StrictMode compiles a tiny wrapper that makes the call, inspects its optimized typed IR, and
fails if the call survives as an `:invoke` — i.e. the compiler chose *not* to inline it. Because
inlining is a heuristic rather than a guarantee, a failure is informational: it means the
compiler did not inline this call under the current settings, which may or may not be a problem.
For that reason `@assert_inlined` is **not** part of [`@strict`](@ref).

Each argument is evaluated once; the macro evaluates to the call's value; disabled builds expand
to the bare call.

```julia
@inline   hot(x) = x * x + 1
@assert_inlined hot(3.0)        # ok: small, inlined

@noinline cold(x) = x * x + 1
@assert_inlined cold(3.0)       # throws: survives as an :invoke
```
"""
macro assert_inlined(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)

    checked = quote
        $(binds...)
        local _val = $litcall
        $(_assert_inlined)($target, $fe, $types)
        _val
    end
    return _gate(checked, esc(call))
end
