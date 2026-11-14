# A module rather than testitem-local definitions, so `kernel`'s keyword method is a real
# `Core.kwcall` entry point that `alloc_entry_report` can enumerate.
module AllocFixtures
module AllocProbe
function kernel(x::Vector{Float64}, y::Vector{Float64}; a = 1.0, b = 0.0)
    s = 0.0
    for i in eachindex(x, y)
        s += a * x[i] + b * y[i]
    end
    return s
end
grow(n::Int) = zeros(n)

# Allocates on every third call and on no other.
function sometimes!(calls::Base.RefValue{Int})
    calls[] += 1
    iszero(calls[] % 3) && Base.donotdelete(zeros(8))
    return calls[]
end

struct Scale
    k::Float64
end
(s::Scale)(x::Float64; shift = 0.0) = s.k * x + shift
end
end
