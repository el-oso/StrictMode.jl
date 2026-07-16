@testsetup module MemsafeFixtures
export memsafe_inbounds_kernel!, memsafe_oob_read_kernel!, memsafe_oob_write_kernel!, MEMSAFE_KERNELS_FILE

const MEMSAFE_KERNELS_FILE = joinpath(@__DIR__, "memsafe_kernels.jl")
include(MEMSAFE_KERNELS_FILE)
end

@testitem "@assert_memsafe / memsafe_report pass cleanly on an in-bounds kernel (both modes)" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        r1 = memsafe_report(memsafe_inbounds_kernel!, zeros(8), rand(8))
        @test r1.violation === nothing

        r2 = memsafe_report(memsafe_inbounds_kernel!, zeros(8), rand(8); isolate = false)
        @test r2.violation === nothing

        out = zeros(4)
        a = [1.0, 2.0, 3.0, 4.0]
        val = @assert_memsafe memsafe_inbounds_kernel!(out, a)
        @test val === nothing
        @test out == [2.0, 4.0, 6.0, 8.0]   # the REAL call ran on the original args, not a guarded copy
    end
end

@testitem "@assert_memsafe catches a deterministic out-of-bounds READ (isolate=true) — issue #15 acceptance" setup = [MemsafeFixtures] begin
    using StrictMode, AllocCheck, JET
    if Sys.iswindows()
        @test_skip false
    else
        out, a = zeros(8), rand(8)
        # The literal issue #15 acceptance criterion: typestable/noalloc PASS while memsafe catches
        # the fault on the very same call.
        @test (@assert_typestable memsafe_oob_read_kernel!(out, a)) === nothing
        @test (@assert_noalloc memsafe_oob_read_kernel!(out, a)) === nothing

        r = memsafe_report(memsafe_oob_read_kernel!, zeros(8), rand(8))
        @test r.violation !== nothing
        @test occursin("SIGSEGV", r.violation)
        @test occursin("memsafe_oob_read_kernel!", r.violation)   # the child's own report names the faulting op's frame

        @test_throws StrictViolation (@assert_memsafe memsafe_oob_read_kernel!(zeros(8), rand(8)))
    end
end

@testitem "memsafe_report(; isolate=false) catches an out-of-bounds WRITE (store-only)" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        r = memsafe_report(memsafe_oob_write_kernel!, rand(8); isolate = false)
        @test r.violation !== nothing
        @test occursin("WRITE", r.violation)
        @test occursin("ReadOnlyMemoryError", r.violation)
    end
end

@testitem "isolate=false genuinely cannot catch an out-of-bounds READ (documented limitation)" setup = [MemsafeFixtures] begin
    using StrictMode
    # Fatal and uncatchable IN-PROCESS by design (Julia's segv handler only converts a *write*
    # fault into ReadOnlyMemoryError) — verified in a disposable subprocess so a real crash here
    # doesn't take down the test runner. Confirms the documented isolate=false limitation is real,
    # not just asserted in a docstring.
    if Sys.iswindows()
        @test_skip false
    else
        script = """
        using StrictMode
        include($(repr(MEMSAFE_KERNELS_FILE)))
        memsafe_report(memsafe_oob_read_kernel!, zeros(8), rand(8); isolate=false)
        print(stdout, "SHOULD_NOT_REACH_HERE")
        """
        cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -e $script`
        outbuf = IOBuffer()
        proc = run(pipeline(cmd; stdout = outbuf, stderr = devnull); wait = false)
        wait(proc)
        @test proc.termsignal == 11   # SIGSEGV — the process died, isolate=false did not (could not) catch it
        @test !occursin("SHOULD_NOT_REACH_HERE", String(take!(outbuf)))
    end
end

@testitem "@assert_memsafe rejects keyword-argument calls with a clear error" begin
    using StrictMode
    # `eval` of a top-level expression wraps a macro-expansion-time error in `LoadError`.
    err = try
        eval(:(@assert_memsafe f(x; k = 1)))
        nothing
    catch e
        e
    end
    @test err isa LoadError
    @test err.error isa ArgumentError
end

@testitem "memsafe_report errors clearly on a closure/anonymous function (isolate=true, no file)" begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        captured = 3.0
        closure_kernel(x) = x + captured
        @test_throws ErrorException memsafe_report(closure_kernel, 1.0)
    end
end

@testitem "_guarded_array is exact-flush and warns when a wider align forces slack" begin
    using StrictMode
    for n in (1, 3, 7, 64, 4097)
        src = rand(n)
        gb = StrictMode._guarded_array(src)
        @test gb.array == src
        @test length(gb.array) == n
        StrictMode._free_guarded!(gb)
    end

    # align wider than sizeof(Float64) forces slack on a length that isn't a clean multiple —
    # exercised for the warning path, not asserted on stdout/stderr content.
    gb = StrictMode._guarded_array(rand(3); align = 32)
    @test length(gb.array) == 3
    StrictMode._free_guarded!(gb)
end

@testitem "MemsafeReport show renders pass/fail" begin
    using StrictMode
    clean = StrictMode.MemsafeReport("f(Int)", true, nothing)
    @test occursin("clean", sprint(show, clean))

    bad = StrictMode.MemsafeReport("f(Int)", true, "boom")
    @test occursin("VIOLATION", sprint(show, bad))
    @test occursin("boom", sprint(show, bad))
end
