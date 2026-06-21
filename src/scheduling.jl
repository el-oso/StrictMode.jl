# Surface & (partly) force the scheduling / vectorization layer — the residual gap vs Rust that
# lives *below* user code. StrictMode cannot match rustc's instruction scheduler (an explicit
# non-goal); what it can do is make that layer **visible** (`@assert_vectorized`, `@assert_effects`,
# `descend`) and **reachable** (the documented `@assume_effects` / `@simd ivdep` / `llvmcall`
# escape hatches). All of these use only Base + InteractiveUtils — no AllocCheck/JET backend.

# Best-effort: did the method's LLVM IR contain SIMD vector ops? (`<N x double>` & friends.)
function _vectorized(@nospecialize(f), @nospecialize(types::Tuple))
    io = IOBuffer()
    try
        InteractiveUtils.code_llvm(io, f, types; debuginfo = :none, optimize = true)
    catch
        return false
    end
    return occursin(r"<\d+ x (float|double|half|i\d+)>", String(take!(io)))
end

function _assert_vectorized(target, @nospecialize(f), @nospecialize(types::Tuple))
    _vectorized(f, types) || _fail(
        :vectorized, target,
        "loop did not SIMD-vectorize — no `<N x …>` vector ops in the LLVM IR (best-effort; try " *
            "`@inbounds @simd`, `@simd ivdep`, or `descend` to see why)."
    )
    return nothing
end

"""
    @assert_vectorized f(args...)

Fail unless `f(args...)` compiled to SIMD vector instructions (**best-effort**): StrictMode scans
the method's LLVM IR for vector types (`<N x …>`). A failure means the compiler did not vectorize
the loop under the current settings — informative, not a proof, so it is **not** part of
[`@strict`](@ref). Each argument is evaluated once; disabled builds expand to the bare call.

```julia
@inbounds @simd_dot(a, b)          # vectorizes → ok
@assert_vectorized branchy(a)      # throws: a data-dependent branch blocked vectorization
```
"""
macro assert_vectorized(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)
    checked = quote
        $(binds...)
        local _val = $litcall
        $(_assert_vectorized)($target, $fe, $types)
        _val
    end
    return _gate(checked, esc(call))
end

# --- @assert_effects (via Base.infer_effects) -------------------------------------------------

function _assert_effects(target, @nospecialize(f), @nospecialize(types::Tuple), required)
    eff = effects(f, types)
    missing_eff = Symbol[s for s in required if !effect_holds(eff, s)]
    isempty(missing_eff) || _fail(
        :effects, target,
        "inferred effects missing $(join(missing_eff, ", ")) for the requested guarantee (have: $eff)."
    )
    return nothing
end

"""
    @assert_effects f(args...) (:nothrow, :effect_free, ...)

Fail unless the compiler infers the requested [effects](https://docs.julialang.org/en/v1/base/base/#Base.@assume_effects)
for `f(args...)`, via `Base.infer_effects`. Effects are one or more of `:nothrow`, `:effect_free`,
`:terminates`, `:consistent`, `:nonoverlayed`. This is the *verify* side of effects; to *declare*
them (and influence codegen), use `Base.@assume_effects`. Each argument is evaluated once.

```julia
@assert_effects dot3(a, b) (:nothrow, :effect_free)   # ok if the compiler agrees
```
"""
macro assert_effects(call, required)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)
    checked = quote
        $(binds...)
        local _val = $litcall
        $(_assert_effects)($target, $fe, $types, $(esc(required)))
        _val
    end
    return _gate(checked, esc(call))
end

# --- descend escape hatch (Cthulhu weak-dep extension fills this in) ---------------------------

const _CTHULHU_DESCEND = Ref{Any}(nothing)

"""
    descend(f, types)

Drop into [Cthulhu](https://github.com/JuliaDebug/Cthulhu.jl)'s interactive descent on the method
`f(::types...)` to *see* the layer StrictMode can't control — inlining decisions, inferred
effects, type-stability, and the LLVM/native code. Requires Cthulhu (`using Cthulhu`); it is an
optional heavy weak dependency, loaded only when you want to look. This is the visibility escape
hatch for scheduling-bound kernels.
"""
function descend(@nospecialize(f), @nospecialize(types))
    _CTHULHU_DESCEND[] === nothing &&
        return @info "StrictMode.descend needs Cthulhu — run `using Cthulhu` first (it's an optional weak dependency)."
    return _CTHULHU_DESCEND[](f, types)
end
