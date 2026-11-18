# TypeContracts pairing. TypeContracts verifies the *interface surface* (the right methods with
# the right signatures/return types exist); StrictMode adds the *performance* layer (those
# methods are type-stable and non-allocating). The two compose: declare the interface with
# `@strict_contract`, then check an implementation with `@verify_strict`.

"""
    registered_strict_contracts() -> Set

The set of interface types declared via [`@strict_contract`](@ref) — i.e. interfaces whose
implementations are expected to satisfy StrictMode's performance guarantees, not just the
TypeContracts method surface.
"""
registered_strict_contracts() = STRICT_CONTRACTS
const STRICT_CONTRACTS = Set{Any}()

"""
    @strict_contract AbstractIface begin
        method(::Self, x::T)::R => "what this method is for"
        :optional
        extra(::Self)::R
    end

    @strict_contract AbstractIface "what the interface is" begin
        method(::Self, x::T)::R
    end

Declare `AbstractIface` as a TypeContracts interface (through `TypeContracts.@contract`) and record
that it carries StrictMode performance guarantees too. Verify implementations with
[`@verify_strict`](@ref), which checks both the method surface and that those methods are
type-stable (throws) and, as warnings, owned-scratch-clean and allocation-free.

The body uses the same syntax as `TypeContracts.@contract` (`::Self`, `:optional`, per-method
`=> "description"`, and so on), and — as the second form shows — an interface description may be
given as a string literal between the type and the block. Both fold into the type's `?`-visible
documentation and into `TypeContracts.describe`.
"""
macro strict_contract(T, block)
    return _strict_contract(__source__, T, nothing, block)
end

# `@contract` has had a 3-argument form (type, description, block) for as long as the 2-argument one,
# but this wrapper only ever forwarded 2, so `@strict_contract Iface "desc" begin … end` failed with a
# MethodError on the macro itself. Per-method `=> "doc"` and `:optional` were never affected — they
# live INSIDE the block, which is forwarded verbatim — so the gap was exactly the interface-level
# description, i.e. the one piece of contract documentation that is not attached to a method.
macro strict_contract(T, desc, block)
    desc isa String ||
        error("@strict_contract: interface description must be a string literal, got: $desc")
    return _strict_contract(__source__, T, desc, block)
end

function _strict_contract(src, T, desc, block)
    # Plain block (no `quote`) so the forwarded `@contract` macrocall expands with its own
    # escaping intact — a wrapping `quote` would add a hygiene layer that corrupts it.
    args = isnothing(desc) ? (T, block) : (T, desc, block)
    contract_call = Expr(
        :macrocall,
        GlobalRef(TypeContracts, Symbol("@contract")), src, args...
    )
    register = Expr(:call, push!, STRICT_CONTRACTS, esc(T))
    # `esc` the forwarded macrocall so our expansion layer supplies the escape level the nested
    # @contract needs to resolve `T` in the *caller's* module rather than in StrictMode.
    return Expr(:block, esc(contract_call), register, esc(T))
end

"""
    @verify_strict T begin
        method(obj, args...)
        ...
    end

Verify that type `T` implements its [`@strict_contract`](@ref) interface (through
`TypeContracts.@verify`), and that each representative call you list satisfies StrictMode's per-call
guarantees ([`@strict`](@ref): type stability throws, owned scratch and allocation warn). Each call
is checked at the signature its arguments give it, so the instances and values you bind in the
surrounding scope are what decide which specialization is verified.

The listed calls are **not performed**. Every check reads the argument types — an inferred return
type and a scan of typed IR — so the values serve to name those types, and this block's results
would be discarded anyway. Performing one call would compile its whole tree, which a block at a
package's top level pays for at every consumer's precompile.

Each argument expression is still evaluated once, so bind them to values that are cheap to produce.

A line may give the argument types instead of an example call: every positional argument written
`::T` and every keyword `name::T`. Nothing but the function and the type expressions is evaluated,
so no instance has to exist. Keywords may be listed in any order — the line is checked as the
`Core.kwcall` signature with the keywords in the order the method declares them — and a keyword
left out takes its default, as in a call. A keyword the method does not declare by name, or a
positional signature no single method matches, is an error. The two kinds of line may be mixed in
one block:

```julia
@verify_strict MyKPI begin
    compute(::MyKPI, ::Vector{Float64}; window::Int)
    name(k)
end
```

`@verify_strict T guarantees = (...) begin … end` checks exactly the named guarantees on each
listed call instead, the way [`@strict_function`](@ref)`guarantees = …` does, and registers each
signature so `StrictModeTest.test_registered` re-proves it. Keeping only the guarantees that gate
at load, `guarantees = (:typestable,)`, leaves the allocation verdicts — which only warn here — to
the test environment, and with them their cost at every precompile.

The interface check always runs. The per-call performance checks gate themselves on the
`checks_enabled` preference, so a production build only pays for the interface verification.

```julia
k = MyKPI("yield"); xs = rand(100)
@verify_strict MyKPI begin
    compute(k, xs)
    name(k)
end
```
"""
macro verify_strict(T, opt, block)
    Meta.isexpr(opt, :(=)) && opt.args[1] === :guarantees || throw(
        ArgumentError(
            "@verify_strict: expected `guarantees = (...)` before the block, got: $opt"
        )
    )
    return _verify_strict(__source__, __module__, T, block, opt.args[2])
end

macro verify_strict(T, block)
    return _verify_strict(__source__, __module__, T, block, nothing)
end

function _verify_strict(__source__, __module__, T, block, guarantees)
    # Forward the interface-surface check to TypeContracts.@verify. `esc` the whole macrocall so
    # our layer supplies the escape level the nested macro needs to resolve `T` in the caller.
    verify_call = esc(
        Expr(
            :macrocall,
            GlobalRef(TypeContracts, Symbol("@verify")), __source__, T
        )
    )

    stmts = Meta.isexpr(block, :block) ? block.args : Any[block]
    out = Any[]
    for s in stmts
        s isa LineNumberNode && continue
        # Already fully escaped and self-gated. The call itself is NOT performed: every check here
        # reads the argument types, this block's values are discarded, and performing one call
        # compiles its whole tree.
        p = _line_parts(s)
        push!(out, isnothing(guarantees) ? _strict_expr(s; execute = false, parts = p) : _verify_listed(s, guarantees, __source__, p))
    end
    # The interface check runs AFTER the per-call checks. Those infer each listed call at its
    # concrete types, and TypeContracts reads conformance for an unannotated member from that cached
    # result instead of inferring the contract's abstract signature.
    push!(out, verify_call, :nothing)
    return Expr(:block, out...)
end

# One listed call checked for exactly `guarantees`, through the funnel `@strict_function
# guarantees = …` uses: each guarantee gates or warns as `_guarantee_gates` says, and the signature
# is registered so the test-environment drivers re-prove it.
function _verify_listed(call, guarantees, src, p)
    srcstr = "@verify_strict at " * string(src.file) * ":" * string(src.line)
    checked = quote
        $(p.binds...)
        $(_verify_strict_guarantees)(
            $(p.checkfn), $(p.types), $(string(call)), $(esc(guarantees));
            mod = @__MODULE__, source = $srcstr
        )
    end
    return _gate(checked, nothing)
end

# --- signature lines ----------------------------------------------------------------------------

_is_sig_arg(a) = Meta.isexpr(a, :(::), 1)
_is_sig_kw(a) = Meta.isexpr(a, :(::), 2) && a.args[1] isa Symbol

# The parts of one listed line: `_signature_parts` for a signature line, `_call_parts` otherwise.
function _line_parts(line)
    p = _signature_parts(line)
    return isnothing(p) ? _call_parts(line) : p
end

# A signature line `f(::T1, ::T2; k1::K1, …)` names the argument types directly. Returns the
# `binds`/`checkfn`/`types` an example call with arguments of those types gets from `_call_parts`,
# or `nothing` when `line` is not a signature line. Only `f` and the type expressions are evaluated.
function _signature_parts(line)
    Meta.isexpr(line, :call) || return nothing
    pos = Any[]
    kws = Any[]
    for a in line.args[2:end]
        Meta.isexpr(a, :parameters) ? append!(kws, a.args) : push!(pos, a)
    end
    nsig = count(_is_sig_arg, pos) + count(_is_sig_kw, kws)
    iszero(nsig) && return nothing
    nsig == length(pos) + length(kws) || throw(
        ArgumentError(
            "@verify_strict: `$line` mixes a signature with an example call. A signature line " *
                "writes every positional argument as `::T` and every keyword as `name::T`; an " *
                "example call passes values (`f(x, y; name = value)`)."
        )
    )

    fnsym = gensym(:f)
    binds = Any[:($fnsym = $(esc(line.args[1])))]
    tsyms = [gensym(:T) for _ in pos]
    append!(binds, Any[:($s = $(esc(a.args[1]))) for (s, a) in zip(tsyms, pos)])
    postypes = Expr(:tuple, tsyms...)
    isempty(kws) && return (; binds, checkfn = fnsym, types = postypes)

    ksyms = [gensym(:K) for _ in kws]
    append!(binds, Any[:($s = $(esc(k.args[2]))) for (s, k) in zip(ksyms, kws)])
    names = Tuple(Symbol[k.args[1] for k in kws])
    sigsym = gensym(:sig)
    push!(
        binds, :(
            $sigsym = $(_signature_kwcall_types)(
                $fnsym, $postypes, $(QuoteNode(names)), $(Expr(:tuple, ksyms...)), $(string(line))
            )
        )
    )
    return (; binds, checkfn = Core.kwcall, types = sigsym)
end

# The `Core.kwcall` argument types of `f(postypes...; names::kwtypes...)`, with the keywords in the
# order the method DECLARES them. A `NamedTuple` type is order-sensitive and a caller may write
# keywords in any order, so the declared order is the one spelling every listing of the same
# keywords agrees on. A keyword left out is absent from the `NamedTuple`: the keyword sorter tests
# `isdefined(kw, :name)` and substitutes the default, as it does for a call that omits it.
function _signature_kwcall_types(@nospecialize(f), postypes::Tuple, names::Tuple, kwtypes::Tuple, line)
    tt = Tuple{postypes...}
    if !hasmethod(f, tt)
        cause = isempty(Base.methods_including_ambiguous(f, tt)) ? "no method matches" : "more than one method matches, ambiguously,"
        throw(ArgumentError("@verify_strict: $cause the positional signature ($(join(postypes, ", "))) in `$line`"))
    end
    m = which(f, tt)
    # A method taking `kw...` is held to its named keywords too: a keyword that only the splat
    # accepts has no declared position, so no order for it is canonical.
    decl = Base.kwarg_decl(m)
    for n in names
        n in decl || throw(
            ArgumentError(
                "@verify_strict: keyword `$n` in `$line` is not declared by the method it dispatches " *
                    "to, $m (declared keywords: $(join(filter(d -> !endswith(string(d), "..."), decl), ", ")))"
            )
        )
        count(==(n), names) == 1 ||
            throw(ArgumentError("@verify_strict: keyword `$n` is listed more than once in `$line`"))
    end
    order = [i for d in decl for i in eachindex(names) if names[i] === d]
    NT = NamedTuple{Tuple(names[i] for i in order), Tuple{(kwtypes[i] for i in order)...}}
    return (NT, Core.Typeof(f), postypes...)
end

# --- the TypeContracts verify hook --------------------------------------------------------------

# `@verify T` checks that an implementation has the interface's methods. Where StrictMode is loaded,
# those same methods are also checked against the module's policy, so a package that already
# verifies its interfaces does not have to remember a second macro. That is the hole this closes:
# an opt-in nobody writes is not a guarantee, and a contract is a declaration people already write.
#
# It REPORTS, never throws. `@verify` runs at the annotated package's own precompile, where the
# proving tier is not loadable, so only the value-free scan is available — and its allocation
# verdicts are structural guesses, measured 8.1% false on a 120-specialization corpus. One of those
# aborting a consumer's build is issue #18. The proofs gate later, from the test environment, where
# `test_registered` and `test_coverage` re-check the same signatures.
#
# The method is defined only where TypeContracts offers the hook, and the condition tests for the
# binding rather than for a version: a feature test follows whichever TypeContracts is resolved,
# including one newer than this package knows about.
#
# `result` is annotated because TypeContracts' own no-op fallback is
# `_verify_hook(::_VerifyHook, ::Module, T::Type, result)`: a method with that exact signature
# REPLACES the fallback rather than adding to it, and overwriting a method during precompilation is
# an error — StrictMode would not precompile at all. Narrowing one argument makes this strictly more
# specific, so both methods exist and dispatch picks this one. The annotation is therefore load-
# bearing, and the test that asserts the hook fires is what would catch `result` changing shape.
@static if isdefined(TypeContracts, :_VerifyHook)
    function TypeContracts._verify_hook(
            ::TypeContracts._VerifyHook, mod::Module, T::Type, result::NamedTuple
        )
        CHECKS_ENABLED || return nothing
        items = _contract_items(mod, T)
        isempty(items) && return nothing
        _run_and_report(
            _map_findings(_scan_findings, items), :verify, string(T), :warn
        )
        return nothing
    end
end

# The `(f, argtypes, guarantees)` triples a verified type's contract names. Only a signature that
# is a dispatch tuple can carry a verdict — a generic one infers to `Any` — and the contract has
# already resolved `::Self` to this concrete type, which is what makes these checkable at all.
function _contract_items(mod::Module, @nospecialize(T))
    entries = try
        TypeContracts.contract_signatures(mod)
    catch
        return Any[]          # a TypeContracts without the enumeration: nothing to add
    end
    gs = module_policy(mod)
    items = Any[]
    for e in entries
        (e.T === T && e.mandatory) || continue
        tt = try
            Tuple(Base.unwrap_unionall(e.sig).parameters)
        catch
            continue
        end
        Base.isdispatchtuple(Tuple{tt...}) || continue
        push!(items, (e.f, tt, gs))
    end
    return items
end
