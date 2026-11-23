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

# Registrations a verdict depends on, made at top level the way a package makes them. Each is
# stored in this package, so it is still in force when a later process loads the package from its
# cache: held in StrictMode alone it would be gone, like a declaration.
struct Handle
    p::Ptr{Cvoid}
end
StrictMode.register_scoped!(Handle)
const KEPT = Ref{Any}(nothing)
leak_handle(p::Ptr{Cvoid}) = (h = Handle(p); KEPT[] = h; nothing)
use_handle(p::Ptr{Cvoid}) = (h = Handle(p); h.p === C_NULL)

parse_len(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))
StrictMode.trust_boundary!(parse_len)
peek_len(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))    # reads the payload, unregistered

const TABLE = Ref{Vector{Float64}}()
@noinline table() = (isassigned(TABLE) || (TABLE[] = zeros(4)); TABLE[])
StrictMode.register_alloc_barrier!(table)
uses_table() = sum(table())

# A type another package owns: its module is closed while this one precompiles, so the constant
# cannot go there, and the call says so in place of registering for this precompile only. Naming
# this package stores it here.
const FOREIGN_UNNAMED = try
    StrictMode.register_scoped!(Base.Libc.RawFD)
    "registered"
catch err
    sprint(showerror, err)
end
StrictMode.register_scoped!(Base.Filesystem.File; mod = @__MODULE__)

# The same for an allocation barrier that is another package's function.
const FOREIGN_BARRIER_UNNAMED = try
    StrictMode.register_alloc_barrier!(Base.Libc.getpid)
    "registered"
catch err
    sprint(showerror, err)
end
StrictMode.register_alloc_barrier!(Base.Libc.gethostname; mod = @__MODULE__)

# A definition-form exemption, stored here with the signature of the one method it writes. The
# wider method next to it is not exempt.
@strict_exempt cold_plan(n::Int) = collect(1:n)
cold_plan(n::Integer) = collect(1:Int(n))

end # module
