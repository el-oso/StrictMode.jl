@testitem "steady_state_report measures what :noalloc cannot express" begin
    using StrictMode

    # A pool that grows to a high-water mark: the growth path exists on every path, so an all-paths
    # proof must report it forever. The property the code has is about the call sequence.
    mutable struct WS
        buf::Vector{Float64}
    end
    pool = WS(Float64[])
    grow!(p::WS, n::Int) = (length(p.buf) < n && (p.buf = Vector{Float64}(undef, n)); p.buf)

    # A DRIVER, not the growth function: the shape a consumer actually asserts.
    function driver!(C::Matrix{Float64}, n::Int)
        s = grow!(pool, n)
        for i in 1:n
            s[i] = i
        end
        C[1, 1] = s[n]
        return C
    end
    C = zeros(2, 2)

    r = steady_state_report(driver!, C, 64)
    @test r isa SteadyStateReport
    @test StrictMode.steady(r)
    @test iszero(r.bytes)
    @test occursin("steady", sprint(show, r))

    # It reports rather than raising — that is the whole difference from the gating form.
    always(p::WS, n::Int) = (p.buf = Vector{Float64}(undef, n); length(p.buf))
    bad = steady_state_report(always, pool, 32)
    @test !StrictMode.steady(bad)
    @test bad.bytes > 0
    @test occursin("NOT steady", sprint(show, bad))

    # A per-task initializer is steady for the task that already paid and not for a fresh one,
    # which is what separates "bounded" from "once per task".
    taskws = Base.OncePerTask{Vector{Float64}}(() -> zeros(8))
    touch_ws() = length(taskws())
    @test StrictMode.steady(steady_state_report(touch_ws))
    @test !StrictMode.steady(steady_state_report(touch_ws; fresh_task = true))

    # The knobs are checked rather than silently meaning something else.
    @test_throws ArgumentError steady_state_report(driver!, C, 8; warmups = 0)
    @test_throws ArgumentError steady_state_report(driver!, C, 8; repeats = 0)

    # It takes VALUES and runs the call, so it sits outside the value-free pipeline: no guarantee
    # named `:steady_state` exists, and `findings` cannot be asked for one.
    @test !(:steady_state in StrictMode._GUARANTEES)
end
