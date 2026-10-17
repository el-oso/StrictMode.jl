@testitem "audit returns the findings (consistent) and emits JSON" begin
    using StrictMode, StrictModeTest
    StrictMode.clear_declarations!()
    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    boxy(t::Tuple{Int, Float64, Float32}) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    StrictMode.register_strict!(clean, (NTuple{3, Float64}, NTuple{3, Float64}))
    StrictMode.register_strict!(boxy, (Tuple{Int, Float64, Float32},))

    fs = audit(:registered)
    @test fs isa Vector{StrictFinding}            # same return type as the other drivers
    @test nfailures(fs) ≥ 1                        # boxy fails (allocates)
    out = format_findings(fs; format = :json)
    @test occursin("\"status\":\"fail\"", out)
    @test occursin("\"suggestion\":", out)        # agents get an actionable hint
    @test startswith(strip(out), "[")             # valid JSON array
end

@testitem "audit is clean (0 failures) for a clean registry" begin
    using StrictMode, StrictModeTest
    StrictMode.clear_declarations!()
    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    StrictMode.register_strict!(clean, (NTuple{3, Float64}, NTuple{3, Float64}))
    @test nfailures(audit(:registered)) == 0
end

@testitem "the compiled sweep's only/exempt filters scope it" begin
    using StrictMode, StrictModeTest
    module Mixed
    hot(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    cold(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )   # boxes by design (a "plan-time" helper)
    end
    Mixed.hot((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
    Mixed.cold((1, 2.0, 3.0f0))

    # exempt the cold helper → no failures from it
    fs = StrictMode._findings_compiled(Mixed; guarantees = (:noalloc, :noboxing), exempt = [:cold])
    @test !any(f -> f.func == "cold", fs)
    # only the hot kernel
    only_hot = StrictMode._findings_compiled(Mixed; guarantees = (:noalloc,), only = [:hot])
    @test all(f -> f.func == "hot", only_hot)
end

@testitem "exempt/only match keyword-argument methods (kwsorter demangling)" begin
    using StrictMode, StrictModeTest
    StrictMode.clear_declarations!()
    @test StrictMode._demangle(Symbol("#foo#34")) === :foo
    @test StrictMode._demangle(:foo) === :foo

    module KW
    kwf(x::Int; k::Int = 1) = collect(1:(x + k))   # allocates; kwargs → kwsorter `#kwf#NN`
    end
    KW.kwf(3; k = 2)                                    # compile the kwsorter

    @test any(StrictMode._failed, StrictMode._findings_compiled(KW; guarantees = (:noalloc,)))      # flagged
    # exempt by the BASE name must skip the mangled kwsorter method too
    # `_failed`, not a hand-written status comparison: this is a NEGATIVE assertion, so one
    # predicate must decide what counts, or it would pass vacuously if the exempt silently stopped
    # working and left a finding behind.
    @test isempty(filter(StrictMode._failed, StrictMode._findings_compiled(KW; guarantees = (:noalloc,), exempt = [:kwf])))
end

@testitem "test_signatures gates an explicit (f, types) list (E2)" begin
    using StrictMode, StrictModeTest
    good(a, b) = a * b + 1.0
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    fs = test_signatures([(good, (Float64, Float64))])
    @test all(f -> f.status === :pass, fs)
    @test_throws StrictViolation test_signatures(
        [(boxy, (Tuple{Int, Float64, Float32},))]; guarantees = (:noboxing,),
    )
end

@testitem "the compiled sweep's exempt accepts a regex and a predicate (E2)" begin
    using StrictMode, StrictModeTest
    module Mix2
    hotk(x::Int) = x + 1
    _planhelper(n::Int) = collect(1:n)        # allocates by design (cold)
    end
    Mix2.hotk(1); Mix2._planhelper(3)             # compile both

    flagged(fs) = any(f -> f.func == "_planhelper" && StrictMode._failed(f), fs)
    @test flagged(StrictMode._findings_compiled(Mix2; guarantees = (:noalloc,)))                  # no filter → flagged
    @test !flagged(StrictMode._findings_compiled(Mix2; guarantees = (:noalloc,), exempt = r"^_plan"))   # regex
    @test !flagged(
        StrictMode._findings_compiled(
            Mix2; guarantees = (:noalloc,),
            exempt = f -> startswith(string(nameof(f)), "_")
        )
    )                          # predicate
end

@testitem "migration_report finds the sites that stopped gating, and ignores src/" begin
    using StrictMode
    # A throwaway package layout: the same macro in `src/` (correct as-is) and in `test/`
    # (silently non-gating since 0.4).
    root = mktempdir()
    mkpath(joinpath(root, "src")); mkpath(joinpath(root, "test"))
    write(
        joinpath(root, "src", "MyPkg.jl"), """
        module MyPkg
        f(x) = @assert_noalloc g(x)
        end
        """
    )
    write(
        joinpath(root, "test", "runtests.jl"), """
        @assert_noalloc kernel!(C, A, B)
        # @assert_noboxing commented_out(x)
        @kernel axpy!(y, a, x)
        @assert_no_scalar_loops glue!(z)
        @strict_function keep(x::Int) = x
        """
    )
    buf = IOBuffer()
    n = migration_report(root; io = buf)
    out = String(take!(buf))

    @test n == 3                                     # test/ only: noalloc, kernel, no_scalar_loops
    @test occursin("@assert_noalloc", out) && occursin("→  @test_noalloc", out)
    @test occursin("@kernel", out) && occursin("→  @test_kernel", out)
    @test occursin("no proving counterpart", out)    # @assert_no_scalar_loops has none
    @test !occursin("MyPkg.jl", out)                 # src/ is deliberately not scanned
    @test !occursin("commented_out", out)            # comment lines skipped
    @test !occursin("@strict_function", out)         # word boundary: `@strict` must not match it

    # A clean package reports zero rather than saying nothing.
    clean = mktempdir(); mkpath(joinpath(clean, "test"))
    write(joinpath(clean, "test", "runtests.jl"), "@test_noalloc already_migrated(x)\n")
    b2 = IOBuffer()
    @test migration_report(clean; io = b2) == 0
    @test occursin("nothing to change", String(take!(b2)))
end

@testitem "migration_report flags DELETED api anywhere, including src/" begin
    using StrictMode
    # A macro in `src/` is correct and must stay unreported; a DELETED NAME there is fatal — the
    # package will not even load — so that half scans every directory. Three of the consumer
    # packages on this machine gate a block of `src/` on `analysis_mode()`/`backend_available()`.
    root = mktempdir()
    mkpath(joinpath(root, "src")); mkpath(joinpath(root, "test"))
    write(
        joinpath(root, "src", "P.jl"), """
        if StrictMode.analysis_mode() === :fast || StrictMode.backend_available()
            @assert_noalloc hot(x)
        end
        """
    )
    write(joinpath(root, "test", "runtests.jl"), "fs = check_signatures([(f, (Int,))])\n")
    buf = IOBuffer()
    n = migration_report(root; io = buf)
    out = String(take!(buf))

    @test occursin("will not load", out)
    @test occursin("analysis_mode", out) && occursin("backend_available", out)
    @test occursin("check_signatures", out) && occursin("test_signatures", out)
    @test !occursin("@assert_noalloc", out)   # a src/ macro is correct, not a finding
    @test n == 3                              # 2 deleted names in src/, 1 in test/
end

@testitem "audit returns findings and renders nothing; the old kwargs name their replacement" begin
    using StrictMode
    StrictMode.clear_declarations!()
    clean2(a::Float64) = a * 2.0
    StrictMode.register_strict!(clean2, (Float64,); guarantees = (:typestable,))

    # Nothing is written: the value is the product, and a sweep's rendering is far too large to
    # push through a log or a tool-result channel on every call.
    mktemp() do path, io
        redirect_stdout(io) do
            audit(:registered)
        end
        flush(io)
        @test read(path, String) == ""
    end

    # A call written against the rendering surface is told what to call instead.
    err = try
        audit(:registered; format = :json)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("format_findings", err.msg)

    StrictMode.clear_declarations!()
end

@testitem "a finding carries its tier, and the tier reaches the serialized record" begin
    using StrictMode, StrictModeTest
    boxy2(t::Tuple{Int, Float64}) = t[rand(1:2)]

    scan = StrictMode.findings(boxy2, (Tuple{Int, Float64},); guarantees = (:noboxing,))
    @test all(f -> f.tier === :report, scan)

    proved = StrictModeTest.proof_findings(boxy2, (Tuple{Int, Float64},); guarantees = (:noboxing,))
    @test all(f -> f.tier === :proof, proved)

    # The whole point of the field: a saved record keeps the distinction.
    @test occursin("\"tier\":\"report\"", format_findings(scan; format = :jsonlines))
    @test occursin("\"tier\":\"proof\"", format_findings(proved; format = :jsonlines))
end

@testitem "findings_diff compares two runs by key" begin
    using StrictMode
    bad3(x::Vector{Float64}) = sum(abs, x) > 0 ? [1.0] : 2.0
    good3(x::Float64) = x + 1.0

    b = StrictMode.findings(bad3, (Vector{Float64},); guarantees = (:typestable,))
    g = StrictMode.findings(good3, (Float64,); guarantees = (:typestable,))
    @test nfailures(b) == 1 && nfailures(g) == 0

    # Different functions, so the failure in `b` is fixed and nothing is introduced.
    d = StrictMode.findings_diff(b, g)
    @test length(d.fixed) == 1 && isempty(d.introduced) && isempty(d.changed)

    # The same run against itself: everything shared, nothing fixed or introduced.
    d2 = StrictMode.findings_diff(b, b)
    @test isempty(d2.fixed) && isempty(d2.introduced) && isempty(d2.changed)
    @test length(d2.unchanged) == 1
    @test StrictMode.key(only(d2.unchanged)) ==
        (nameof(@__MODULE__), "bad3", "(Vector{Float64})", :typestable)
end
