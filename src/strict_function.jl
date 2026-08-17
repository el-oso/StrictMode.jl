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
function _verify_strict_def(@nospecialize(f), @nospecialize(types::Tuple), target)
    Base.isdispatchtuple(Tuple{types...}) || return begin
        @warn "@strict_function $target: signature has non-concrete argument types " *
            "$(types); precompile guarantees skipped (call sites can still use @strict)."
        nothing
    end
    # Record it so the automatic drivers (check_all, @strict module, the Revise loop) re-check it.
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
    # at the enclosing module's PRECOMPILE, so it must not require an analysis backend: a package
    # annotating its own `src/` depends on `StrictMode` alone, and AllocCheck/JET live in
    # `StrictModeTest`, which is a test-environment dependency and is not loadable here. With the
    # backend absent we use the value-free IR heuristic; a test run that adds `StrictModeTest`
    # re-checks the same declarations against the proof.
    if !backend_available()
        sig = _alloc_signals(f, types)
        if sig.alloc || sig.boxing || sig.abscontainer !== nothing
            # WARN, never throw. This runs at the enclosing module's precompile, where the proof is
            # unreachable by construction — so under `fail_mode = :error` a heuristic false positive
            # would abort the consumer's module load for code that may be provably clean. That is
            # exactly what made checks-on unusable in PureBLAS (issue #18 part 2, a `trmv!` false
            # positive), and the heuristic's measured false-positive rate on a real consumer is ~28%
            # (issue #17: 19 of 68, every one measuring 0 bytes). A build must not be decidable by a
            # structural guess. The declaration is registered either way, so a test run with
            # `StrictModeTest` loaded re-checks this same signature against AllocCheck and DOES fail.
            @warn "@strict_function $target: " *
                _box_msg(
                "allocates / boxes (fast heuristic — a structural guess, not a proof; " *
                    "add StrictModeTest to your test environment to resolve it)", sig
            )
        end
        return nothing
    end
    try
        results, _ = _checked_allocs(f, types)
        isempty(results) || _fail(:strict_function, target, _format_allocs(results))
    catch err
        err isa StrictViolation && rethrow()
        @warn "@strict_function $target: AllocCheck could not analyze this signature ($err)"
    end
    return nothing
end

"""
    @strict_function function f(x::T, ...) ... end
    @strict_function f(x::T, ...) = ...

Define `f` and, when checks are enabled, verify its contract at precompile time against the
declared argument types. The return type must be concrete and the body must not allocate, with
runtime dispatch and boxing counting as allocations. Break the contract and the enclosing module
won't load, rather than being discovered at the next profiling session.

Only concrete signatures are verified this way. Signatures with abstract types or varargs emit a
one-time warning and fall back to call-site [`@strict`](@ref) checks. With checks disabled this is
just the plain definition.

```julia
@strict_function dot3(a::NTuple{3,Float64}, b::NTuple{3,Float64}) =
    a[1]*b[1] + a[2]*b[2] + a[3]*b[3]    # loads fine: stable + non-allocating
```
"""
macro strict_function(def)
    sig = _strictdef_sig(def)
    fname = sig.args[1]
    argexprs = filter(a -> !Meta.isexpr(a, :parameters), sig.args[2:end])
    argtypes = Expr(:tuple, (esc(_argtype(a)) for a in argexprs)...)
    target = string(fname) * "(" * join((string(_argtype(a)) for a in argexprs), ", ") * ")"

    checked = quote
        $(esc(def))
        $(_verify_strict_def)($(esc(fname)), $argtypes, $target)
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
by `check_all`, `audit`, the whole-module load check, and `check_compiled` sweeps. It's never
gated; the exemption always applies.
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
