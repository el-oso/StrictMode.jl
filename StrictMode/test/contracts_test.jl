
@testitem "a TypeContracts @verify carries the performance guarantees too" begin
    using StrictMode, TypeContracts

    # The enforcement story: a contract is a declaration people already write, so the guarantees
    # ride along with it. Nobody writes a StrictMode macro here.
    @test isdefined(TypeContracts, :_VerifyHook)
    @test any(m -> m.module === StrictMode, methods(TypeContracts._verify_hook))

    abstract type HookShape end
    function hookarea end
    @contract HookShape begin
        hookarea(::Self)::Float64
    end

    struct HookClean <: HookShape
        r::Float64
    end
    hookarea(c::HookClean) = c.r * 2.0

    struct HookBoxy <: HookShape
        p::Vector{Any}
    end
    # The declared return keeps the interface satisfied; the abstract element type does not.
    hookarea(b::HookBoxy)::Float64 = sum(x -> Float64(x), b.p)

    # A clean implementation is silent: a verify that printed for every passing type would be
    # noise, and noise is what gets a check switched off.
    @test_logs @verify HookClean

    # One that satisfies the interface and not the guarantees warns, naming each guarantee.
    msg = @test_logs (:warn,) match_mode = :any @verify HookBoxy
    @test msg isa Any

    # It must WARN, never throw: `@verify` runs at the annotated package's own precompile, where
    # the proving tier cannot load, so only the guessing engine is available — and a guess that
    # aborts a consumer's build is issue #18.
    @test (@verify HookBoxy; true)

    # The signatures it checks come from the contract, which has already resolved `::Self` to the
    # concrete type — the reason these are checkable when a generic declaration is not.
    items = StrictMode._contract_items(@__MODULE__, HookBoxy)
    @test !isempty(items)
    @test all(it -> Base.isdispatchtuple(Tuple{it[2]...}), items)
end
