@testitem "test_no_unsafe gates the fence and names what to allow" begin
    using StrictMode, StrictModeTest

    module GateKernels
    raw(x::Int) = ccall(:abs, Cint, (Cint,), x)
    clean(v::Vector{Float64}) = sum(v)
    end

    @test_throws StrictMode.StrictViolation test_no_unsafe(GateKernels)
    @test_throws "leaves Julia's safety guarantees" test_no_unsafe(GateKernels)
    @test_throws "`ccall`" test_no_unsafe(GateKernels)

    # A reviewed escape is recorded where the policy is written, not tolerated silently.
    @test isempty(test_no_unsafe(GateKernels; allow = (:ccall,)))
    @test isempty(test_no_unsafe(GateKernels; only = r"^clean$"))

    module GateClean
    f(v::Vector{Float64}) = sum(v)
    end
    @test isempty(test_no_unsafe(GateClean))
end

@testitem "test_no_unsafe holds an unsafe function however it is spelled" begin
    using StrictMode, StrictModeTest

    module GateSpellings
    mapped(ps) = map(unsafe_load, ps)
    kwcall(p) = unsafe_wrap(Array, p, 2; own = false)
    freed(p) = Libc.free(p)
    made(x::UInt) = Ptr{Float64}(x)
    clean(v) = map(abs, v)
    end

    @test_throws "`unsafe_load`" test_no_unsafe(GateSpellings; only = [:mapped])
    @test_throws "`unsafe_wrap`" test_no_unsafe(GateSpellings; only = [:kwcall])
    @test_throws "`free`" test_no_unsafe(GateSpellings; only = [:freed])
    @test_throws "`Ptr`" test_no_unsafe(GateSpellings; only = [:made])
    @test isempty(test_no_unsafe(GateSpellings; only = [:clean]))
    @test isempty(test_no_unsafe(GateSpellings; allow = (:unsafe_load, :unsafe_wrap, :free, :Ptr)))

    # An `allow` entry that names no construct excuses nothing, and says so.
    @test_throws "`allow` names `unsafeload`" test_no_unsafe(GateSpellings; allow = (:unsafeload,))
    @test_throws "Accepted: :ccall, :cfunction, :inbounds, :Ptr" test_no_unsafe(GateSpellings; allow = (:unsafeload,))
end
