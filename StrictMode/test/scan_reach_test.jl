@testitem "the scan follows the package's own helpers past the Base depth limit" begin
    using StrictMode
    @noinline h6(x) = (v = Float64[]; push!(v, x); v)
    @noinline h5(x) = h6(x)
    @noinline h4(x) = h5(x)
    @noinline h3(x) = h4(x)
    @noinline h2(x) = h3(x)
    @noinline h1(x) = h2(x)
    top(x) = h1(x)
    @test StrictMode._alloc_signals(top, (Float64,)).alloc
    f = only(StrictMode.findings(top, (Float64,); guarantees = (:noalloc,)))
    @test StrictMode._failed(f)
    @test f.code === :SM0002
end

@testitem "a scan that did not read the whole call tree never passes" begin
    using StrictMode
    @noinline c4(x) = x + 1.0
    @noinline c3(x) = c4(x) * 2.0
    @noinline c2(x) = c3(x) - 1.0
    @noinline c1(x) = c2(x) / 3.0
    top(x) = c1(x)

    StrictMode.clear_cache!()
    for g in (:noalloc, :noboxing)
        @test !StrictMode._failed(only(StrictMode.findings(top, (Float64,); guarantees = (g,))))
    end

    old = StrictMode._SCAN_BODY_BUDGET[]
    try
        StrictMode._SCAN_BODY_BUDGET[] = 2
        StrictMode.clear_cache!()
        for g in (:noalloc, :noboxing)
            f = only(StrictMode.findings(top, (Float64,); guarantees = (g,)))
            @test StrictMode._failed(f)
            @test f.code === :SM0207
            @test occursin("not established", f.reason)
        end
        @test occursin("scan could not read", StrictMode.explain(:SM0207))
    finally
        StrictMode._SCAN_BODY_BUDGET[] = old
        StrictMode.clear_cache!()
    end
end

@testitem "a Ref handed to a ccall through unsafe_convert stays on the stack" begin
    using StrictMode
    store!(x::Float64, p::Ptr{Float64}) = (unsafe_store!(p, x); nothing)
    const FP = Ref{Ptr{Cvoid}}(C_NULL)
    FP[] = @cfunction(store!, Cvoid, (Float64, Ptr{Float64}))
    const SINK = Ref{Ptr{Float64}}(C_NULL)

    function through_pointer(x::Float64)
        o = Ref(0.0)
        p = Base.unsafe_convert(Ptr{Float64}, o)
        GC.@preserve o ccall(FP[], Cvoid, (Float64, Ptr{Float64}), x, p)
        return o[]
    end
    function pointer_escapes(x::Float64)
        o = Ref(x)
        SINK[] = Base.unsafe_convert(Ptr{Float64}, o)
        return o[]
    end

    through_pointer(1.0); pointer_escapes(1.0)
    @test iszero(@allocated through_pointer(2.0))
    @test !StrictMode._alloc_signals(through_pointer, (Float64,)).alloc
    # A pointer kept past the call is a different shape, and the scan still reports the Ref.
    @test StrictMode._alloc_signals(pointer_escapes, (Float64,)).alloc
end
