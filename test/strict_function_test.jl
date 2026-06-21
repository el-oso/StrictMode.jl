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
    # Return type Union{Int,Float64} for a concrete Int signature.
    @test_throws StrictViolation begin
        @strict_function maybe(x::Int) = x > 0 ? x : 1.0
    end
end

@testitem "@strict_function skips (warns on) a non-concrete signature" begin
    using StrictMode
    # Abstract arg type → static guarantees are skipped, definition still loads.
    @strict_function generic(x::Number) = x + one(x)
    @test generic(3) == 4
end
