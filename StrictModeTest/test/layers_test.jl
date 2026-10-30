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
