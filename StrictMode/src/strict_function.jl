# `@strict_function` — annotate a definition so its guarantees are verified at *precompile*
# time. When a concrete signature violates the contract the module fails to load — the
# "Rust compiler error" experience. The check runs against the declared argument types, so no
# call-site values are needed.

# Pull the `:call` signature out of a function definition, peeling `where` and return-type
# annotations. Errors loudly on anything that is not a function definition.
function _strictdef_sig(def)
    Meta.isexpr(def, (:function, :(=))) || throw(
        ArgumentError(
            "@strict_function expects a function definition, got: $def"
        )
    )
    sig = def.args[1]
    while Meta.isexpr(sig, :where)
        sig = sig.args[1]
    end
    Meta.isexpr(sig, :(::)) && (sig = sig.args[1])   # `f(...)::RetType`
    Meta.isexpr(sig, :call) || throw(
        ArgumentError(
            "@strict_function: unsupported signature $sig"
        )
    )
    return sig
end

# Type expression for one argument; bare names and varargs degrade to `Any` (which makes the
# signature non-concrete, so the precompile check is skipped rather than wrong).
function _argtype(a)
    Meta.isexpr(a, :(::)) && return length(a.args) == 1 ? a.args[1] : a.args[2]
    Meta.isexpr(a, :kw) && return _argtype(a.args[1])
    return :Any
end

# Runs at precompile/module-load. Only verifies *concrete* signatures; abstract ones warn once.
function _verify_strict_def(@nospecialize(f), @nospecialize(types::Tuple), target; warn_abstract::Bool = true)
    Base.isdispatchtuple(Tuple{types...}) || return begin
        # Silent when the caller supplied `signatures =`: they have already answered which concrete
        # instantiations this declaration stands for, so the declaration being abstract is expected.
        warn_abstract && @warn "@strict_function $target: signature has non-concrete argument types " *
            "$(types); precompile guarantees skipped (list them with `signatures = [...]`, or use " *
            "`@strict_stable` to check every specialization instead)."
        nothing
    end
    # Record it so the automatic drivers (audit, @strict module, the Revise loop, and
    # StrictModeTest.test_registered) re-check it.
    register_strict!(f, types)
    # Type stability: the return type for this signature must be concrete.
    rts = Base.return_types(f, Tuple{types...})
    if length(rts) != 1 || !_is_typestable_return(only(rts))
        _fail(
            :strict_function, target,
            "return type is not concrete for ($(join(types, ", "))): inferred $(rts)"
        )
    end
    # Allocation-freedom (subsumes runtime dispatch / boxing, which show as allocations). This runs
    # at the enclosing module's PRECOMPILE, so it cannot use an analysis backend: a package
    # annotating its own `src/` depends on `StrictMode` alone, and AllocCheck/JET live in
    # `StrictModeTest`, a test-environment dependency that is not loadable here.
    #
    # So this WARNS, never throws — a heuristic false positive must not abort the consumer's module
    # load for code that may be provably clean. That is exactly what made checks-on unusable in
    # PureBLAS (issue #18 part 2, a `trmv!` false positive), and the scan's measured false-positive
    # rate on a real consumer is ~28% (issue #17: 19 of 68, every one measuring 0 bytes). The
    # declaration is registered either way, so `StrictModeTest.test_registered()` re-checks this
    # same signature against AllocCheck from the test environment and DOES fail.
    sig = _alloc_signals(f, types)
    if sig.alloc || sig.boxing || !isnothing(sig.abscontainer)
        @warn "@strict_function $target: " *
            _box_msg(
            "allocates / boxes (value-free IR scan — a structural guess, not a proof; " *
                "add StrictModeTest to your test environment and call test_registered() to " *
                "resolve it)", sig
        )
    end
    return nothing
end

# `signatures = [...]` — check the SAME contract against concrete instantiations the declaration
# cannot name. A generic declaration infers to `Any` (`return_types(pick, Tuple{Tuple,Int})` is
# `Any[Any]`), so checking it directly would fail every generic function; listing the
# instantiations that matter keeps the verdict at module load, where it belongs, without that.
function _verify_strict_signatures(@nospecialize(f), sigs, fname::AbstractString)
    for s in sigs
        types = s isa Tuple ? s : Tuple(s)
        _verify_strict_def(f, types, fname * "(" * join(types, ", ") * ")")
    end
    return nothing
end

"""
    @strict_function function f(x::T, ...) ... end
    @strict_function f(x::T, ...) = ...

Define `f` and, when checks are enabled, verify its contract at precompile time against the
declared argument types. A non-concrete return type stops the enclosing module loading. An
allocation only WARNS here: this runs at the annotated package's own precompile, where the proof
is not loadable, so a structural guess must not stop a consumer installing — `test_registered()`
re-proves the same signature from `test/` and does fail.

Only concrete signatures are verified this way. A declaration whose argument types are abstract
infers to `Any` and so cannot be checked directly — list the instantiations that matter with
`signatures = [...]`, each a tuple of concrete types, and each is verified at load exactly as a
concrete declaration would be:

```julia
sigs = [(NTuple{3,Float64}, Int), (Tuple{Float64,String}, Int)]
@strict_function signatures = sigs pick(t::Tuple, i::Int) = t[i]
# the second entry infers Union{Float64,String}, so the module fails to load
```

That keeps every verdict at module load. To check instead whatever specializations callers
actually create — including ones you could not have listed — see [`@strict_stable`](@ref), which
trades load-time failure for open coverage. With checks disabled this is just the plain definition.

```julia
@strict_function dot3(a::NTuple{3,Float64}, b::NTuple{3,Float64}) =
    a[1]*b[1] + a[2]*b[2] + a[3]*b[3]    # loads fine: stable + non-allocating
```
"""
macro strict_function(args...)
    pos, opts = _macro_call(args, (:signatures,))
    length(pos) == 1 || throw(
        ArgumentError("@strict_function expects one function definition, got $(length(pos))")
    )
    def = pos[1]
    sig = _strictdef_sig(def)
    fname = sig.args[1]
    argexprs = filter(a -> !Meta.isexpr(a, :parameters), sig.args[2:end])
    argtypes = Expr(:tuple, (esc(_argtype(a)) for a in argexprs)...)
    target = string(fname) * "(" * join((string(_argtype(a)) for a in argexprs), ", ") * ")"
    sigs = get(opts, :signatures, nothing)

    checked = if sigs === nothing
        quote
            $(esc(def))
            $(_verify_strict_def)($(esc(fname)), $argtypes, $target)
        end
    else
        quote
            $(esc(def))
            $(_verify_strict_def)($(esc(fname)), $argtypes, $target; warn_abstract = false)
            $(_verify_strict_signatures)($(esc(fname)), $(esc(sigs)), $(string(fname)))
        end
    end
    return _gate(checked, esc(def))
end

"""
    @strict_exempt f(x::T, ...) = ...
    @strict_exempt name

Mark a function as cold: setup or plan-time code that's meant to allocate or stay type-flexible,
and should be exempt from StrictMode's checks. Inside a
`@strict module` every function is checked by default, and you wrap only the occasional cold helper
in `@strict_exempt`, rather than annotating all the hot code.

The definition form defines the function and records its name as exempt; the name form
(`@strict_exempt foo` or `@strict_exempt :foo`) just records the name. Exempt functions are skipped
by `audit`, the whole-module load check, and `StrictModeTest`'s `test_registered`/`test_compiled`
gates. It's never gated itself; the exemption always applies.
"""
macro strict_exempt(arg)
    if Meta.isexpr(arg, (:function, :(=)))
        sig = _strictdef_sig(arg)
        fname = sig.args[1]
        fname isa Symbol || throw(ArgumentError("@strict_exempt: unsupported definition $arg"))
        return quote
            $(esc(arg))
            $(_exempt!)($(QuoteNode(fname)))
            $(esc(fname))
        end
    end
    name = arg isa QuoteNode ? arg.value : arg
    name isa Symbol || throw(ArgumentError("@strict_exempt expects a definition or a function name, got $arg"))
    return :($(_exempt!)($(QuoteNode(name))))
end

# --- `@strict_stable` -----------------------------------------------------------------------------
# `@strict_function` checks the DECLARED signature once, at the enclosing module's load. That leaves
# two gaps: a declaration whose argument types are abstract is skipped entirely (`isdispatchtuple`
# is false, and it warns), and a concrete declaration says nothing about the other specializations
# callers actually create.
#
# This closes both by moving the body into a hidden inner function and giving the public one a
# wrapper that infers the inner's return type. `Base.promote_op` is inference, so `T` is a
# compile-time constant and `_is_typestable_return(T)` folds with it: a stable specialization keeps
# no branch at all — measured, the wrapper compiles to the same LLVM as the unannotated function and
# still inlines into its caller — while an unstable one throws as that specialization is compiled.
#
# The trade is that the verdict is re-derived per specialization instead of being fixed at load, so
# a definition that loaded clean can still throw later when inference changes under it. That is the
# whole point of the macro, and it is why it does not share a name with `@strict_function`.

# Name for one argument, so the wrapper can forward it. `::T` with no name gets one.
function _stable_argname(a)
    Meta.isexpr(a, :(::)) && return length(a.args) == 1 ? gensym(:arg) : a.args[1]
    Meta.isexpr(a, :kw) && return _stable_argname(a.args[1])
    return a
end

# Cold path only: reached when inference already proved the return type non-concrete, so nothing
# here has to be cheap.
@noinline function _stable_violation(target, @nospecialize(T))
    # A call made while some module is precompiling is compiling a program this verdict does not
    # own; failing there aborts a build over code the caller may never run.
    iszero(ccall(:jl_generating_output, Cint, ())) || return nothing
    _fail(
        :typestable, target,
        "return type is not concrete for this specialization: inferred $T"
    )
    return nothing
end

"""
    @strict_stable f(x::T, ...) = ...

Define `f` so that **every concrete specialization** carries its own type-stability check, and pay
nothing for the ones that hold.

The body moves into a hidden inner function; `f` becomes a wrapper that infers the inner's return
type. That inference is a compile-time constant, so a stable specialization compiles to exactly the
code the unannotated definition would — the branch is gone, and the wrapper still inlines into its
caller. An unstable specialization throws [`StrictViolation`](@ref) when it is compiled.

Use this where [`@strict_function`](@ref) cannot reach:

```julia
@strict_function pick(t::Tuple, i::Int) = t[i]   # skipped: `Tuple` is abstract, so it only warns
@strict_stable   pick(t::Tuple, i::Int) = t[i]   # throws on the call whose tuple is heterogeneous
```

The difference from `@strict_function` is not just coverage but *when* the verdict is formed.
`@strict_function` decides once, at the enclosing module's load, against the declared argument
types. This decides per specialization, at that specialization's compile time — which means a
definition that loaded clean can begin throwing after unrelated code changes what inference can
prove. Reach for `@strict_function` when the contract is a fixed concrete signature; reach for this
when the guarantee should follow the function wherever callers take it.

Positional arguments only. Keyword and varargs definitions are rejected rather than silently left
unchecked. Only type stability is enforced: allocation and vectorization are read from compiled
output and cannot be delivered this way. With checks disabled this is the plain definition.
"""
macro strict_stable(def)
    sig = _strictdef_sig(def)
    fname = sig.args[1]
    fname isa Symbol || throw(ArgumentError("@strict_stable: unsupported function name $fname"))
    args = sig.args[2:end]
    any(a -> Meta.isexpr(a, :parameters), args) && throw(
        ArgumentError("@strict_stable does not support keyword arguments; use @strict_function")
    )
    any(a -> Meta.isexpr(a, :(...)), args) && throw(
        ArgumentError("@strict_stable does not support varargs; use @strict_function")
    )
    argnames = map(_stable_argname, args)
    inner = Symbol("#", fname, "#inner")
    target = string(fname)

    innerdef = deepcopy(def)
    isig = innerdef.args[1]
    while Meta.isexpr(isig, :where)
        isig = isig.args[1]
    end
    Meta.isexpr(isig, :(::)) && (isig = isig.args[1])
    isig.args[1] = inner

    wrapper = deepcopy(def)
    wrapper.args[2] = Expr(
        :block,
        :(local var"#T" = $(Base.promote_op)($inner, $((:(typeof($a)) for a in argnames)...))),
        # The compile-time-constant test comes FIRST so a stable specialization folds the whole
        # branch away; anything runtime-valued here would keep it alive.
        :(
            if !$(_is_typestable_return)(var"#T")
                $(_stable_violation)($target, var"#T")
            end
        ),
        Expr(:call, inner, argnames...),
    )

    return _gate(esc(Expr(:block, innerdef, wrapper, fname)), esc(def))
end
