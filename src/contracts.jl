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
        method(::Self, x::T)::R
        ...
    end

Declare `AbstractIface` as a TypeContracts interface (through `TypeContracts.@contract`) and record
that it carries StrictMode performance guarantees too. Verify implementations with
[`@verify_strict`](@ref), which checks both the method surface and that those methods are
type-stable and allocation-free.

The body uses the same syntax as `TypeContracts.@contract` (`::Self`, `:optional`, and so on).
"""
macro strict_contract(T, block)
    # Plain block (no `quote`) so the forwarded `@contract` macrocall expands with its own
    # escaping intact — a wrapping `quote` would add a hygiene layer that corrupts it.
    contract_call = Expr(
        :macrocall,
        GlobalRef(TypeContracts, Symbol("@contract")), __source__, T, block
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
guarantees ([`@strict`](@ref), so type-stable and non-allocating). The calls run against the
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
