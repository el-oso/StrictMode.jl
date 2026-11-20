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

    # Naming an existing function declares its signatures without defining anything, which is the
    # form for an `@generated` definition.
    named(mod, name) = Core.eval(
        mod, Expr(
            :macrocall, GlobalRef(StrictMode, Symbol("@strict_function")), LineNumberNode(1, :named),
            :(guarantees = (:no_spill,)),
            :(signatures = [(Vector{Float64}, Vector{Float64}, Vector{Float64})]), name,
        )
    )
    gen = Module(:_DeclGen)
    Core.eval(gen, :(@generated gsum(o::Vector{T}, a::Vector{T}, b::Vector{T}) where {T} = :(sum(a))))
    @test isnothing(named(gen, :gsum))
    @test haskey(StrictMode.declarations(), (gen.gsum, (Vector{Float64}, Vector{Float64}, Vector{Float64})))
    if NoSpillFixtures.spills_observable()
        spill = Module(:_DeclNamedSpill)
        Core.eval(spill, :(const k! = $(NoSpillFixtures.spilly_accum_kernel!)))
        @test_throws StrictViolation named(spill, :k!)
    end
    @test_throws "needs `signatures" Core.eval(
        gen, Expr(:macrocall, GlobalRef(StrictMode, Symbol("@strict_function")), LineNumberNode(1, :n), :gsum)
    )

    # A listed signature with no method is named as such.
    typo = Expr(
        :macrocall, GlobalRef(StrictMode, Symbol("@strict_function")), LineNumberNode(1, :typo),
        :(guarantees = (:no_spill,)), :(signatures = [(Int,)]),
        :(g(x::Vector{T}) where {T} = x),
    )
    @test_throws "no method matches" Core.eval(Module(:_DeclTypo), typo)
    StrictMode.clear_declarations!()
end

@testitem "@strict_policy raises when it has nothing to check at its line" begin
    using StrictMode

    load(src) = Core.eval(@__MODULE__, Meta.parse(src))
    unstable = "later(x::Int) = x > 0 ? 1 : \"s\""

    # A policy checks the methods defined ABOVE it. Written first, it finds none, and loading on
    # would read as a module that satisfies its policy: the unstable method below is never read.
    @test_throws "@strict_policy checked nothing: no method is defined above this line in `PolFirst`" load("module PolFirst; using StrictMode; @strict_policy :typestable; $unstable; end")
    @test_throws "place `@strict_policy` at the end of the module, or use `@strict module`" load("module PolFirstB; using StrictMode; @strict_policy :typestable; $unstable; end")
    # The same with a filter: there is nothing above it for the name to match yet.
    @test_throws "no method is defined above this line in `PolFirstOnly`" load("module PolFirstOnly; using StrictMode; @strict_policy :typestable only = (:later,); $unstable; end")
    @test_throws "no method is defined above this line" load("module PolFirstExempt; using StrictMode; @strict_policy :typestable exempt = (:later,); $unstable; end")

    # Written last, it reads the method.
    @test_throws StrictMode.StrictViolation load("module PolLast; using StrictMode; $unstable; @strict_policy :typestable; end")
    @test_throws StrictMode.StrictViolation load("module PolLastOnly; using StrictMode; $unstable; @strict_policy :typestable only = (:later,); end")
    @test load("module PolLastClean; using StrictMode; ok(x::Int) = x + 1; @strict_policy :typestable; end") isa Module

    # A policy that does check something still rejects a name that matches nothing.
    @test_throws "`only` names `latr`, which matches no function" load("module PolTypo; using StrictMode; ok(x::Int) = x + 1; @strict_policy :typestable only = (:latr,); end")

    # Methods above it, none of them with a concrete signature to check.
    @test_throws "@strict_policy checked nothing: 1 method(s) are defined above this line in `PolGeneric`, and none has a concrete signature" load("module PolGeneric; using StrictMode; gen(x::AbstractVector) = sum(x); @strict_policy :typestable; end")
    @test_throws "check = false" load("module PolGenericB; using StrictMode; gen(x::AbstractVector) = sum(x); @strict_policy :typestable; end")

    # `check = false` records the policy and checks nothing, by request.
    @test load("module PolRecorded; using StrictMode; @strict_policy :typestable check = false only = (:later,); $unstable; end") isa Module
    @test StrictMode.module_policy(PolRecorded) == (:typestable,)
end
