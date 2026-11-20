# Three packages, one depending on the other two, built in a scratch directory and loaded from their
# caches, for the registrations a single package cannot exercise: one made in an `__init__`, one
# of a function or type another package owns, one of a callable object, and one a package makes of
# its own function when a dependent first calls it. The owner also has an extension and a package
# nested in its directory, which register its types as another package would.
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

# Registered by this package's own code when it is first called. A dependent's precompile
# workload can be the first caller, in a process where this package came from its cache.
struct Lazy
    p::Ptr{Cvoid}
end
lazy_reader(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))
@noinline lazy_table() = zeros(4)
function lazy_setup!()
    StrictMode.register_scoped!(Lazy)
    StrictMode.trust_boundary!(lazy_reader)
    StrictMode.register_alloc_barrier!(lazy_table)
    return nothing
end

# Left for this package's extension and for the package in its `lib/` to register.
struct ExtTop
    p::Ptr{Cvoid}
end
struct ExtLent
    p::Ptr{Cvoid}
end
@noinline ext_lent_table() = zeros(4)
struct SubTop
    p::Ptr{Cvoid}
end
end
"""

const ATTEMPT = raw"""
attempt(f) = try
    f()
    "registered"
catch err
    sprint(showerror, err)
end
"""

# RegOwner's extension, and a package in RegOwner's `lib/`. Both lie in RegOwner's directory and
# both are packages of their own, so registering RegOwner's types without naming themselves is
# refused, from top-level code and from a function of theirs alike.
const EXT_SRC = "module RegOwnerDatesExt\nusing RegOwner, Dates, StrictMode\n" * ATTEMPT * raw"""
const TOP_LEVEL = try
    StrictMode.register_scoped!(RegOwner.ExtTop)
    "registered"
catch err
    sprint(showerror, err)
end
const UNNAMED_SCOPED = attempt(() -> StrictMode.register_scoped!(RegOwner.ExtLent))
@noinline setup() = StrictMode.register_alloc_barrier!(RegOwner.ext_lent_table)
const UNNAMED_BARRIER = attempt(setup)
end
"""

const SUB_SRC = raw"""
module RegSub
using RegOwner, StrictMode
const TOP_LEVEL = try
    StrictMode.register_scoped!(RegOwner.SubTop)
    "registered"
catch err
    sprint(showerror, err)
end
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
lazy_reader(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))
lazy_setup!() = (StrictMode.trust_boundary!(lazy_reader); nothing)
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
# A refused registration registers nothing, in this precompile either.
const UNNAMED_IN_FORCE_HERE = StrictMode._is_scoped_type(RegOwner.Lent) ||
    StrictMode._is_trust_boundary(RegOwner.lent_reader) ||
    any(g -> g === RegOwner.lent_table, StrictMode._barrier_functions())

# RegOwner registering its own, called from here while this package precompiles: in force for
# the process, and no error. The same call from RegInit, which holds no store at all.
const LAZY_OWNER = attempt(RegOwner.lazy_setup!)
const LAZY_INIT = attempt(RegInit.lazy_setup!)

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
# A barrier is matched on the callee's type, so one instance is refused and the type is registered.
const CALLABLE_BARRIER_INSTANCE = attempt(() -> StrictMode.register_alloc_barrier!(Table(4)))
const CALLABLE_BARRIER = attempt(() -> StrictMode.register_alloc_barrier!(Table))
end
"""

const CHECK = raw"""
using StrictMode, RegOwner, RegInit, RegDependent, Dates, RegSub
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
say("unnamed_refused_at_precompile", !RegDependent.UNNAMED_IN_FORCE_HERE)
say("named_scoped", StrictMode._is_scoped_type(RegOwner.LentNamed))
say("named_trust", StrictMode._is_trust_boundary(RegOwner.lent_reader_named))
say("named_barrier", barrier(RegOwner.lent_table_named))
say("callable_trust", RegDependent.CALLABLE_TRUST == "registered" && StrictMode._is_trust_boundary(RegDependent.Validator(3)) && !StrictMode._is_trust_boundary(RegDependent.Validator(4)))
say("callable_barrier", RegDependent.CALLABLE_BARRIER == "registered" && barrier(RegDependent.Table) && occursin("register_alloc_barrier!(Table)", RegDependent.CALLABLE_BARRIER_INSTANCE) && !barrier(RegDependent.Table(4)))
say("lazy_owner_no_error", RegDependent.LAZY_OWNER == "registered" && RegDependent.LAZY_INIT == "registered")
# Made in the dependent's precompile, so not in this process until the owner's code runs here.
say("lazy_not_stored", !StrictMode._is_trust_boundary(RegOwner.lazy_reader) && !StrictMode._is_scoped_type(RegOwner.Lazy) && !barrier(RegOwner.lazy_table))
RegOwner.lazy_setup!()
say("lazy_in_session", StrictMode._is_trust_boundary(RegOwner.lazy_reader) && StrictMode._is_scoped_type(RegOwner.Lazy) && barrier(RegOwner.lazy_table))
ext = Base.get_extension(RegOwner, :RegOwnerDatesExt)
say("nested_ext_refused", !isnothing(ext) && refused(ext.TOP_LEVEL) && refused(ext.UNNAMED_SCOPED) && refused(ext.UNNAMED_BARRIER) && !StrictMode._is_scoped_type(RegOwner.ExtTop) && !StrictMode._is_scoped_type(RegOwner.ExtLent) && !barrier(RegOwner.ext_lent_table))
say("nested_sub_refused", refused(RegSub.TOP_LEVEL) && !StrictMode._is_scoped_type(RegOwner.SubTop))
"""

mkpath(WORK)
cd(WORK) do
    Pkg.generate("RegOwner"; io = devnull)
    Pkg.generate("RegDependent"; io = devnull)
    Pkg.generate("RegInit"; io = devnull)
    write(joinpath("RegInit", "src", "RegInit.jl"), INIT_SRC)
    write(joinpath("RegOwner", "src", "RegOwner.jl"), OWNER_SRC)
    write(joinpath("RegDependent", "src", "RegDependent.jl"), DEPENDENT_SRC)
    mkpath(joinpath("RegOwner", "ext"))
    write(joinpath("RegOwner", "ext", "RegOwnerDatesExt.jl"), EXT_SRC)
    cd(() -> Pkg.generate("RegSub"; io = devnull), mkpath(joinpath("RegOwner", "lib")))
    sub = joinpath(WORK, "RegOwner", "lib", "RegSub")
    write(joinpath(sub, "src", "RegSub.jl"), SUB_SRC)
    write("check.jl", CHECK)
    specs = [Pkg.PackageSpec(path = p) for p in (STRICTMODE, joinpath(WORK, "RegOwner"), joinpath(WORK, "RegInit"), joinpath(WORK, "RegDependent"))]
    for own in ("RegOwner", "RegInit")
        Pkg.activate(joinpath(WORK, own); io = devnull)
        Pkg.develop(specs[1]; io = devnull)
    end
    owner = joinpath(WORK, "RegOwner", "Project.toml")
    dates = string(Base.identify_package("Dates").uuid)
    write(owner, read(owner, String) * "\n[weakdeps]\nDates = \"$dates\"\n\n[extensions]\nRegOwnerDatesExt = \"Dates\"\n")
    Pkg.activate(joinpath(WORK, "RegOwner"); io = devnull)
    Pkg.resolve(; io = devnull)
    Pkg.activate(sub; io = devnull)
    Pkg.develop(specs[1:2]; io = devnull)
    Pkg.activate(joinpath(WORK, "RegDependent"); io = devnull)
    Pkg.develop(specs[1:3]; io = devnull)
    Pkg.activate(joinpath(WORK, "env"); io = devnull)
    Pkg.develop([specs; Pkg.PackageSpec(path = sub)]; io = devnull)
    Pkg.add("Dates"; io = devnull)
    # Each package is compiled in a process of its own, as a user's would be. The first run of the
    # check does that and prints nothing to rely on; the second loads both from their caches.
    check = `$(Base.julia_cmd()) --startup-file=no --project=$(joinpath(WORK, "env")) check.jl`
    success(pipeline(check; stdout = devnull, stderr = devnull)) || println("first_load = failed")
    run(check)
end
