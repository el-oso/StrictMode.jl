# --- shared macro plumbing (runs at user macro-expansion time, never at module load) ---
# Used by every guarantee macro across the package (static_checks.jl, typestability.jl,
# scheduling.jl, inlining.jl, trimsafe.jl, concurrency.jl, explain.jl, and this file).

# Split a call expression into `(function-expr, [positional-arg-exprs], [(kwname, valexpr)...])`.
# Handles plain calls `f(a, b)`, keyword calls `f(a; k=v)` / `f(a, k=v)`, and broadcasts
# `f.(a, b)` (rewritten to `broadcast(f, a, b)`). Genuinely unsupported forms (bare macrocalls,
# blocks, non-calls) get a clear error pointing at the interference-proof `StrictMode.findings`.
function _callinfo(call)
    # Broadcasting: `f.(xs...)` parses as `Expr(:., f, Expr(:tuple, xs...))`.
    if Meta.isexpr(call, :., 2) && Meta.isexpr(call.args[2], :tuple)
        return :broadcast, Any[call.args[1], call.args[2].args...], Any[]
    end
    Meta.isexpr(call, :call) || throw(
        ArgumentError(
            "StrictMode guarantee macros expect a call `f(args...)` or broadcast `f.(args...)`, " *
                "got: $call. For blocks or other forms, use the function API: " *
                "`StrictMode.findings(f, (T1, T2, …))`."
        )
    )
    fexpr = call.args[1]
    argexprs = Any[]
    kwexprs = Any[]   # normalized (name::Symbol, valexpr) pairs
    for a in call.args[2:end]
        if Meta.isexpr(a, :parameters)      # trailing `; k=v`
            for p in a.args
                _collect_kw!(kwexprs, p)
            end
        elseif Meta.isexpr(a, :kw)          # inline `k=v`
            _collect_kw!(kwexprs, a)
        else
            push!(argexprs, a)
        end
    end
    return fexpr, argexprs, kwexprs
end

function _collect_kw!(kwexprs, p)
    if Meta.isexpr(p, :kw)
        push!(kwexprs, (p.args[1]::Symbol, p.args[2]))
    elseif p isa Symbol                     # `; k` shorthand for `k = k`
        push!(kwexprs, (p, p))
    else
        throw(
            ArgumentError(
                "StrictMode guarantee macros can't handle the keyword form `$p` (e.g. `; kw...` " *
                    "splats). Use the function API instead: `StrictMode.findings(f, (T1, T2, …))`."
            )
        )
    end
    return kwexprs
end

# The single choke point behind every guarantee macro. Returns a NamedTuple:
#   binds   — bind each positional arg AND each kw *value* to a fresh gensym (evaluate-once; the
#             alloc thunk runs twice, so kw values must be hoisted, not re-evaluated inside it).
#   litcall — the reconstructed `f(argsyms...; k=kwsym...)` used for the value.
#   thunk   — `() -> litcall`, for the alloc path.
#   checkfn — the function whose signature the backends inspect: `f`, or `Core.kwcall` when there
#             are keyword args (so `check_allocs`/`return_types` see the real kwarg sites unchanged).
#   types   — the inference-signature tuple expr matching `checkfn`.
# `types = (...)` override pins the signature verbatim (fixes DataType-widening false positives).
function _call_parts(call; types = nothing)
    fexpr, argexprs, kwexprs = _callinfo(call)

    # The FUNCTION POSITION is bound like any argument, and bound FIRST (Julia evaluates the callee
    # before the arguments). Splicing `esc(fexpr)` into both the executed call and the analyzed
    # `checkfn` would evaluate it twice — so `@assert_noalloc ws.kernel(x)` runs the getfield twice,
    # and `@test_noalloc make_f()(x)` analyzes a DIFFERENT closure than it ran, which is a proof
    # about code the user never executed. The alloc thunk runs the call a second time, compounding it.
    fnsym = gensym(:f)
    binds = Any[:($fnsym = $(esc(fexpr)))]

    argsyms = [gensym(:arg) for _ in eachindex(argexprs)]
    append!(binds, Any[:($s = $(esc(e))) for (s, e) in zip(argsyms, argexprs)])

    kwnames = Symbol[name for (name, _) in kwexprs]
    kwsyms = [gensym(:kw) for _ in eachindex(kwexprs)]
    for (s, (_, v)) in zip(kwsyms, kwexprs)
        push!(binds, :($s = $(esc(v))))
    end
    haskw = !isempty(kwexprs)

    if haskw
        params = Expr(:parameters, (Expr(:kw, n, s) for (n, s) in zip(kwnames, kwsyms))...)
        litcall = Expr(:call, fnsym, params, argsyms...)
    else
        litcall = Expr(:call, fnsym, argsyms...)
    end
    thunk = Expr(:->, Expr(:tuple), Expr(:block, litcall))

    # A keyword call really dispatches through `Core.kwcall`, so that is the signature the engines
    # must be handed — INCLUDING under a `types = (…)` override. Taking the plain `(fnsym, types)`
    # branch there would analyze `f(types...)`, a method the executed call never reaches. The
    # override keeps meaning "these are the POSITIONAL argument types"; the kwcall wrapper is added
    # here so the analyzed signature and the executed one stay the same signature.
    nt = Expr(:tuple, (Expr(:(=), n, s) for (n, s) in zip(kwnames, kwsyms))...)
    if !isnothing(types) && haskw
        checkfn = Core.kwcall
        typesexpr = :((typeof($nt), typeof($fnsym), $(esc(types))...))
    elseif !isnothing(types)
        checkfn = fnsym
        typesexpr = esc(types)
    elseif haskw
        checkfn = Core.kwcall
        typesexpr = Expr(:tuple, :(typeof($nt)), :(typeof($fnsym)), (:(typeof($s)) for s in argsyms)...)
    else
        checkfn = fnsym
        typesexpr = Expr(:tuple, (:(typeof($s)) for s in argsyms)...)
    end
    return (; binds, litcall, thunk, checkfn, types = typesexpr)
end

# Varargs scan generalizing the `static=`/`self=` option loops: pulls any `Expr(:(=), key, val)`
# whose `key ∈ allowed` into `opts` (raw RHS expr), everything else into `positionals` in order.
function _macro_call(args, allowed::Tuple)
    positionals = Any[]
    opts = Dict{Symbol, Any}()
    for a in args
        if Meta.isexpr(a, :(=)) && a.args[1] isa Symbol && a.args[1] in allowed
            opts[a.args[1]] = a.args[2]
        else
            push!(positionals, a)
        end
    end
    return positionals, opts
end

# Shared shape for a per-call guarantee macro that runs one check function against
# `(target, checkfn, types, extra_args...)` and returns the call's own value unchanged — the
# common pattern behind most `@assert_*` macros (`@assert_inlined`, `@assert_noboxing`,
# `@assert_vectorized`, `@assert_no_scalar_loops`, `@assert_trim_safe`,
# `@assert_trim_compatible`, `@assert_no_threadid_state`, `@assert_effects`). `extra_args` are
# already-escaped expressions (e.g. an effects tuple) appended after `types`. Builds the
# checked-path expression only — callers still wrap the result with `_gate(expr, esc(call))`
# themselves, since the bare-call fallback is just `esc(call)`, already in scope at the call site.
function _guarantee_expr(call, runner, extra_args...; types = nothing)
    p = _call_parts(call; types)
    target = string(call)
    return quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(runner)($target, $(p.checkfn), $(p.types), $(extra_args...))
        _val
    end
end

# `@strict` — the guarantees every hot path wants, applied together. Binds the arguments a single
# time so the combined check never double-evaluates side effects.
#
# `:noboxing` is deliberately absent: its rule is a strict subset of `:noalloc`'s
# (`check.jl` fails `:noalloc` on `alloc || boxing || abscontainer` and `:noboxing` on
# `boxing || abscontainer`), so including both reports every boxing violation twice and detects
# nothing extra.

# Build the gated expression for a single `f(args...)` call, or the bare call when checks are
# disabled. Factored out so `@verify_strict` can reuse it without fragile nested-macro composition.
function _strict_expr(call; types = nothing)
    target = string(call)
    p = _call_parts(call; types)

    mode = _noalloc_mode(nothing)
    checked = quote
        $(p.binds...)
        # (1) type stability (root cause of most surprise allocations, so checked first)
        $(_typestable_check_expr(target, p.checkfn, p.types))
        # (2) owned scratch. Reports here rather than throwing as `@assert_owned` does: the rule
        # flags ANY runtime `AbstractDict` accessor on the hot path, which is right for a check you
        # asked for by name and too broad for one applied to every `@strict` site — a value-keyed
        # cache is legitimate. Runs before the call so the static scan precedes execution.
        $(_assert_owned)($target, $(p.checkfn), $(p.types); gates = false)
        # (3) allocation-freedom (also returns the call's value)
        $(_assert_noalloc)($target, $(p.checkfn), $(p.types), $(p.thunk); mode = $(QuoteNode(mode)))
    end
    return _gate(checked, esc(call))
end

"""
    @strict f(args...)

Apply the guarantees a hot path wants to `f(args...)` at once:

1. type stability ([`@assert_typestable`](@ref)) — checked first, since instability is usually
   what's behind a surprise allocation;
2. owned scratch ([`@assert_owned`](@ref)) — a runtime `AbstractDict` lookup on the hot path is
   type-stable and non-allocating on the warm hit, so the other two pass it;
3. allocation-freedom ([`@assert_noalloc`](@ref)).

Only type stability **throws** here. The owned-scratch and allocation checks warn: the first flags
any runtime dictionary accessor, which is right when you name it yourself and too broad applied to
every call site, and the second is a heuristic scan. Use [`@assert_owned`](@ref) directly for a hard
gate on owned scratch, and `StrictModeTest`'s `@test_noalloc` for a proof of allocation-freedom.

`@assert_noboxing` is not included: its rule is a strict subset of `@assert_noalloc`'s, so it would
report the same violations a second time and catch nothing extra.

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

    mode = _noalloc_mode(nothing)
    checked = quote
        $(p.binds...)
        # (1) type stability
        $(_typestable_check_expr(target, p.checkfn, p.types))
        # (2) allocation-freedom (returns the call's value)
        local _kval = $(_assert_noalloc)($target, $(p.checkfn), $(p.types), $(p.thunk); mode = $(QuoteNode(mode)))
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
@kernel vscale!(dst, src)       # type-stable + vectorized (throw), allocation-free (warns)
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

See also [`@strict`](@ref), which swaps the vectorization check for the owned-scratch check.
"""
macro kernel(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@kernel needs a call expression"))
    return _kernel_expr(pos[1]; types = get(opts, :types, nothing))
end
