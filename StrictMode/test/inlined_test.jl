@testitem "@assert_inlined passes on an inlined call and returns its value" begin
    using StrictMode
    @inline hot(x) = x * x + 1
    @test (@assert_inlined hot(3.0)) === 10.0
end

@testitem "@assert_inlined fails when the call is not inlined" begin
    using StrictMode
    @noinline cold(x) = x * x + 1
    @test_throws StrictViolation @assert_inlined cold(3.0)
end

@testitem "@assert_inlined treats builtins as inlined" begin
    using StrictMode
    # `which(+, (Float64, Float64))` resolves, but the lowered + is absorbed — no surviving
    # :invoke — so this passes.
    @test (@assert_inlined 1.0 + 2.0) === 3.0
end

@testitem "@assert_inlined reads the body behind a default or keyword argument" begin
    using StrictMode
    # Large enough that the compiler does not inline it by cost; the forwarder that supplies the
    # default is small and does inline, so the body survives as a call to the full signature.
    function big(x::Float64, n::Int = 4)
        s = x
        for i in 1:n, j in 1:n, k in 1:n
            s = muladd(s, sin(s), cos(i * j * k * s))
        end
        return s
    end
    function kwbig(x::Float64; n::Int = 4)
        s = x
        for i in 1:n, j in 1:n, k in 1:n
            s = muladd(s, sin(s), cos(i * j * k * s))
        end
        return s
    end
    @test StrictMode._inlined_survives(big, (Float64, Int)) === true
    @test StrictMode._inlined_survives(big, (Float64,)) === true
    @test StrictMode._failed(only(findings(big, (Float64,); guarantees = (:inlined,))))
    @test_throws StrictViolation @assert_inlined big(1.0)
    @test StrictMode._inlined_survives(kwbig, (Float64,)) === true
    @test StrictMode._inlined_survives(Core.kwcall, (typeof((; n = 2)), typeof(kwbig), Float64)) === true
    @test_throws StrictViolation @assert_inlined kwbig(1.0; n = 2)
    @test_throws StrictViolation @assert_inlined kwbig(1.0)
    # A small function with a default argument still inlines whole.
    @inline small(x::Float64, n::Int = 2) = x * n
    @test StrictMode._inlined_survives(small, (Float64,)) === false
end
