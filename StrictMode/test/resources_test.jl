@testitem "resource_leak_report names the shapes that outlive a scoped owner" begin
    using StrictMode

    module Leaks
    struct Workspace
        buf::Vector{Float64}
    end
    const SINK = Ref{Any}(nothing)

    borrow_escapes(ws::Workspace) = ws.buf                   # the caller holds the borrow
    stash!(ws::Workspace) = (SINK[] = ws.buf; nothing)       # escapes through an unscoped container
    function spawn_it(ws::Workspace)                         # outlives the frame AND is shared
        t = Threads.@spawn (ws.buf[1] += 1.0)
        wait(t)
        return nothing
    end
    # Copying a VALUE out is not handing over the handle, and a scoped owner receiving it is
    # ownership rather than a leak.
    owned!(ws::Workspace, o::Workspace) = (o.buf[1] = ws.buf[1]; nothing)
    total(ws::Workspace) = sum(ws.buf)
    end

    W = Leaks.Workspace
    # Read from COMPILED signatures, so every method has to run once first.
    Leaks.borrow_escapes(W(zeros(2))); Leaks.stash!(W(zeros(2)))
    Leaks.spawn_it(W(zeros(2))); Leaks.owned!(W(zeros(2)), W(zeros(2))); Leaks.total(W(zeros(2)))

    # With nothing registered there is no resource to leak, so the sweep is silent by construction.
    @test isempty(resource_leak_report(Leaks))

    register_scoped!(W)
    fs = resource_leak_report(Leaks)
    by = Dict(f.func => f for f in fs)

    @test Set(keys(by)) == Set(["borrow_escapes", "stash!", "spawn_it"])
    @test all(f -> f.guarantee === :resource && f.status === :info && f.code === :SM0309, fs)

    @test occursin("returned", by["borrow_escapes"].reason)
    @test occursin("stored outside a scoped owner", by["stash!"].reason)
    @test occursin("captured by a task", by["spawn_it"].reason)

    # The two that hand over no handle are not reported at all.
    @test !haskey(by, "owned!")
    @test !haskey(by, "total")

    # An empty report is a lead, not a proof, and the suggestion says so.
    @test occursin("could not follow", by["stash!"].suggestion)

    # The name filters behave as on every other sweep.
    @test isempty(resource_leak_report(Leaks; only = r"^nothing_matches$"))
    @test !haskey(
        Dict(f.func => f for f in resource_leak_report(Leaks; exempt = (:borrow_escapes,))),
        "borrow_escapes"
    )

    # It REPORTS: `:resource` is no part of the swept guarantees, and there is no gating form.
    @test !(:resource in StrictMode._GUARANTEES)
end
