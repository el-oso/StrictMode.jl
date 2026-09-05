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
