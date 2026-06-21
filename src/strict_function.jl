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
    all(isconcretetype, types) || return begin
        @warn "@strict_function $target: signature has non-concrete argument types " *
            "$(types); precompile guarantees skipped (call sites can still use @strict)."
        nothing
    end
    # Type stability: the return type for this signature must be concrete.
    rts = Base.return_types(f, Tuple{types...})
    if length(rts) != 1 || !isconcretetype(only(rts))
        _fail(
            :strict_function, target,
            "return type is not concrete for ($(join(types, ", "))): inferred $(rts)"
        )
    end
    # Allocation-freedom (subsumes runtime dispatch / boxing, which show as allocations).
    try
        results = check_allocs(f, types)
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

Define `f` and, when checks are enabled, **verify its contract at precompile time** against the
declared argument types: the return type must be concrete and the body must not allocate
(runtime dispatch / boxing count as allocations). If the contract is violated the enclosing
module fails to load — the same "won't compile if it's wrong" guarantee Rust gives.

Only *concrete* signatures are verified statically; signatures with abstract types or varargs
emit a one-time warning and are left to call-site [`@strict`](@ref) checks. When checks are
disabled this expands to the plain definition.

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
