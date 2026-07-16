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

@testitem "issue #13: a heuristic PASS stays :pass/empty-reason (back-compat) and notes the coverage gap" begin
    using StrictMode
    # status/reason on the structured StrictFinding are deliberately untouched by the issue #13
    # caveat — this pins the back-compat contract explicitly (a heuristic PASS is not distinguishable
    # from an authoritative one via `findings`/`check`; the caveat is macro-path-only visibility).
    safe_fn(x::Int) = x * 2 + 1
    fs = only(check(safe_fn, (Int,); guarantees = (:trimsafe,), fail = :none, mode = :fast))
    @test fs.status === :pass
    @test fs.reason == ""

    # The macro's own PASS is unaffected functionally (returns the call's value as before).
    @test (@assert_trim_safe safe_fn(3)) == 7
    @test (@assert_trim_compatible safe_fn(3)) == 7

    # The one-time session note actually fires. `@test_logs` installs its own fresh logger for the
    # duration of the block, so it captures this `maxlog=1` (this repo's standing convention for a
    # hot-path advisory, same as _assert_noalloc's gc_num note) note independently of whatever else
    # ran earlier against the DEFAULT logger in this shared test worker — verified directly: a
    # maxlog=1 message already fired once against Base's default logger is still captured by a
    # subsequent `@test_logs` on the same call, since maxlog counting lives on the active logger
    # instance, not globally per call site.
    @test_logs (:info, r"reachability-limit union-splits") match_mode = :any (@assert_trim_safe safe_fn(3))
end
