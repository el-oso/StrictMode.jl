# Runs in ConsumerPkg's TEST environment, where StrictModeTest is available. The `@strict_function`
# declarations in `src/` were registered at ConsumerPkg's own precompile; this re-proves them.
using ConsumerPkg, StrictMode, StrictModeTest, Test

@testset "the consumer layout, end to end" begin
    @test StrictMode.checks_enabled()
    @test StrictMode.proofs_loaded()

    # The fixture must still allocate, or the gate below would pass for the wrong reason.
    ConsumerPkg.leaky(4)
    @test @allocated(ConsumerPkg.leaky(4)) > 0

    # `@strict_function` declares at the DEFINING package's precompile, and the declaration is
    # stored in ConsumerPkg itself — which is why it is still here after this process loaded
    # ConsumerPkg from its pkgimage. Stored in StrictMode instead, it would be gone: StrictMode is
    # loaded from its own cache by then, so the mutation does not survive.
    @test isempty(StrictMode.registered_strict())      # nothing registered in THIS session
    d = StrictMode.declarations()
    @test count(k -> StrictMode._mod_sym(k[1]) === :ConsumerPkg, keys(d)) == 2

    # The proof tier re-checks those declarations and DOES fail, where the precompile-time scan
    # only warned.
    @test_throws StrictViolation test_registered(; modules = [ConsumerPkg])

    # And the coverage gate counts them as declared: a package that annotates its `src/` must not
    # be told its own methods are undeclared.
    ConsumerPkg.clean(1.0)
    cov = audit(ConsumerPkg; require = :all)
    undeclared = Set(
        f.func * f.signature for f in cov
            if f.guarantee === :coverage && StrictMode._failed(f)
    )
    @test !("clean(Float64)" in undeclared)
    @test !("leaky(Int64)" in undeclared)

    # The path that does not depend on the registry surviving: name the signatures directly.
    @test_throws StrictViolation test_signatures(
        [(ConsumerPkg.leaky, (Int,))]; guarantees = (:noalloc,)
    )
    @test test_signatures([(ConsumerPkg.clean, (Float64,))]) isa Vector{StrictMode.StrictFinding}
end

@testset "registrations made in src/ are in force after a cached load" begin
    # ConsumerPkg came from its cache, and nothing was registered in this session: what the
    # checks below find was stored in ConsumerPkg at its own precompile.
    @test !isnothing(Base.pkgorigins[Base.PkgId(ConsumerPkg)].cachepath)
    @test isempty(StrictMode._TRUST_BOUNDARIES)
    @test isempty(StrictMode._SCOPED_TYPES)

    # A trust boundary: the registered reader passes, the unregistered one still fails.
    sig = (Untrusted{Vector{UInt8}},)
    @test only(findings(ConsumerPkg.parse_len, sig; guarantees = (:trusted,))).status === :pass
    @test StrictMode._failed(only(findings(ConsumerPkg.peek_len, sig; guarantees = (:trusted,))))

    # A scoped type: with nothing registered `:noescape` passes every signature unchecked.
    leak = only(findings(ConsumerPkg.leak_handle, (Ptr{Cvoid},); guarantees = (:noescape,)))
    @test leak.status !== :pass
    @test occursin("Handle", leak.reason)
    @test only(findings(ConsumerPkg.use_handle, (Ptr{Cvoid},); guarantees = (:noescape,))).status === :pass

    # An allocation barrier.
    @test only(findings(ConsumerPkg.uses_table, (); guarantees = (:noalloc,))).status === :pass

    # A type another package owns is refused when the call does not name this package, and
    # stored here when it does.
    @test occursin("could not be stored in `Base`", ConsumerPkg.FOREIGN_UNNAMED)
    @test occursin("mod = @__MODULE__", ConsumerPkg.FOREIGN_UNNAMED)
    @test StrictMode._is_scoped_type(Base.Filesystem.File)
    @test !StrictMode._is_scoped_type(Base.Libc.RawFD)
    @test occursin("could not be stored in `Base`", ConsumerPkg.FOREIGN_BARRIER_UNNAMED)
    @test occursin("mod = @__MODULE__", ConsumerPkg.FOREIGN_BARRIER_UNNAMED)
    @test any(g -> g === Base.Libc.gethostname, StrictMode._barrier_functions())
    @test !any(g -> g === Base.Libc.getpid, StrictMode._barrier_functions())
end

@testset "registrations across packages" begin
    # A registration made in a dependency's `__init__`, one of a type or function another package
    # owns, and one of a callable object. `dependents.jl` builds the packages in a scratch
    # directory and reports what a process that loads them from their caches finds.
    script = joinpath(@__DIR__, "..", "..", "dependents.jl")
    out = mktempdir() do dir
        cmd = `$(Base.julia_cmd()) --startup-file=no $script $dir $(pkgdir(StrictMode))`
        # The child resolves its own environments, so it must not inherit this sandbox's.
        cmd = addenv(cmd, "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing)
        read(ignorestatus(cmd), String)
    end
    facts = Dict{String, String}()
    for line in split(out, '\n')
        parts = split(line, " = "; limit = 2)
        length(parts) == 2 && (facts[parts[1]] = parts[2])
    end
    @test !haskey(facts, "first_load")
    for name in (
            "loaded_from_cache", "top_level_own", "init_scoped", "init_trust", "init_barrier",
            "unnamed_scoped_refused", "unnamed_trust_refused", "unnamed_barrier_refused",
            "named_scoped", "named_trust", "named_barrier", "callable_trust", "callable_barrier",
            "lazy_owner_no_error", "lazy_not_stored", "lazy_in_session",
        )
        @test get(facts, name, "missing") == "true"
    end
end
