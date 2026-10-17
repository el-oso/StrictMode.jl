# The `@test_*` surface: the same properties StrictMode's `@assert_*` report on, but proved, and
# gating.

@testitem "the @test_* macros gate where the @assert_* macros only report" setup = [Fixtures] begin
    using StrictMode, StrictModeTest
    # This is the split's whole premise: the same property, two macros, and only one of them can
    # break a build.
    @test_throws StrictViolation @test_noalloc Fixtures.allocs(4)
    @test (@test_noalloc Fixtures.clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
    @test_throws StrictViolation @test_noboxing Fixtures.boxy((1, 2.0, 3.0f0))
    @test (@test_typestable Fixtures.clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
    @test (@test_trim_compatible Fixtures.clean((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0

    # …while StrictMode's own macro warns on the very same call.
    @test_logs (:warn,) match_mode = :any (@assert_noalloc Fixtures.allocs(4))
end

@testitem "the composite proving macros" begin
    using StrictMode, StrictModeTest
    clean2(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    SINK2 = Ref{Any}(nothing)
    allocs2(n::Int) = (v = rand(n); SINK2[] = v; length(v))
    allocs2(4)
    @test @allocated(allocs2(4)) > 0          # the fixture must still be bad

    @test (@test_strict clean2((1.0, 2.0, 3.0), (1.0, 2.0, 3.0))) === 14.0
    @test_throws StrictViolation @test_strict allocs2(4)
    # The exception names the COMPOSITE, not whichever bundled guarantee tripped first — otherwise
    # `@test_strict` failures would be indistinguishable from `@test_noalloc` ones in a log.
    err = try
        @test_strict allocs2(4)
        nothing
    catch e
        e
    end
    @test err.kind === :strict
end

@testitem "@test_steady_state measures what :noalloc cannot express" begin
    using StrictMode, StrictModeTest

    # A pool that grows to a high-water mark: the growth path exists forever, so an all-paths proof
    # must report it. The property the code really has is about the call sequence.
    mutable struct Pool
        buf::Vector{Float64}
    end
    pool = Pool(Float64[])
    function use_pool!(p::Pool, n::Int)
        length(p.buf) < n && (p.buf = Vector{Float64}(undef, n))
        @inbounds for i in 1:n
            p.buf[i] = i
        end
        return n
    end

    @test_throws StrictMode.StrictViolation (@test_noalloc use_pool!(pool, 8))
    @test (@test_steady_state use_pool!(pool, 8)) == 8          # warmed, then zero
    @test (@test_steady_state use_pool!(pool, 8) fresh_task = true) == 8   # any caller

    # A per-task initializer is alloc-free only for the task that paid. Measuring on a fresh task
    # asks the question a caller means, and is what tells "bounded" from "once per task".
    taskws = Base.OncePerTask{Vector{Float64}}(() -> zeros(64))
    touch_ws() = length(taskws())
    @test (@test_steady_state touch_ws()) == 64                  # warmed on this task
    @test_throws StrictMode.StrictViolation (@test_steady_state touch_ws() fresh_task = true)

    # Something that allocates every single call fails however long it is warmed.
    always(n::Int) = length(collect(1:n))
    @test_throws StrictMode.StrictViolation (@test_steady_state always(4) warmups = 5)

    # Bad knobs are rejected rather than silently meaning something else.
    @test_throws ArgumentError (@test_steady_state use_pool!(pool, 8) warmups = 0)
    @test_throws ArgumentError (@test_steady_state use_pool!(pool, 8) repeats = 0)
end
