# The MEASURED allocation gate and the entry-point report. Both exist because a proof of
# `f(args...)` covers one entry point, and a hand-written `@allocated` at a module-global call site
# measures the call site rather than the call.

@testitem "@test_allocated_zero is not fooled by a non-const global call site" begin
    using StrictMode, StrictModeTest
    include(joinpath(@__DIR__, "allocated_fixtures.jl"))

    x = rand(64)
    y = rand(64)
    # `P` is deliberately not `const`, which is what every binding inside a testitem is. The call
    # through it is dispatched at run time and boxes its keywords, so a plain `@allocated` here
    # reports bytes the same call does not allocate.
    P = AllocFixtures.AllocProbe
    P.kernel(x, y; a = 2.0, b = 3.0)
    @test @allocated(P.kernel(x, y; a = 2.0, b = 3.0)) > 0

    # The gate hands the callee and the arguments to the measured window as arguments, so the same
    # source line measures zero.
    v = @test_allocated_zero P.kernel(x, y; a = 2.0, b = 3.0)
    @test v ≈ AllocFixtures.AllocProbe.kernel(x, y; a = 2.0, b = 3.0)

    # Positional form, and the call's value comes back.
    @test (@test_allocated_zero P.kernel(x, y)) ≈ AllocFixtures.AllocProbe.kernel(x, y)

    # …and it is not vacuous: a call that really allocates still fails.
    @test_throws StrictViolation @test_allocated_zero AllocFixtures.AllocProbe.grow(16)
end

@testitem "allocated_bytes measures the call, and a clean zero needs no control" begin
    using StrictMode
    include(joinpath(@__DIR__, "allocated_fixtures.jl"))

    x = rand(32)
    y = rand(32)
    r = StrictMode.allocated_bytes(AllocFixtures.AllocProbe.kernel, (x, y), (a = 2.0, b = 1.0))
    @test iszero(r.bytes)
    # A zero cannot have been produced by a neighbor's allocation, which can only add, so no
    # control window is run for it.
    @test iszero(r.noise)
    @test !StrictMode.inconclusive(r)
    @test occursin("kernel", r.target)
    @test occursin("a::Float64", r.target)

    bad = StrictMode.allocated_bytes(AllocFixtures.AllocProbe.grow, (16,))
    @test bad.bytes > 0
    @test occursin("byte", sprint(show, bad))

    @test_throws ArgumentError StrictMode.allocated_bytes(
        AllocFixtures.AllocProbe.grow, (16,); windows = 0
    )
end

@testitem "alloc_entry_report names the keyword entry a positional proof does not cover" begin
    using StrictMode, StrictModeTest
    include(joinpath(@__DIR__, "allocated_fixtures.jl"))

    r = StrictModeTest.alloc_entry_report(AllocFixtures.AllocProbe.kernel)
    @test length(r.entries) == 2

    pos = only(filter(e -> e.kind === :positional, r.entries))
    kw = only(filter(e -> e.kind === :keyword, r.entries))
    # The positional entry is provable, which is exactly why the keyword one going unmentioned is
    # the defect: the suite reads as covered.
    @test pos.status === :pass
    @test kw.status === :unproven
    @test occursin("keyword", kw.reason)
    @test occursin("unproven", sprint(show, r))
end

@testitem "the measured window charges the call nothing for how it was passed" begin
    using StrictMode, StrictModeTest

    # A function-valued argument, a type-valued argument and a callable struct are concrete inside
    # the window. Each of these calls allocates nothing, and a window that only forwards its
    # arguments reads a boxed return value for them.
    x = rand(64)
    for (f, args) in (
            (sum, (abs2, x)), (maximum, (abs, x)), (mapreduce, (abs2, +, x)),
            (count, (>(0.5), x)), (convert, (Float64, 1)), (Float64, (1,)),
        )
        @test iszero(StrictMode.allocated_bytes(f, args).bytes)
    end
    @test iszero(StrictMode.allocated_bytes(sum, (abs2, x), (init = 0.0,)).bytes)
    @test (@test_allocated_zero sum(abs2, x)) ≈ sum(abs2, x)
    @test (@test_allocated_zero sum(abs2, x; init = 0.0)) ≈ sum(abs2, x)

    # An allocation whose result nothing uses is still counted.
    @test StrictMode.allocated_bytes(Vector{Float64}, (undef, 4)).bytes > 0
    @test occursin("Type{Float64}", StrictMode.allocated_bytes(convert, (Float64, 1)).target)
end

@testitem "an allocation on only some calls fails the measured gate" begin
    using StrictMode, StrictModeTest
    include(joinpath(@__DIR__, "allocated_fixtures.jl"))

    # One call in three allocates, so with three windows exactly one of them sees it. The figure
    # kept is the worst, which is what reports it.
    calls = Ref(0)
    r = StrictMode.allocated_bytes(AllocFixtures.AllocProbe.sometimes!, (calls,))
    @test r.bytes > 0
    @test_throws "worst of 3 window(s)" @test_allocated_zero AllocFixtures.AllocProbe.sometimes!(calls)

    # Growth that is amortized over calls is allocation too.
    v = Float64[]
    @test_throws StrictViolation @test_allocated_zero push!(v, 1.0) windows = 64

    # The call runs `warmups + windows + 1` times, and the last value is returned.
    n = Ref(0)
    count!(r) = (r[] += 1)
    @test (@test_allocated_zero count!(n) warmups = 2 windows = 3) == 6
    @test n[] == 6
end

@testitem "@test_allocated_zero rejects a call it cannot bind, by name" begin
    using StrictMode, StrictModeTest
    add2(a, b) = a + b
    t = (1.0, 2.0)
    @test_throws "splatted argument" @macroexpand @test_allocated_zero add2(t...)
    @test_throws "expect a call" @macroexpand @test_allocated_zero t[1]
end

@testitem "alloc_entry_report on a type and on a callable lists only their own entry points" begin
    using StrictMode, StrictModeTest
    include(joinpath(@__DIR__, "allocated_fixtures.jl"))
    S = AllocFixtures.AllocProbe.Scale

    # `typeof(S)` is `DataType`, which matches the keyword constructor of every type loaded.
    rt = StrictModeTest.alloc_entry_report(S)
    @test occursin("Scale", rt.target)
    @test all(e -> e.kind === :positional, rt.entries)
    @test length(rt.entries) == length(methods(S))

    rc = StrictModeTest.alloc_entry_report(S(2.0))
    @test [e.kind for e in rc.entries] == [:positional, :keyword]
    @test only(filter(e -> e.kind === :keyword, rc.entries)).status === :unproven
    @test only(filter(e -> e.kind === :positional, rc.entries)).status === :pass
end
