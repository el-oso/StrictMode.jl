@testitem "@unroll over a literal range produces correct results" begin
    using StrictMode
    function s(t)
        acc = 0.0
        @unroll for i in 1:3
            acc += t[i]
        end
        return acc
    end
    @test s((1, 2.0, 3.0f0)) == 6.0
end

@testitem "@unroll over a tuple literal binds each element" begin
    using StrictMode
    out = Float64[]
    @unroll for x in (1, 2.5, 3.0f0)
        push!(out, Float64(x))
    end
    @test out == [1.0, 2.5, 3.0]
end

@testitem "@unroll removes the runtime-tuple-index boxing (the founding trap)" begin
    using StrictMode
    htup = (1, 2.0, 3.0f0)
    function naive(t)
        acc = 0.0
        for i in 1:3
            acc += t[i]           # runtime index over a heterogeneous tuple → boxes
        end
        return acc
    end
    function unrolled(t)
        acc = 0.0
        @unroll for i in 1:3
            acc += t[i]           # → acc += t[1]; t[2]; t[3]   (literal, no boxing)
        end
        return acc
    end
    @test naive(htup) == unrolled(htup)          # same answer
    # The naive loop is type-stable (concrete Float64 return) yet still allocates — exactly the
    # silent trap @assert_noalloc exists to catch — while the unrolled version is clean.
    @test_throws StrictViolation (@assert_noalloc naive(htup))
    @test (@assert_noalloc unrolled(htup)) == 6.0
end

@testitem "@unroll rejects a non-statically-known iteration" begin
    using StrictMode
    @test_throws ArgumentError StrictMode._unroll_values(:(1:n))
    @test_throws ArgumentError StrictMode._unroll_values(:(eachindex(t)))
end

@testitem "staticval lifts a count into the type domain" begin
    using StrictMode
    @test staticval(4) === Val(4)
    @test staticval(4) isa Val{4}
end
