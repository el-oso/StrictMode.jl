@testitem "test_layers allows extension along the declared direction and rejects it against" begin
    using StrictMode, StrictModeTest

    module Kernel
    public area
    area(x) = 0.0
    struct Square
        s::Float64
    end
    area(sq::Square) = sq.s^2
    end

    module Engine
    using ..Kernel
    struct Circle
        r::Float64
    end
    Kernel.area(c::Circle) = 3.14 * c.r^2        # allowed: Engine declares Kernel
    spin(c::Circle) = Kernel.area(c)
    end

    module Rogue
    using ..Kernel, ..Engine
    Engine.spin(::Int) = -1.0                    # Rogue does not declare Engine
    end

    graph = [Kernel => (), Engine => (Kernel,), Rogue => (Kernel,)]
    fs = StrictModeTest._layer_findings(graph)
    @test length(fs) == 3                        # one row per layer, pass or fail
    @test Set(f.mod for f in fs) == Set([:Kernel, :Engine, :Rogue])

    # Only the layer that extended against its declaration fails.
    failed = filter(StrictMode._failed, fs)
    @test length(failed) == 1
    bad = only(failed)
    @test bad.mod === :Rogue
    @test bad.func == "spin"
    @test bad.code === :SM0205
    @test occursin("Rogue", bad.reason) && occursin("Engine.spin", bad.reason)

    @test_throws StrictMode.StrictViolation test_layers(graph...)
    @test_throws "does not declare" test_layers(graph...)

    # Declaring the direction makes it legal — the rule is the declaration, not a fixed hierarchy.
    @test iszero(nfailures(test_layers(Kernel => (), Engine => (Kernel,), Rogue => (Kernel, Engine))))

    # A layer absent from the graph is not judged at all, so the graph is the opt-in.
    @test iszero(nfailures(test_layers(Kernel => (), Engine => (Kernel,))))
end

@testitem "test_layers reports a layer that reads another layer's implementation" begin
    using StrictMode, StrictModeTest

    # A real fixture rather than a contrived one: StrictModeTest reaches into about twenty
    # StrictMode internals by design, which is the whole reason the two ship in lockstep. The check
    # should say so, because that coupling is exactly what a layer declaration is meant to make
    # visible rather than silent.
    fs = StrictModeTest._layer_findings([StrictMode => (), StrictModeTest => (StrictMode,)])
    failed = filter(StrictMode._failed, fs)
    @test !isempty(failed)
    @test all(f -> f.mod === :StrictModeTest, failed)
    @test all(f -> f.code === :SM0205, failed)
    @test any(f -> occursin("does not declare public", f.reason), failed)
    @test any(f -> occursin("StrictMode.", f.reason), failed)

    # The graph above ALLOWS StrictModeTest to depend on StrictMode, and these are still failures:
    # the direction is permitted, the private name is not. Nothing in the declaration can excuse
    # reading another layer's implementation, which is what makes the two rules independent.
    @test !any(f -> occursin("among the layers it may see", f.reason), failed)

    # The access half needs source on disk. A module that is not inside a package contributes no
    # access findings rather than erroring, so a graph of in-session modules is still checkable for
    # the extension rule alone.
    module NoFile
    g(x) = x
    end
    @test isnothing(pathof(Base.moduleroot(NoFile)))
    @test iszero(nfailures(test_layers(NoFile => ())))
end

@testitem "test_layers judges only the modules the graph names" begin
    using StrictMode, StrictModeTest

    # This is what keeps the check usable. StrictMode reads Base and Core internals deliberately —
    # `Base.ACTIVE_PROJECT`, `Core.Argument` and dozens more — and the underlying analysis returns
    # every one of them. They are not layer violations, because Base and Core are not layers, and
    # reporting them would bury the findings the declaration is about.
    fs = StrictModeTest._layer_findings([StrictMode => ()])
    @test iszero(nfailures(fs))

    # …and the analysis really does see those accesses, so this pins the filter rather than an
    # accident of what the parser found.
    rows = StrictModeTest.ExplicitImports.improper_qualified_accesses(StrictMode, pathof(StrictMode))
    own = only(r for r in rows if first(r) === StrictMode)
    @test count(a -> !a.public_access, last(own)) > 10
end

@testitem "test_layers rejects a graph it cannot act on" begin
    using StrictMode, StrictModeTest

    module Solo
    f(x) = x
    end

    @test_throws "no layers declared" test_layers()
    @test_throws "must be a Module" test_layers(:NotAModule => ())
    @test_throws "may only name Modules" test_layers(Solo => (:alsoNot,))
    @test_throws "declared twice" test_layers(Solo => (), Solo => ())
    @test_throws "`Layer => (deps…)`" StrictModeTest._layer_graph((Solo,))
end

@testitem "rule 2 judges sibling submodules of ONE package" begin
    using StrictMode, StrictModeTest

    # Submodules of a single package are the main use of a layer graph: two packages already have
    # Pkg-level separation, while siblings have nothing else holding the boundary. ExplicitImports
    # defaults `allow_internal_accesses` to `true`, which drops every access between modules sharing
    # a `Base.moduleroot` — so with the default this rule fired only between separate PACKAGES, and
    # every positive control used a package pair, which is how the gap survived.
    #
    # A real package on disk, because the rule parses source: `pathof(Base.moduleroot(layer))` is
    # the file it reads, and a module defined inside a test item has none.
    dir = mktempdir()
    pkg = joinpath(dir, "LayerSiblings")
    mkpath(joinpath(pkg, "src"))
    write(
        joinpath(pkg, "Project.toml"),
        # A fixed UUID, written out rather than generated: this fixture is never resolved from a
        # registry, so the value only has to be unique, and a literal keeps `UUIDs` out of the test
        # environment's dependencies.
        """
        name = "LayerSiblings"
        uuid = "6f1a2b3c-4d5e-4f60-9a71-8b2c3d4e5f60"
        version = "0.1.0"
        """
    )
    write(
        joinpath(pkg, "src", "LayerSiblings.jl"),
        """
        module LayerSiblings
        module Store
            public numel
            const index = [1, 2, 3]
            numel(x) = length(x)
        end
        module Reader
            using ..Store
            peek() = length(Store.index)
        end
        end
        """
    )
    push!(LOAD_PATH, dir)
    try
        LS = @eval (using LayerSiblings; LayerSiblings)
        store, reader = LS.Store, LS.Reader

        # The read crosses two declared layers, so it is reported whatever the direction says.
        failed = filter(
            StrictMode._failed,
            StrictModeTest._layer_findings([LS => (store, reader), store => (), reader => ()])
        )
        # Asserted before `only`, so a rule that stops firing reads as "Reader was not reported"
        # rather than as an empty-collection error.
        reader_rows = filter(f -> f.mod === :Reader, failed)
        @test length(reader_rows) == 1
        bad = only(reader_rows)
        @test bad.func == "index"
        @test bad.code === :SM0205
        @test occursin("Reader", bad.reason) && occursin("Store.index", bad.reason)

        # …and the graph stays the opt-in. With `Store` outside it there is no second layer to
        # read from, and with both submodules inside ONE layer the read is internal to that layer.
        @test iszero(nfailures(StrictModeTest._layer_findings([reader => ()])))
        @test iszero(nfailures(StrictModeTest._layer_findings([LS => ()])))
    finally
        filter!(!=(dir), LOAD_PATH)
    end
end
