# The proof tier's half of StrictMode's `sweep_invoke_test.jl`: a specialization compiled only
# through `invoke` of a wider method is proved as that method, by every gate and by both engines.

@testitem "a gate proves a specialization compiled through a wider invoke as that method" begin
    using StrictMode, StrictModeTest
    include(joinpath(pkgdir(StrictMode), "test", "sweep_invoke_fixtures.jl"))
    M = SweepInvoke
    register_scoped!(M.Handle)
    M.warm!()
    failed(f, tt, g) = StrictMode._failed(only(proof_findings(f, tt; guarantees = (g,))))
    wide(x) = occursin(" via invoke of ", x.signature)
    for g in StrictMode._GUARANTEES
        tt = M.argtypes(g)
        dirty = failed(getfield(M, Symbol(g, :_dp)), tt, g)
        @test !failed(getfield(M, Symbol(g, :_cp)), tt, g)
        sweeps = (
            proof_findings(M; guarantees = (g,), only = M.names_for(g)),
            proof_audit(M; sweep = true, guarantees = (g,), only = M.names_for(g), dispatch_suggest = false),
        )
        for fs in sweeps
            row(name, w) = only(filter(x -> x.func == string(g, name) && wide(x) == w, fs))
            @test length(fs) == 4
            @test StrictMode._failed(row(:_d, true)) == dirty
            @test !StrictMode._failed(row(:_d, false))
            @test !StrictMode._failed(row(:_c, true))
            @test StrictMode._failed(row(:_c, false)) == dirty
        end
        # The gate fails exactly the dirty rows: the wider method of `_d`, the specific one of `_c`.
        for (name, w) in ((:_d, true), (:_c, false))
            if dirty
                err = try
                    test_compiled(M; guarantees = (g,), only = [Symbol(g, name)])
                    nothing
                catch e
                    e
                end
                @test err isa StrictViolation
                @test occursin(" via invoke of ", sprint(showerror, err)) == w
            else
                @test test_compiled(M; guarantees = (g,), only = [Symbol(g, name)]) isa Vector
            end
        end
        # The two engines agree on every row.
        for (f, types, _) in StrictMode._compiled_items(M; guarantees = (g,), only = M.names_for(g))
            d = divergence_report(f, types; guarantees = (g,))
            @test isempty(d)
            @test isempty(d.cause_diverged)
        end
    end
end

@testitem "test_coverage counts a declaration for the method it dispatches to only" begin
    using StrictMode, StrictModeTest
    include(joinpath(pkgdir(StrictMode), "test", "sweep_invoke_fixtures.jl"))
    M = SweepInvoke
    M.warm!()
    A = Vector{Float64}
    StrictMode.clear_declarations!()
    try
        StrictMode.register_strict!(M.noalloc_d, (A, Int); guarantees = (:noalloc,))
        err = try
            test_coverage(M; only = [:noalloc_d])
            nothing
        catch e
            e
        end
        @test err isa StrictViolation
        @test occursin("(Vector{Float64}, Int64) via invoke of (Vector{Float64}, Integer)", err.details)
        # The rows that are declared pass the gate.
        StrictMode.register_strict!(M.noalloc_dp, (A, Int); guarantees = (:noalloc,))
        @test test_coverage(M; only = [:noalloc_dp]) isa Vector
    finally
        StrictMode.clear_declarations!()
    end
end

@testitem "a proof honors a narrow exemption for the method it names only" begin
    using StrictMode, StrictModeTest
    include(joinpath(pkgdir(StrictMode), "test", "narrow_invoke_fixtures.jl"))
    A = Vector{Float64}
    wide(x) = occursin(" via invoke of ", x.signature)
    sweep(M) = proof_findings(M; guarantees = (:noalloc,), only = [:d, :c])
    row(fs, name, w) = only(filter(x -> x.func == name && wide(x) == w, fs)).status
    proof(f; kw...) = only(proof_findings(f, (A, Int); guarantees = (:noalloc,), kw...))

    N = narrow_invoke_module(@__MODULE__, "ProofNarrowSpecific", "(Vector{Float64}, Int)")
    fs = sweep(N)
    @test length(fs) == 4
    @test row(fs, "d", true) === :fail
    @test row(fs, "d", false) === :info
    @test row(fs, "c", true) === :pass
    @test row(fs, "c", false) === :info
    @test proof(N.dv).status === :fail
    @test proof(N.dv).code === :SM0002
    @test proof(N.cv).status === :pass
    err = try
        test_compiled(N; guarantees = (:noalloc,), only = [:d])
        nothing
    catch e
        e
    end
    @test err isa StrictViolation
    @test occursin(" via invoke of ", err.details)

    W = narrow_invoke_module(@__MODULE__, "ProofNarrowWide", "(Vector{Float64}, Integer)")
    fs = sweep(W)
    @test row(fs, "d", true) === :info
    @test row(fs, "d", false) === :pass
    @test row(fs, "c", true) === :info
    @test row(fs, "c", false) === :fail
    @test proof(W.dv).code === :SM0018
    @test proof(W.dv; allow_exempt = true).status === :info
    @test proof(W.cv).status === :pass
    @test test_compiled(W; guarantees = (:noalloc,), only = [:d]) isa Vector

    # Both engines agree on every row.
    for M in (N, W)
        for (f, types, _) in StrictMode._compiled_items(M; guarantees = (:noalloc,), only = [:d, :c, :dv, :cv])
            @test isempty(divergence_report(f, types; guarantees = (:noalloc,)))
        end
    end
end
