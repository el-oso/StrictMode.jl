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

end # module
