# A module sweep meets specializations no call dispatches to: `invoke` of a wider method compiles
# that method for argument types a more specific method answers. Each such row must be checked as
# the method that compiled it, and the more specific method as itself.

@testitem "a sweep checks a specialization compiled through a wider invoke as that method" begin
    using StrictMode
    include(joinpath(@__DIR__, "sweep_invoke_fixtures.jl"))
    M = SweepInvoke
    register_scoped!(M.Handle)
    M.warm!()
    failed(f, tt, g) = StrictMode._failed(only(findings(f, tt; guarantees = (g,))))
    wide(x) = occursin(" via invoke of ", x.signature)
    for g in StrictMode._GUARANTEES
        tt = M.argtypes(g)
        # What the dirty body's verdict is in this configuration; the clean body always passes.
        dirty = failed(getfield(M, Symbol(g, :_dp)), tt, g)
        @test !failed(getfield(M, Symbol(g, :_cp)), tt, g)
        sweeps = (
            StrictMode._findings_compiled(M; guarantees = (g,), only = M.names_for(g)),
            audit(M; sweep = true, guarantees = (g,), only = M.names_for(g), dispatch_suggest = false),
        )
        for fs in sweeps
            row(name, w) = only(filter(x -> x.func == string(g, name) && wide(x) == w, fs))
            @test length(fs) == 4
            @test StrictMode._failed(row(:_d, true)) == dirty
            @test !StrictMode._failed(row(:_d, false))
            @test !StrictMode._failed(row(:_c, true))
            @test StrictMode._failed(row(:_c, false)) == dirty
            # The rows of one function have their own keys.
            @test allunique(StrictMode.key.(fs))
        end
    end
end

@testitem "the sweep's advisory reports read a wider invoke's specialization as that method" begin
    using StrictMode
    include(joinpath(@__DIR__, "sweep_invoke_fixtures.jl"))
    M = SweepInvoke
    M.warm!()
    # `noboxing_d`'s wider method dispatches at run time and its specific one does not; `noboxing_c`
    # is the other way round.
    r = dispatch_report(M; only = M.names_for(:noboxing))
    @test sort([(s.func, occursin(" via invoke of ", s.signature)) for s in r.dynamic]) ==
        [("noboxing_c", false), ("noboxing_d", true)]
    @test r.nclear == 2

    # A per-method report reads each method's own compiled code.
    module Thrower
    t(x::Int, n::Integer) = throw(ArgumentError("n = $n"))
    t(x::Int, n::Int) = x + n
    via(x::Int, n::Int) = invoke(t, Tuple{Int, Integer}, x, n)
    end
    @test_throws ArgumentError Thrower.via(1, 2)
    Thrower.t(1, 2)
    fs = throw_report(Thrower; only = [:t])
    @test length(fs) == 1
    @test occursin("Integer", only(fs).signature)
    @test occursin("ArgumentError", only(fs).reason)
end
