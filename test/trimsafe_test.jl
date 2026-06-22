@testitem "@assert_trim_safe + :trimsafe guarantee (proactive, TypeContracts.trim_report)" begin
    using StrictMode
    safe_fn(x::Int) = x * 2 + 1
    unsafe_fn(x::Int) = length(Base.return_types(sin, (Float64,)))   # reflection → trim-unsafe

    @test (@assert_trim_safe safe_fn(3)) == 7                        # passes → returns the value
    @test_throws StrictViolation @assert_trim_safe unsafe_fn(3)      # reflection → fails loudly

    # As an engine guarantee — value-free, so identical in :fast and :full (no backend needed).
    @test all(f -> f.status === :pass, check(safe_fn, (Int,); guarantees = (:trimsafe,), fail = :none, mode = :fast))
    @test any(f -> f.status === :fail, check(unsafe_fn, (Int,); guarantees = (:trimsafe,), fail = :none, mode = :full))
end

@testitem ":trimsafe flows through check_compiled / audit (sweep)" begin
    using StrictMode
    module TrimMix
    hotk(x::Int) = x + 1
    reflecty(x::Int) = length(Base.return_types(sin, (Float64,)))   # trim-unsafe
    end
    TrimMix.hotk(1); TrimMix.reflecty(1)                                # compile both

    fs = check_compiled(TrimMix; guarantees = (:trimsafe,), mode = :fast)
    @test any(f -> f.func == "reflecty" && f.status === :fail, fs)
    @test any(f -> f.func == "hotk" && f.status === :pass, fs)
end

@testitem "explain_trim translates juliac output (reactive)" begin
    using StrictMode
    tf = explain_trim("not a real verifier dump")    # unrecognized → still returns a TrimFailure
    @test tf isa Exception                           # TrimFailure <: Exception
    @test tf.recognized == false
end
