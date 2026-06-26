@testitem "@assert_trim_compatible + :trim_compatible (escalating: TypeContracts :fast / TrimCheck :full)" begin
    using StrictMode, TrimCheck
    @test StrictMode.trimcheck_available()                          # extension active

    safe_fn(x::Int) = x * 2 + 1
    unsafe_fn(x::Int) = length(Base.return_types(sin, (Float64,)))  # reflection → trim-unsafe

    # Macro form
    @test (@assert_trim_compatible safe_fn(3)) == 7                 # passes → returns the value
    @test_throws StrictViolation @assert_trim_compatible unsafe_fn(3)

    # :fast = TypeContracts static scan
    @test all(f -> f.status === :pass, check(safe_fn, (Int,); guarantees = (:trim_compatible,), fail = :none, mode = :fast))
    @test any(f -> f.status === :fail, check(unsafe_fn, (Int,); guarantees = (:trim_compatible,), fail = :none, mode = :fast))

    # :full = juliac's verify_typeinf_trim verifier via TrimCheck
    @test all(f -> f.status === :pass, check(safe_fn, (Int,); guarantees = (:trim_compatible,), fail = :none, mode = :full))
    fr = check(unsafe_fn, (Int,); guarantees = (:trim_compatible,), fail = :none, mode = :full)
    @test fr[1].status === :fail
    @test occursin("juliac", fr[1].reason)                         # cites the real verifier, not the static heuristic

    # back-compat: the static-only @assert_trim_safe / :trimsafe still work
    @test (@assert_trim_safe safe_fn(3)) == 7
    @test any(f -> f.status === :fail, check(unsafe_fn, (Int,); guarantees = (:trimsafe,), fail = :none))
end
