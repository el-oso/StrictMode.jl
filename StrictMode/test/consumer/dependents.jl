# Three packages, one depending on the other two, built in a scratch directory and loaded from their
# caches, for the registrations a single package cannot exercise: one made in an `__init__`, one
# of a function or type another package owns, and one of a callable object.
#
#     julia dependents.jl WORKDIR STRICTMODE_DIR
#
# Prints one `name = value` line per fact. `ConsumerPkg/test/runtests.jl` runs it and reads them.
# The packages are generated here, not kept in the repository, so their project files are written
# by Pkg and their `[sources]` paths point at this checkout.
import Pkg

const WORK, STRICTMODE = ARGS[1], ARGS[2]

const OWNER_SRC = raw"""
module RegOwner
using StrictMode

# Registered at top level, so this package already holds a store of each kind when a dependent
# registers something of its.
struct Kept
    p::Ptr{Cvoid}
end
StrictMode.register_scoped!(Kept)
kept_reader(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))
StrictMode.trust_boundary!(kept_reader)
const KEPT_TABLE = Ref{Vector{Float64}}()
@noinline kept_table() = (isassigned(KEPT_TABLE) || (KEPT_TABLE[] = zeros(4)); KEPT_TABLE[])
StrictMode.register_alloc_barrier!(kept_table)

# Left for the dependent to register.
struct Lent
    p::Ptr{Cvoid}
end
struct LentNamed
    p::Ptr{Cvoid}
end
lent_reader(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))
lent_reader_named(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))
@noinline lent_table() = zeros(4)
@noinline lent_table_named() = zeros(4)
end
"""

# A package whose only registrations are in `__init__`, which runs again in every process that
# loads it, and also while a dependent precompiles. It holds no store of its own, and its module
# is closed by then.
const INIT_SRC = raw"""
module RegInit
using StrictMode
struct InitHandle
    p::Ptr{Cvoid}
end
init_reader(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))
const INIT_TABLE = Ref{Vector{Float64}}()
@noinline init_table() = (isassigned(INIT_TABLE) || (INIT_TABLE[] = zeros(4)); INIT_TABLE[])
function __init__()
    StrictMode.register_scoped!(InitHandle)
    StrictMode.trust_boundary!(init_reader)
    StrictMode.register_alloc_barrier!(init_table)
    return nothing
end
end
"""

const DEPENDENT_SRC = raw"""
module RegDependent
using RegOwner, RegInit, StrictMode

attempt(f) = try
    f()
    "registered"
catch err
    sprint(showerror, err)
end

# Another package's type and functions, without naming this package: refused, since RegOwner is
# not the package being written.
const UNNAMED_SCOPED = attempt(() -> StrictMode.register_scoped!(RegOwner.Lent))
const UNNAMED_TRUST = attempt(() -> StrictMode.trust_boundary!(RegOwner.lent_reader))
const UNNAMED_BARRIER = attempt(() -> StrictMode.register_alloc_barrier!(RegOwner.lent_table))

# The same, naming this package: stored here.
StrictMode.register_scoped!(RegOwner.LentNamed; mod = @__MODULE__)
StrictMode.trust_boundary!(RegOwner.lent_reader_named; mod = @__MODULE__)
StrictMode.register_alloc_barrier!(RegOwner.lent_table_named; mod = @__MODULE__)

# A callable object is registered by value, and belongs to the module of its type.
struct Validator
    min::Int
end
(v::Validator)(u::Untrusted{Vector{UInt8}}) = (b = unsafe_trust(u); length(b) >= v.min ? length(b) : 0)
const CALLABLE_TRUST = attempt(() -> StrictMode.trust_boundary!(Validator(3)))
struct Table
    n::Int
end
(t::Table)() = zeros(t.n)
const CALLABLE_BARRIER = attempt(() -> StrictMode.register_alloc_barrier!(Table(4)))
end
"""

const CHECK = raw"""
using StrictMode, RegOwner, RegInit, RegDependent
say(name, value) = println(name, " = ", value)
cached(M) = !isnothing(Base.pkgorigins[Base.PkgId(M)].cachepath)
say("loaded_from_cache", cached(RegOwner) && cached(RegInit) && cached(RegDependent))
barrier(f) = any(g -> g === f, StrictMode._barrier_functions())
say("top_level_own", StrictMode._is_scoped_type(RegOwner.Kept) && StrictMode._is_trust_boundary(RegOwner.kept_reader) && barrier(RegOwner.kept_table))
say("init_scoped", StrictMode._is_scoped_type(RegInit.InitHandle))
say("init_trust", StrictMode._is_trust_boundary(RegInit.init_reader))
say("init_barrier", barrier(RegInit.init_table))
refused(s) = occursin("mod = @__MODULE__", s)
say("unnamed_scoped_refused", refused(RegDependent.UNNAMED_SCOPED) && !StrictMode._is_scoped_type(RegOwner.Lent))
say("unnamed_trust_refused", refused(RegDependent.UNNAMED_TRUST) && !StrictMode._is_trust_boundary(RegOwner.lent_reader))
say("unnamed_barrier_refused", refused(RegDependent.UNNAMED_BARRIER) && !barrier(RegOwner.lent_table))
say("named_scoped", StrictMode._is_scoped_type(RegOwner.LentNamed))
say("named_trust", StrictMode._is_trust_boundary(RegOwner.lent_reader_named))
say("named_barrier", barrier(RegOwner.lent_table_named))
say("callable_trust", RegDependent.CALLABLE_TRUST == "registered" && StrictMode._is_trust_boundary(RegDependent.Validator(3)) && !StrictMode._is_trust_boundary(RegDependent.Validator(4)))
say("callable_barrier", RegDependent.CALLABLE_BARRIER == "registered" && barrier(RegDependent.Table(4)))
"""

mkpath(WORK)
cd(WORK) do
    Pkg.generate("RegOwner"; io = devnull)
    Pkg.generate("RegDependent"; io = devnull)
    Pkg.generate("RegInit"; io = devnull)
    write(joinpath("RegInit", "src", "RegInit.jl"), INIT_SRC)
    write(joinpath("RegOwner", "src", "RegOwner.jl"), OWNER_SRC)
    write(joinpath("RegDependent", "src", "RegDependent.jl"), DEPENDENT_SRC)
    write("check.jl", CHECK)
    specs = [Pkg.PackageSpec(path = p) for p in (STRICTMODE, joinpath(WORK, "RegOwner"), joinpath(WORK, "RegInit"), joinpath(WORK, "RegDependent"))]
    for own in ("RegOwner", "RegInit")
        Pkg.activate(joinpath(WORK, own); io = devnull)
        Pkg.develop(specs[1]; io = devnull)
    end
    Pkg.activate(joinpath(WORK, "RegDependent"); io = devnull)
    Pkg.develop(specs[1:3]; io = devnull)
    Pkg.activate(joinpath(WORK, "env"); io = devnull)
    Pkg.develop(specs; io = devnull)
    # Each package is compiled in a process of its own, as a user's would be. The first run of the
    # check does that and prints nothing to rely on; the second loads both from their caches.
    check = `$(Base.julia_cmd()) --startup-file=no --project=$(joinpath(WORK, "env")) check.jl`
    success(pipeline(check; stdout = devnull, stderr = devnull)) || println("first_load = failed")
    run(check)
end
