# Idiom-encoding helpers: make the fast path the *easy* path so users never hand-write the
# avoid-boxing pattern. Unlike the assert macros these are not gated — you want the unrolling in
# production too — and they emit straight-line code with *literal* indices.

# Substitute a bare loop variable with a literal value throughout an expression (a fresh copy).
# This is what makes the unrolled indices literal — `t[i]` becomes `t[1]`, `t[2]`, … — so a
# heterogeneous tuple is indexed type-stably instead of boxing. Field names (`a.i`) and keyword
# names (`f(i = …)`) are left untouched.
function _subst(@nospecialize(x), var::Symbol, @nospecialize(val))
    x === var && return val
    if x isa Expr
        x.head === :. && return Expr(:., _subst(x.args[1], var, val), x.args[2])
        x.head === :kw && length(x.args) == 2 && return Expr(:kw, x.args[1], _subst(x.args[2], var, val))
        return Expr(x.head, Any[_subst(a, var, val) for a in x.args]...)
    end
    return x
end

# The literal values a `@unroll` iterates over, extracted at macro-expansion time.
function _unroll_values(iter)
    if Meta.isexpr(iter, :call, 3) && iter.args[1] === :(:) &&
            iter.args[2] isa Integer && iter.args[3] isa Integer
        return collect(iter.args[2]:iter.args[3])
    elseif Meta.isexpr(iter, :tuple)
        return iter.args
    end
    throw(
        ArgumentError(
            "@unroll needs a statically-known iteration: a literal integer range " *
                "`lo:hi` or a tuple literal `(a, b, …)`, got `$iter`. For a size known only from a " *
                "type, splice the count into `@unroll` from a @generated function (see the docs)."
        )
    )
end

"""
    @unroll for i in lo:hi
        body
    end
    @unroll for x in (a, b, c)
        body
    end

Fully unroll a loop whose trip count is known at macro-expansion time, emitting straight-line code
with the loop variable replaced by a literal on each pass. That removes the whole
runtime-tuple-indexing boxing problem: `s += t[i]` becomes `s += t[1]; s += t[2]; …`, so a
heterogeneous tuple is indexed type-stably instead of producing a `Union` and boxing. (This is the
trap that cost a measured 135× in the FFT work.)

Because the loop variable is substituted rather than captured in a closure, a mutated accumulator
stays an ordinary local, with no `Core.Box`. `@unroll` isn't gated by `checks_enabled`; the
unrolling always happens. Pair it with [`@assert_noalloc`](@ref) or [`@assert_typestable`](@ref) to
confirm the result really is on the fast path.

The iteration has to be statically known: a literal integer range or a tuple literal. For a size
that lives only in a type, write a `@generated` wrapper and splice the count in; see
[`staticval`](@ref) and the docs.

```julia
function tuple_sum(t)         # t::Tuple of mixed element types
    s = 0.0
    @unroll for i in 1:3
        s += t[i]             # → s += t[1]; s += t[2]; s += t[3]   (no boxing)
    end
    return s
end
```
"""
macro unroll(forexpr)
    Meta.isexpr(forexpr, :for) ||
        throw(ArgumentError("@unroll expects a `for` loop, got `$forexpr`"))
    spec, body = forexpr.args
    (Meta.isexpr(spec, :(=)) && spec.args[1] isa Symbol) ||
        throw(ArgumentError("@unroll supports a single `for i in <iterable>` variable"))
    var = spec.args[1]
    values = _unroll_values(spec.args[2])
    stmts = Any[_subst(body, var, v) for v in values]
    push!(stmts, :nothing)   # a `for` loop evaluates to nothing
    return esc(Expr(:block, stmts...))
end

"""
    staticval(n::Integer) -> Val{n}

Push a count/size into the type domain for full compile-time specialization. Dispatch a kernel
on `staticval(n)` so the size is a static parameter; a `@generated` method can then splice that
literal into an [`@unroll`](@ref) to unroll a type-driven trip count without boxing.

```julia
kernel(x, ::Val{N}) where {N} = ...        # N is a compile-time constant here
kernel(x, n::Integer) = kernel(x, staticval(n))
```
"""
staticval(n::Integer) = Val(n)
