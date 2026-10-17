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
guarantees ([`@strict`](@ref): type stability throws, owned scratch and allocation warn). The calls
run against the
instances and values you bind in the surrounding scope.

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
macro verify_strict(T, block)
    # Forward the interface-surface check to TypeContracts.@verify. `esc` the whole macrocall so
    # our layer supplies the escape level the nested macro needs to resolve `T` in the caller.
    verify_call = esc(
        Expr(
            :macrocall,
            GlobalRef(TypeContracts, Symbol("@verify")), __source__, T
        )
    )

    stmts = Meta.isexpr(block, :block) ? block.args : Any[block]
    out = Any[verify_call]
    for s in stmts
        s isa LineNumberNode && continue
        push!(out, _strict_expr(s))   # already fully escaped + self-gated
    end
    push!(out, :nothing)
    return Expr(:block, out...)
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
