@testitem "Revise extension wires the watch/unwatch hooks" begin
    using StrictMode
    using Revise   # loading both should trigger StrictModeReviseExt.__init__

    # The extension installs the live-loop entry points.
    @test StrictMode._REVISE_WATCH[] !== nothing
    @test StrictMode._REVISE_UNWATCH[] !== nothing
    @test isnothing(unwatch())   # safe no-op when not watching
end
