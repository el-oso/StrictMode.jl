@testitem "@test_no_gc_pause passes an uninterrupted window and returns the call's value" begin
    using StrictMode, StrictModeTest

    counter = Ref(0)
    bump!() = (counter[] += 1; counter[])
    val = @test_no_gc_pause bump!() samples = 50
    @test val == counter[]                       # the macro returns the call's value
    @test counter[] == 50 + 2 + 1                # samples + warmups + the returned call
end

@testitem "@test_no_gc_pause fails when a collection lands in the window" begin
    using StrictMode, StrictModeTest

    # `max_collections = 0` is the default because that is what the name asserts. A call that allocates
    # heavily triggers its own collections, so this needs no second thread.
    hungry() = sum(rand(100_000))
    @test_throws StrictMode.StrictViolation @test_no_gc_pause hungry() samples = 300
    @test_throws "collection(s) ran during" @test_no_gc_pause hungry() samples = 300

    # The verdict alone cannot be acted on, so the message carries the distribution and names the
    # mechanism — a pause may come from a thread this call never reaches.
    msg = try
        @test_no_gc_pause hungry() samples = 300
        ""
    catch e
        sprint(showerror, e)
    end
    @test occursin("median", msg) && occursin("q99", msg)
    @test occursin("safepoint", msg)

    # …and a process known to be doing other work can say so instead of failing.
    @test (@test_no_gc_pause hungry() samples = 300 max_collections = 100_000) isa Any
end

@testitem "@test_no_gc_pause gates a latency budget only when one is given" begin
    using StrictMode, StrictModeTest

    clean_kernel() = (acc = 0.0; for i in 1:5000; acc += sqrt(i); end; acc)

    # No budget: only the collection count is gated, which is the half that does not depend on the
    # machine. A wall-clock threshold is stated per machine or not at all.
    @test (@test_no_gc_pause clean_kernel() samples = 100) isa Float64

    # A budget no call can meet fails, and names the budget it missed.
    @test_throws StrictMode.StrictViolation @test_no_gc_pause clean_kernel() samples = 100 max_q99_ms = 1.0e-9
    @test_throws "against a budget of" @test_no_gc_pause clean_kernel() samples = 100 max_q99_ms = 1.0e-9

    # A generous one passes.
    @test (@test_no_gc_pause clean_kernel() samples = 100 max_q99_ms = 1000.0) isa Float64
end

@testitem "@test_no_gc_pause rejects a budget it cannot honor" begin
    using StrictMode, StrictModeTest

    noop() = nothing
    @test_throws "max_collections must be at least 0" @test_no_gc_pause noop() samples = 10 max_collections = -1
    @test_throws LoadError @eval @test_no_gc_pause
end
