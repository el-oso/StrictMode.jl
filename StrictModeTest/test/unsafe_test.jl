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
