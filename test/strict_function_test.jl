@testitem "@strict_function loads a clean definition and it works" begin
    using StrictMode
    @strict_function square(x::Int) = x * x
    @test square(7) == 49
end

@testitem "@strict_function rejects an allocating definition at definition time" begin
    using StrictMode
    @test_throws StrictViolation begin
        @strict_function leaky(n::Int) = sum(collect(1:n))
    end
end

@testitem "@strict_function rejects a type-unstable definition" begin
    using StrictMode
    # Return type Union{Int,String} is a heap-boxing union — not accepted (F21).
    @test_throws StrictViolation begin
        @strict_function maybe(x::Int) = x > 0 ? x : "nope"
    end
end

@testitem "@strict_function skips (warns on) a non-concrete signature" begin
    using StrictMode
    # Abstract arg type → static guarantees are skipped, definition still loads.
    @strict_function generic(x::Number) = x + one(x)
    @test generic(3) == 4
end

@testitem "@strict_function verifies (does not skip) a ::Type{T} argument signature (F37)" begin
    using StrictMode
    empty!(StrictMode.registered_strict())
    # `Type{Float64}` is a fully-specified dispatch signature, not a non-concrete one — it used to
    # be silently skipped (isconcretetype(Type{Float64}) == false) even though it's checkable. (A
    # `where {T}`-generic `::Type{T}` argument is a separate, pre-existing limitation: the macro
    # evaluates the argument-type expression outside the method body, where a `where`-bound `T`
    # isn't a valid symbol — unrelated to the isdispatchtuple fix, so tested here with a literal
    # concrete `Type{Float64}` argument instead.)
    @strict_function typed_clean(::Type{Float64}, n::Int) = n + 1
    @test !isempty(StrictMode.registered_strict())
    @test typed_clean(Float64, 3) == 4
end
