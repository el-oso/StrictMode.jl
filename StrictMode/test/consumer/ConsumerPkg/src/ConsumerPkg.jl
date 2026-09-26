# A miniature of the layout the tier split exists to serve: `StrictMode` in this package's own
# Project.toml, `@strict_function` in its `src/`, and `StrictModeTest` only in `test/`.
#
# `leaky`'s allocation escapes into a sink, so it is a REAL allocation on every Julia version —
# a non-escaping one would be elided and this fixture would stop exhibiting the shape it tests.
module ConsumerPkg

using StrictMode

const SINK = Ref{Any}(nothing)

@strict_function clean(x::Float64) = 2x + 1.0

@strict_function function leaky(n::Int)
    v = Vector{Float64}(undef, n)
    SINK[] = v
    return length(v)
end

# An embedded CALL-SITE macro, for the shipping build (`ship/`, checks off) to reach. Deliberately
# NOT called from `trim_entry.jl`: `--trim` verifies only reachable code, and with checks ENABLED the
# expansion reaches the IR scan, which uses reflection the verifier rightly rejects (measured: 248
# errors). The two builds together pin both halves — armed checks load and declare cleanly, and a
# disabled build leaves nothing of the macro behind.
dot3(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]

guarded(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = @strict dot3(a, b)

end # module
