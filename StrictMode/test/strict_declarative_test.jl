@testitem "a scoped @strict_policy checks its matches and keeps the module's policy" begin
    using StrictMode

    StrictMode.clear_declarations!()

    @eval module _TwoPol
    using StrictMode
    entry_64_(x::Int) = x + 1
    kern(x::Float64) = 2x
    @strict_policy (:typestable,) only = r"_64_$"
    @strict_policy (:typestable, :noalloc) only = [:kern]
    end
    @test StrictMode.module_policy(_TwoPol) == (:typestable,)

    # An unscoped second policy would replace the module's, so it says how to scope it instead.
    @test_throws "already has a policy" (
        @eval module _TwoPolBad
        using StrictMode
        @strict_policy (:typestable,) check = false
        @strict_policy (:noalloc,) check = false
        end
    )

    # A scoped second policy still checks: an unstable match stops the module loading.
    @test_throws StrictViolation (
        @eval module _TwoPolFail
        using StrictMode
        const G = Ref{Any}(1)
        entry_64_(x::Int) = x + 1
        unstable_k(x::Int) = G[]
        @strict_policy (:typestable,) only = r"_64_$"
        @strict_policy (:typestable,) only = [:unstable_k]
        end
    )
    StrictMode.clear_declarations!()
end

@testitem "@strict_function guarantees = … checks listed signatures of a parametric kernel" setup = [NoSpillFixtures] begin
    using StrictMode

    StrictMode.clear_declarations!()

    # A parametric copy of the fixture kernels, declared through the macro so its `where` clause is
    # what `signatures` has to supply.
    function declared(mod, name, n)
        def = NoSpillFixtures._accum_kernel_expr(name, n).args[2]
        call = def.args[1]
        for k in 2:4
            call.args[k] = Expr(:(::), call.args[k].args[1], :(Vector{T}))
        end
        def.args[1] = Expr(:where, call, :T)
        decl = Expr(
            :macrocall, GlobalRef(StrictMode, Symbol("@strict_function")), LineNumberNode(1, :decl),
            :(guarantees = (:no_spill,)),
            :(signatures = [(Vector{Float64}, Vector{Float64}, Vector{Float64})]),
            def,
        )
        return Core.eval(mod, decl)
    end

    clean = Module(:_DeclClean)
    declared(clean, :pk_clean!, 4)
    decls = StrictMode.declarations()
    key = (clean.pk_clean!, (Vector{Float64}, Vector{Float64}, Vector{Float64}))
    @test haskey(decls, key)
    @test decls[key].guarantees == (:no_spill,)

    # A spill is read from compiled output, so it stops the declaring module from loading. Only
    # where this configuration's codegen spills the starved kernel at all (see the fixtures).
    if NoSpillFixtures.spills_observable()
        @test_throws StrictViolation declared(Module(:_DeclSpill), :pk_spill!, 80)
    end

    # A listed signature with no method is named as such.
    typo = Expr(
        :macrocall, GlobalRef(StrictMode, Symbol("@strict_function")), LineNumberNode(1, :typo),
        :(guarantees = (:no_spill,)), :(signatures = [(Int,)]),
        :(g(x::Vector{T}) where {T} = x),
    )
    @test_throws "no method matches" Core.eval(Module(:_DeclTypo), typo)
    StrictMode.clear_declarations!()
end
