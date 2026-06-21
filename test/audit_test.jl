@testitem "audit returns the failure count and emits JSON" begin
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
    n = audit(:registered; format = :json, io = buf)
    @test n ≥ 1                                   # boxy fails (allocates)
    out = String(take!(buf))
    @test occursin("\"status\":\"fail\"", out)
    @test occursin("\"suggestion\":", out)        # agents get an actionable hint
    @test startswith(strip(out), "[")             # valid JSON array
end

@testitem "audit is clean (count 0) for a clean registry" begin
    using StrictMode
    empty!(StrictMode.registered_strict())
    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    StrictMode.register_strict!(clean, (NTuple{3, Float64}, NTuple{3, Float64}))
    @test audit(:registered; format = :jsonlines, io = IOBuffer()) == 0
end
