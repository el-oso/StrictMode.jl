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

@testitem "a declaration covers only the method its signature dispatches to" begin
    using StrictMode
    include(joinpath(@__DIR__, "sweep_invoke_fixtures.jl"))
    M = SweepInvoke
    M.warm!()
    A = Vector{Float64}
    undeclared(name) = filter(
        x -> x.guarantee === :coverage && x.status === :fail, audit(M; require = :all, only = [name])
    )
    StrictMode.clear_declarations!()
    try
        # `(A, Int)` dispatches to the specific method, so the wider method's row, compiled for the
        # same argument types through `invoke`, is undeclared, and the finding says why.
        StrictMode.register_strict!(M.noalloc_d, (A, Int); guarantees = (:noalloc,))
        fs = undeclared(:noalloc_d)
        @test length(fs) == 1
        @test only(fs).signature == "(Vector{Float64}, Int64) via invoke of (Vector{Float64}, Integer)"
        @test occursin("invoke", only(fs).reason)
        @test occursin("@strict_exempt", only(fs).suggestion)
        # A signature the wider method is dispatched for declares that method's row, and only it.
        M.noalloc_d([1.0], Int32(1))
        @test length(undeclared(:noalloc_d)) == 2
        StrictMode.register_strict!(M.noalloc_d, (A, Int32); guarantees = (:noalloc,))
        fs = undeclared(:noalloc_d)
        @test length(fs) == 1
        @test occursin(" via invoke of ", only(fs).signature)
        # A function with one method is covered by its declaration, as before.
        StrictMode.register_strict!(M.noalloc_dp, (A, Int); guarantees = (:noalloc,))
        @test isempty(undeclared(:noalloc_dp))
        @test length(undeclared(:noalloc_cp)) == 1
    finally
        StrictMode.clear_declarations!()
    end
end

@testitem "a narrow exemption excuses only the method its signature dispatches to" begin
    using StrictMode
    include(joinpath(@__DIR__, "narrow_invoke_fixtures.jl"))
    A = Vector{Float64}
    wide(x) = occursin(" via invoke of ", x.signature)
    sweep(M) = StrictMode._findings_compiled(M; guarantees = (:noalloc,), only = [:d, :c])
    row(fs, name, w) = only(filter(x -> x.func == name && wide(x) == w, fs)).status
    scan(f) = only(findings(f, (A, Int); guarantees = (:noalloc,)))

    # `(A, Int)` names the specific methods. The wider ones are judged on their own: `d`'s allocates
    # and fails, `c`'s is clean and passes, and a caller reaching `d`'s through `invoke` fails.
    N = narrow_invoke_module(@__MODULE__, "NarrowSpecific", "(Vector{Float64}, Int)")
    fs = sweep(N)
    @test length(fs) == 4
    @test row(fs, "d", true) === :fail
    @test row(fs, "d", false) === :info
    @test row(fs, "c", true) === :pass
    @test row(fs, "c", false) === :info
    @test scan(N.dv).status === :fail
    @test scan(N.dv).code === :SM0002
    @test scan(N.cv).status === :pass

    # `(A, Integer)` names the wider methods, which excuses their rows and the call `invoke` makes,
    # and leaves the specific ones judged.
    W = narrow_invoke_module(@__MODULE__, "NarrowWide", "(Vector{Float64}, Integer)")
    fs = sweep(W)
    @test row(fs, "d", true) === :info
    @test row(fs, "d", false) === :pass
    @test row(fs, "c", true) === :info
    @test row(fs, "c", false) === :fail
    @test scan(W.dv).status === :info
    @test scan(W.cv).status === :pass
    # A row the wider method is dispatched for is in that method and within the signature named, so
    # `(A, Integer)` excuses it and `(A, Int)` does not.
    int32(M) = only(filter(x -> x.func == "d" && occursin("Int32", x.signature), sweep(M))).status
    W.d([1.0], Int32(1))
    N.d([1.0], Int32(1))
    @test int32(W) === :info
    @test int32(N) === :fail
end
