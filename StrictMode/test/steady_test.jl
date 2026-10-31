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

@testitem "a process-wide figure is checked against a control before it is believed" begin
    using StrictMode

    # `@allocated` counts allocation for the whole process, so a positive figure may belong to a
    # neighbor. The verdict is a function of the call's figure and the control's, so it is pinned
    # here directly rather than through a race with another task.
    mk(bytes, noise) = StrictMode.SteadyStateReport("f()", bytes, noise, 2, 1, false, 8)

    @test StrictMode.steady(mk(0, 0))
    @test !StrictMode.inconclusive(mk(0, 0))

    # Positive, and the control recorded nothing: the figure is this call's own.
    @test !StrictMode.steady(mk(128, 0))
    @test !StrictMode.inconclusive(mk(128, 0))
    @test occursin("NOT steady", sprint(show, mk(128, 0)))

    # Positive, and the control recorded allocation too: nothing is attributable.
    @test !StrictMode.steady(mk(128, 4096))
    @test StrictMode.inconclusive(mk(128, 4096))
    @test occursin("INCONCLUSIVE", sprint(show, mk(128, 4096)))
    @test occursin("control window", sprint(show, mk(128, 4096)))
    @test occursin("whole process", sprint(show, mk(128, 4096)))

    # Another task's allocation can only ADD to the figure, so a zero stands on its own and no
    # control is measured for one.
    @test StrictMode.steady(mk(0, 4096))

    # The control window must allocate nothing itself, or the harness creates what it measures.
    StrictMode._spin(UInt64(1_000))
    @test iszero(@allocated StrictMode._spin(UInt64(50_000)))
    @test iszero(StrictMode._control_bytes(UInt64(50_000), 2))

    # …and the same three rules reached through a real measurement: a clean call is steady with no
    # control taken, an allocating one carries a figure of its own.
    buf = Ref(Float64[])
    warmed(n) = (length(buf[]) < n && (buf[] = Vector{Float64}(undef, n)); length(buf[]))
    r = steady_state_report(warmed, 32; repeats = 3)
    @test StrictMode.steady(r) && iszero(r.noise)
    bad = steady_state_report(n -> sum(Vector{Float64}(undef, n)), 4)
    @test !StrictMode.steady(bad) && bad.bytes > 0
end
