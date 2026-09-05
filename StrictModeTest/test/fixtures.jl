# Shared fixtures. Every assertion that says "the proof flags this" rests on these actually
# exhibiting the defect, so `proofs_test.jl` measures them before anything relies on them.
@testmodule Fixtures begin
    # A `const` sink, so the allocation ESCAPES and neither optimizer can elide it. Without this the
    # fixture measures 0 B and every assertion built on it becomes a tautology.
    const SINK = Ref{Any}(nothing)

    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    allocs(n::Int) = (v = rand(n); SINK[] = v; length(v))

    const T3 = (NTuple{3, Float64}, NTuple{3, Float64})
    const THET = (Tuple{Int, Float64, Float32},)
end
