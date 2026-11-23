# A module whose every function has two methods compiled for the same argument types: the
# specific one (`n::Int`), by dispatch, and the wider one (`n::Integer`), only through `invoke`.
# For each guarantee `g` there are two functions, named after it:
#
#   `<g>_d`: the wider method breaks `g`, the specific one keeps it;
#   `<g>_c`: the wider method keeps `g`, the specific one breaks it.
#
# `warm!()` compiles all of them. A sweep that reads each specialization as the method that
# compiled it fails the wider `<g>_d` and the specific `<g>_c`, and passes the other two.
module SweepInvoke
using StrictMode

const SINK = Ref{Any}(nothing)
const G = Ref{Any}(1)
const U = Untrusted{Vector{UInt8}}
const DICT = Dict{Symbol, Vector{Float64}}
const V4 = NTuple{4, VecElement{Float64}}
mutable struct Handle
    x::Int
end

# Vector work that is vector work whatever the bounds-check and coverage settings.
@inline vadd(v::V4) = Base.llvmcall(
    """
    %r = fadd <4 x double> %0, %0
    ret <4 x double> %r
    """, V4, Tuple{V4}, v
)
# A scalar floating-point loop that cannot vectorize: each step depends on the last.
const serial = quote
    s = a
    for _ in 1:n
        s = s * 1.0000001 + 1.0
    end
    s
end

# A loop with `nacc` independent SIMD accumulators. Far past the vector register count the
# register allocator has to spill inside the loop; four never do.
function accum(nacc::Int)
    accs = [Symbol(:acc, k) for k in 1:nacc]
    return quote
        $([:($(accs[k]) = 0.0) for k in 1:nacc]...)
        @inbounds @simd for i in eachindex(a)
            $([:($(accs[k]) += a[i] * a[i] + $(Float64(k))) for k in 1:nacc]...)
        end
        +($(accs...)) + n
    end
end

# (argument types, dirty body, clean body), each body a function of the arguments `a` and `n`.
const BODIES = Dict(
    :typestable => (:(Int), :(G[] + a), :(a + 1)),
    :noalloc => (:(Vector{Float64}), :((Base.donotdelete(Any[a, n]); 0.0)), :((a[1] = n; 0.0))),
    :noboxing => (:(Int), :(G[] + n), :(a + n)),
    :owned => (:(DICT), :(a[:k]), :(Float64[])),
    :inlined => (
        :(Float64), :(
            begin
                @noinline
                a + 1.0
            end
        ), :(a + 1.0),
    ),
    :vectorized => (:(Float64), :(a + n), :(vadd(V4((a, a + 1.0, a + 2.0, a + n))))),
    :no_scalar_loops => (:(Float64), serial, :(a + 1.0)),
    :no_spill => (:(Vector{Float64}), accum(80), accum(4)),
    :trim_compatible => (:(Int), :(G[] + n), :(a + n)),
    :trusted => (:(U), :(length(unsafe_trust(a))), :(0)),
    :noescape => (:(Int), :((SINK[] = Handle(a); 0)), :((h = Handle(a); h.x + 1))),
    :no_threadid_state => (:(Vector{Int}), :((i = Threads.threadid(); yield(); a[i] += n; nothing)), :(nothing)),
    :concurrency_safe => (:(Vector{Int}), :((a[1] = n; nothing)), :(nothing)),
)

for (g, (A, dirty, clean)) in BODIES
    d, c = Symbol(g, :_d), Symbol(g, :_c)
    # `:inlined` asks whether the call inlines, so its methods carry no annotation.
    ann = g === :inlined ? identity : (ex -> :(@noinline $ex))
    @eval begin
        $(ann(:($d(a::$A, n::Integer) = $dirty)))
        $(ann(:($d(a::$A, n::Int) = $clean)))
        $(ann(:($c(a::$A, n::Integer) = $clean)))
        $(ann(:($c(a::$A, n::Int) = $dirty)))
        $(Symbol(g, :_dv))(a::$A, n::Int) = invoke($d, Tuple{$A, Integer}, a, n)
        $(Symbol(g, :_cv))(a::$A, n::Int) = invoke($c, Tuple{$A, Integer}, a, n)
        # One method each, so dispatch reads the body: what each verdict is in this configuration.
        $(ann(:($(Symbol(g, :_dp))(a::$A, n::Int) = $dirty)))
        $(ann(:($(Symbol(g, :_cp))(a::$A, n::Int) = $clean)))
    end
end

# The argument each function is warmed with.
function value(g::Symbol)
    g === :typestable && return 1
    g in (:noalloc, :no_spill) && return [1.0]
    g === :owned && return DICT(:k => [1.0])
    g in (:inlined, :no_scalar_loops, :vectorized) && return 1.0
    g === :trusted && return Untrusted(UInt8[1, 2])
    g in (:no_threadid_state, :concurrency_safe) && return zeros(Int, 256)
    return 1
end

argtypes(g::Symbol) = (Core.eval(SweepInvoke, BODIES[g][1]), Int)

function warm!()
    for g in keys(BODIES)
        a = value(g)
        for s in (:_d, :_c, :_dv, :_cv, :_dp, :_cp)
            getfield(SweepInvoke, Symbol(g, s))(a, 1)
        end
    end
    return nothing
end

# The functions a sweep of guarantee `g` covers.
names_for(g::Symbol) = [Symbol(g, :_d), Symbol(g, :_c)]

end
