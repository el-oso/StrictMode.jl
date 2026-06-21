@testitem "audit returns the findings (consistent) and emits JSON" begin
    using StrictMode
    empty!(StrictMode.registered_strict())
    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    boxy(t::Tuple{Int, Float64, Float32}) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    StrictMode.register_strict!(clean, (NTuple{3, Float64}, NTuple{3, Float64}))
    StrictMode.register_strict!(boxy, (Tuple{Int, Float64, Float32},))

    buf = IOBuffer()
    fs = audit(:registered; format = :json, io = buf)
    @test fs isa Vector{StrictFinding}            # same return type as the other drivers
    @test nfailures(fs) ≥ 1                        # boxy fails (allocates)
    out = String(take!(buf))
    @test occursin("\"status\":\"fail\"", out)
    @test occursin("\"suggestion\":", out)        # agents get an actionable hint
    @test startswith(strip(out), "[")             # valid JSON array
end

@testitem "audit is clean (0 failures) for a clean registry" begin
    using StrictMode
    empty!(StrictMode.registered_strict())
    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    StrictMode.register_strict!(clean, (NTuple{3, Float64}, NTuple{3, Float64}))
    @test nfailures(audit(:registered; format = :jsonlines, io = IOBuffer())) == 0
end

@testitem "check_compiled only/exempt filters scope the sweep" begin
    using StrictMode
    module Mixed
    hot(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    cold(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )   # boxes by design (a "plan-time" helper)
    end
    Mixed.hot((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
    Mixed.cold((1, 2.0, 3.0f0))

    # exempt the cold helper → no failures from it
    fs = check_compiled(Mixed; guarantees = (:noalloc, :noboxing), exempt = [:cold])
    @test !any(f -> f.func == "cold", fs)
    # only the hot kernel
    only_hot = check_compiled(Mixed; guarantees = (:noalloc,), only = [:hot])
    @test all(f -> f.func == "hot", only_hot)
end
