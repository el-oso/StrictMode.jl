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
