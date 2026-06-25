# F19: @golden gated bit-exact regression harness

@testitem "F19 golden harness — record-then-compare, ULP tolerance, mismatch" tags = [:f19] begin
    using StrictMode

    mktempdir() do tmpdir
        # --- exact match (ulps=0 default) ---
        # Record
        x = [1.0, 2.0, 3.0]
        r1 = @golden "vec_exact" copy(x) dir=tmpdir
        @test r1 == x
        @test isfile(joinpath(tmpdir, "vec_exact.golden"))

        # Compare (same value) → passes
        r2 = @golden "vec_exact" copy(x) dir=tmpdir
        @test r2 == x

        # --- scalar Float64 record + compare ---
        s1 = @golden "scalar" 42.0 dir=tmpdir
        @test s1 === 42.0
        s2 = @golden "scalar" 42.0 dir=tmpdir
        @test s2 === 42.0

        # --- 1-ULP perturbation: fails with ulps=0, passes with ulps=1 ---
        v = [1.0]
        @golden "ulp_test" v dir=tmpdir   # record
        v1 = nextfloat(1.0)               # 1 ULP away
        perturbed = [v1]

        @test_throws StrictViolation @golden "ulp_test" perturbed dir=tmpdir         # ulps=0 → fail
        @test (@golden "ulp_test" perturbed dir=tmpdir ulps=1) == perturbed          # ulps=1 → pass

        # --- shape/type mismatch errors clearly ---
        long_vec = [1.0, 2.0, 3.0, 4.0]
        err = try
            @golden "vec_exact" long_vec dir=tmpdir   # different length than recorded [1,2,3]
            nothing
        catch e
            e
        end
        @test err isa StrictViolation
        @test occursin("mismatch", err.details)

        # --- Float32 array ---
        y32 = Float32[1.0, 2.0]
        @golden "f32" y32 dir=tmpdir
        r32 = @golden "f32" Float32[1.0, 2.0] dir=tmpdir
        @test r32 isa Vector{Float32}
        @test r32 == y32

        # --- ComplexF64 array ---
        z = ComplexF64[1.0+2.0im, 3.0+4.0im]
        @golden "complex" z dir=tmpdir
        rc = @golden "complex" copy(z) dir=tmpdir
        @test rc == z

        # --- unsupported type throws clearly ---
        err2 = try
            @golden "str" "hello" dir=tmpdir
            nothing
        catch e
            e
        end
        @test err2 isa Exception
        @test occursin("unsupported", string(err2))

        # --- STRICTMODE_RECORD_GOLDEN=1 forces re-record ---
        orig_env = get(ENV, "STRICTMODE_RECORD_GOLDEN", "")
        try
            ENV["STRICTMODE_RECORD_GOLDEN"] = "1"
            # Re-record with a different value overwrites; subsequent compare must match
            new_x = [10.0, 20.0, 30.0]
            @golden "vec_exact" new_x dir=tmpdir   # re-records
        finally
            if isempty(orig_env)
                delete!(ENV, "STRICTMODE_RECORD_GOLDEN")
            else
                ENV["STRICTMODE_RECORD_GOLDEN"] = orig_env
            end
        end
        # Now the golden matches the new value
        r3 = @golden "vec_exact" [10.0, 20.0, 30.0] dir=tmpdir
        @test r3 == [10.0, 20.0, 30.0]
    end
end

@testitem "@golden validator= semantic invariant (F27)" begin
    using StrictMode

    # validator path: no golden file, just invariant check
    mktempdir() do d
        # Passing invariant
        result = @golden "round_trip" 3.14 validator=x->(x isa Float64) dir=d
        @test result === 3.14

        # Failing invariant throws StrictViolation
        err = try
            @golden "bad" 3.14 validator=x->false dir=d
        catch e
            e
        end
        @test err isa StrictViolation
        @test occursin("semantic invariant", err.details)
    end
end
