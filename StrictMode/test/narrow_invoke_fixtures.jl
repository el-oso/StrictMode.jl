# A module whose functions `d` and `c` each have a wider method (`n::Integer`) and a specific one
# (`n::Int`) compiled for the same argument types, the wider one only through `invoke` from `dv`
# and `cv`. `d`'s wider method allocates and its specific one does not; `c` is the other way round.
# Both are exempted from `:noalloc` with `types = exempt_types`, which names the specific method
# for `(Vector{Float64}, Int)` and the wider one for `(Vector{Float64}, Integer)`. `warm!()`
# compiles every row.
narrow_invoke_source(name::AbstractString, exempt_types::AbstractString) = """
module $name
using StrictMode
const A = Vector{Float64}
@noinline d(a::A, n::Integer) = (Base.donotdelete(Any[a, n]); 0.0)
@noinline d(a::A, n::Int) = (a[1] = n; 0.0)
@noinline c(a::A, n::Integer) = (a[1] = n; 0.0)
@noinline c(a::A, n::Int) = (Base.donotdelete(Any[a, n]); 0.0)
dv(a::A, n::Int) = invoke(d, Tuple{A, Integer}, a, n)
cv(a::A, n::Int) = invoke(c, Tuple{A, Integer}, a, n)
@strict_exempt :noalloc types = $exempt_types reason = "narrow" d
@strict_exempt :noalloc types = $exempt_types reason = "narrow" c
function warm!()
    a = [1.0]
    d(a, 1); c(a, 1); dv(a, 1); cv(a, 1)
    return nothing
end
end
"""

function narrow_invoke_module(into::Module, name::AbstractString, exempt_types::AbstractString)
    M = Base.include_string(into, narrow_invoke_source(name, exempt_types), name * ".jl")::Module
    Core.eval(M, :(warm!()))
    return M
end
