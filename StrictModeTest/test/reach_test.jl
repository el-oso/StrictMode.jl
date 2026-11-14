# The gating forms of the reach checks: a target that is absent fails whether or not the graph was
# read in full, and two entries pass only when both graphs were.

@testmodule ReachGate begin
    module Routes
    @noinline serial(x) = sum(x)
    @noinline threaded(x) = (t = Threads.@spawn sum(x); fetch(t))
    @inline core(x; workers::Int = 1) = workers > 1 ? threaded(x) : serial(x)
    native(x) = core(x; workers = length(x) > 100 ? Threads.nthreads() : 1)
    cabi(x) = core(x)
    cabi2(x) = core(x; workers = 1)
    @noinline hidden(x) = x + 1
    viaref(r::Base.RefValue{Any}, x) = r[](x)
    leaf(x) = x
    end
end

@testitem "@test_reaches fails on an absent target, read in full or not" setup = [ReachGate] begin
    using StrictMode, StrictModeTest
    R = ReachGate.Routes
    x = rand(8)

    @test (@test_reaches R.native(x) R.threaded) == sum(x)
    @test (@test_reaches R.cabi(x) R.serial) == sum(x)
    @test_throws "is not among" @test_reaches R.cabi(x) R.threaded
    # `@assert_reaches` warns here; the gate does not pass what it could not show.
    r = Ref{Any}(R.hidden)
    @test_throws "unknown callee" @test_reaches R.viaref(r, 1) R.hidden
end

@testitem "test_route_parity passes only two graphs read in full that agree" setup = [ReachGate] begin
    using StrictMode, StrictModeTest
    R = ReachGate.Routes
    V = (Vector{Float64},)

    @test test_route_parity(R.cabi => V, R.cabi2 => V; mod = R) isa RouteParity
    @test_throws "only `native(Vector{Float64})` reaches" test_route_parity(R.native => V, R.cabi => V; mod = R)
    @test_throws "not shown to agree" test_route_parity(
        R.viaref => (Base.RefValue{Any}, Int), R.leaf => (Int,); mod = R
    )
end
