@testitem "audit returns the findings (consistent) and emits JSON" begin
    using StrictMode, StrictModeTest
    empty!(StrictMode.registered_strict())
    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    boxy(t::Tuple{Int, Float64, Float32}) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    StrictMode.register_strict!(clean, (NTuple{3, Float64}, NTuple{3, Float64}))
    StrictMode.register_strict!(boxy, (Tuple{Int, Float64, Float32},))

    buf = IOBuffer()
    fs = audit(:registered; format = :json, io = buf)
    @test fs isa Vector{StrictFinding}            # same return type as the other drivers
    @test nfailures(fs) ≥ 1                        # boxy fails (allocates)
    out = String(take!(buf))
    @test occursin("\"status\":\"fail\"", out)
    @test occursin("\"suggestion\":", out)        # agents get an actionable hint
    @test startswith(strip(out), "[")             # valid JSON array
end

@testitem "audit is clean (0 failures) for a clean registry" begin
    using StrictMode, StrictModeTest
    empty!(StrictMode.registered_strict())
    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    StrictMode.register_strict!(clean, (NTuple{3, Float64}, NTuple{3, Float64}))
    @test nfailures(audit(:registered; format = :jsonlines, io = IOBuffer())) == 0
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
    empty!(StrictMode.exempt_strict())
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
