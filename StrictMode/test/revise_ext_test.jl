@testitem "Revise extension wires the watch/unwatch hooks" begin
    using StrictMode
    using Revise   # loading both should trigger StrictModeReviseExt.__init__

    # The extension installs the live-loop entry points.
    @test StrictMode._REVISE_WATCH[] !== nothing
    @test StrictMode._REVISE_UNWATCH[] !== nothing
    @test isnothing(unwatch())   # safe no-op when not watching
end

@testitem "the Revise watcher re-checks a declaration made by @strict_function" begin
    using StrictMode
    using Revise
    ext = Base.get_extension(StrictMode, :StrictModeReviseExt)
    StrictMode.clear_declarations!()
    # `@strict_function` stores its declaration in the declaring module, not in this session's own
    # registry, so the watcher must read every declaration in scope.
    @strict_function rw_grows(x::Vector{Float64}) = x .+ 1.0
    @test isempty(StrictMode.registered_strict())
    @test !isempty(StrictMode.declarations())
    out = mktemp() do path, io
        redirect_stdout(ext._on_revision, io)
        close(io)
        read(path, String)
    end
    @test occursin("rw_grows", out)
    StrictMode.clear_declarations!()
end
