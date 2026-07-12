# F21: Union{T,Nothing} and other isbits unions should pass @assert_typestable.

@testitem "Union{T,Nothing} passes @assert_typestable (F21)" begin
    using StrictMode

    finds_it(v::Vector{Int}, x::Int) = findfirst(==(x), v)   # returns Union{Int,Nothing}

    @test @assert_typestable(finds_it([1, 2, 3], 2)) == 2
    @test isnothing(@assert_typestable(finds_it([1, 2, 3], 9)))

    # non-isbits union still fails
    unstable(x::Int) = x > 0 ? x : "nope"
    err = try
        @assert_typestable(unstable(1)); nothing
    catch e
        e
    end
    @test err isa StrictViolation

    # batch path: isbits union → :pass
    fs = check(finds_it, (Vector{Int}, Int); guarantees = (:typestable,), fail = :none)
    @test first(fs).status === :pass

    # batch path: non-isbits union → :fail
    fs2 = check(unstable, (Int,); guarantees = (:typestable,), fail = :none)
    @test first(fs2).status === :fail
end
