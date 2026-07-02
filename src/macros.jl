# `@strict` — apply every per-call guarantee at once. Binds the arguments a single time so the
# combined check never double-evaluates side effects. (v0.2 will also fold in `@assert_noboxing`
# and `@assert_inlined`.)

# Build the gated expression for a single `f(args...)` call: type-stable + non-allocating, or
# the bare call when checks are disabled. Factored out so `@verify_strict` can reuse it without
# fragile nested-macro composition.
function _strict_expr(call; types = nothing)
    target = string(call)
    p = _call_parts(call; types)

    static = ANALYSIS_MODE === :full
    checked = quote
        $(p.binds...)
        # (1) type stability (root cause of most surprise allocations, so checked first)
        $(_typestable_check_expr(target, p.checkfn, p.types))
        # (2) allocation-freedom (also returns the call's value)
        $(_assert_noalloc)($target, $(p.checkfn), $(p.types), $(p.thunk); static = $static)
    end
    return _gate(checked, esc(call))
end

"""
    @strict f(args...)

Ask for all of StrictMode's per-call guarantees on `f(args...)` at once: type stability
([`@assert_typestable`](@ref)) and allocation-freedom ([`@assert_noalloc`](@ref)). Type stability
comes first, since instability is usually what's behind a surprise allocation.

Arguments are evaluated once, and the macro returns the call's value. Disabled builds expand to the
bare call. Keyword-argument calls and a `types = (…)` signature override are both supported, exactly
as for [`@assert_typestable`](@ref) / [`@assert_noalloc`](@ref).

```julia
@strict dot(u, v)              # ok: stable + non-allocating
@strict trsm!(B, A; side='L')  # ok: keyword call guaranteed as-is
x = @strict kernel(a, b)       # use the result while still guaranteeing the fast path
```
"""
macro strict(args...)
    # `@strict module M … end` marks the whole module (see registry.jl); otherwise it's the
    # per-call guarantee on `f(args...)`.
    length(args) == 1 && Meta.isexpr(args[1], :module) && return _strict_module(args[1])
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@strict needs a call expression"))
    return _strict_expr(pos[1]; types = get(opts, :types, nothing))
end

# Build the gated expression for `@kernel f(args...)`: type-stable + non-allocating + vectorized.
function _kernel_expr(call; types = nothing)
    target = string(call)
    p = _call_parts(call; types)

    static = ANALYSIS_MODE === :full
    checked = quote
        $(p.binds...)
        # (1) type stability
        $(_typestable_check_expr(target, p.checkfn, p.types))
        # (2) allocation-freedom (returns the call's value)
        local _kval = $(_assert_noalloc)($target, $(p.checkfn), $(p.types), $(p.thunk); static = $static)
        # (3) vectorization
        $(_assert_vectorized)($target, $(p.checkfn), $(p.types))
        _kval
    end
    return _gate(checked, esc(call))
end

"""
    @kernel f(args...)

Apply all three SIMD-kernel guarantees to `f(args...)` at once: type stability
([`@assert_typestable`](@ref)), allocation-freedom ([`@assert_noalloc`](@ref)), and
vectorization ([`@assert_vectorized`](@ref)).

Use this on every `@generated`/SIMD kernel during development — it catches the single most
common footgun early: a tuple-of-`Vec` accumulator reassigned in a loop boxes and runs ~100×
slower despite looking like clean SIMD (also a 135× FFT regression in the wild). `@assert_noalloc`
is the signal that exposes it; `@kernel` makes that check reflexive so it is not forgotten during
early exploration.

Arguments are evaluated once, and the macro returns the call's value. Disabled builds expand to the
bare call.

```julia
@kernel vscale!(dst, src)       # vectorized + allocation-free + type-stable, or it throws
x = @kernel dot_kernel(a, b)   # use the result while still guaranteeing the fast path
```

!!! note
    [`@assert_vectorized`](@ref) inspects the *leaf compiled body*. A thin dispatcher whose SIMD
    lives in non-inlined callees will fail it — point `@kernel` at the kernels where the vector
    ops are, not at an entry-point wrapper. A **keyword-argument** kernel routes through the
    (non-inlined) `Core.kwcall` sorter, so mark it `@inline` for the vectorization check to see
    through to the vector ops.

Keyword-argument calls and a `types = (…)` signature override are supported (see
[`@assert_typestable`](@ref)).

See also [`@strict`](@ref) for the subset without the vectorization check.
"""
macro kernel(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@kernel needs a call expression"))
    return _kernel_expr(pos[1]; types = get(opts, :types, nothing))
end
