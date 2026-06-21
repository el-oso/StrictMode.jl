@testitem "@explain returns a passing report for a clean call" begin
    using StrictMode
    clean(a, b) = 0.5a + 0.5b
    r = @explain clean(2.0, 4.0)

    @test r isa StrictReport
    @test r.return_concrete
    @test !StrictMode.would_fail_typestable(r)
    @test !StrictMode.would_fail_noalloc(r)

    text = sprint(show, MIME"text/plain"(), r)
    @test occursin("✓ @assert_typestable would pass", text)
    @test occursin("✓ @assert_noalloc would pass", text)
end

@testitem "@explain diagnoses the runtime tuple-indexing boxing case" begin
    using StrictMode
    heterogeneous = (1, 2.0, "three")
    pick(tup, i) = tup[i]
    r = @explain pick(heterogeneous, rand(1:3))

    @test r isa StrictReport
    @test !r.return_concrete                       # Union return type
    @test StrictMode.would_fail_typestable(r)
    @test StrictMode.would_fail_noalloc(r)         # boxing shows as an allocation

    text = sprint(show, MIME"text/plain"(), r)
    @test occursin("✗ @assert_typestable would fail", text)
    @test occursin("✗ @assert_noalloc would fail", text)
    @test occursin("@code_warntype", text)         # instability → warntype section included
end

@testitem "@explain does not throw on a failing call (unlike the asserts)" begin
    using StrictMode
    makevec(n) = collect(1:n)
    r = @explain makevec(5)                        # allocates, but @explain only reports
    @test r isa StrictReport
    @test StrictMode.would_fail_noalloc(r)
end
