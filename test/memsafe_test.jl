@testmodule MemsafeFixtures begin
    export memsafe_inbounds_kernel!, memsafe_oob_read_kernel!, memsafe_oob_write_kernel!,
        memsafe_align64_check_kernel!, MEMSAFE_KERNELS_FILE

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
    using StrictMode, StrictModeTest
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
        # SIGSEGV on Linux, SIGBUS on macOS — same fault class, platform-dependent signal.
        @test occursin("SIGSEGV", r.violation) || occursin("SIGBUS", r.violation)
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
        # The canary names the ARGUMENT and BYTE OFFSET. That is not cosmetic: since Julia 1.12 a
        # guard-page write fault's backtrace is destroyed (`unknown function (ip: …)`, zero frames),
        # so without this a write violation would carry no localizing information at all.
        @test occursin(r"argument \d+::", r.violation)
        @test occursin("past its end", r.violation)
    end
end

@testitem "memsafe_report(; isolate=true, the default) also catches an out-of-bounds WRITE" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        r = memsafe_report(memsafe_oob_write_kernel!, rand(8))   # isolate=true (default)
        @test r.violation !== nothing
        @test occursin("WRITE", r.violation)
        # The canary names the ARGUMENT and BYTE OFFSET. That is not cosmetic: since Julia 1.12 a
        # guard-page write fault's backtrace is destroyed (`unknown function (ip: …)`, zero frames),
        # so without this a write violation would carry no localizing information at all.
        @test occursin(r"argument \d+::", r.violation)
        @test occursin("past its end", r.violation)

        @test_throws StrictViolation (@assert_memsafe memsafe_oob_write_kernel!(rand(8)))
    end
end

@testitem "align= reaches the guard buffer built inside the isolate=true subprocess" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        # 9 Float64s = 72 bytes, not a multiple of 64 — the default (align=sizeof(Float64)=8)
        # placement would NOT be 64-aligned here, so this only passes if `align=64` actually reached
        # the guard buffer the CHILD process built, not just the (untested-by-this-case) in-process path.
        r = memsafe_report(memsafe_align64_check_kernel!, rand(9); align = 64)
        @test r.violation === nothing
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
        # isolate=false uses a READABLE, writable, poisoned canary page — a load past the end
        # disturbs nothing, so it is invisible to this mode by construction. That is the same
        # documented limitation as before ("stores only"), but the failure mode is now much better:
        # it used to rely on a guard page, so an out-of-bounds READ under isolate=false KILLED the
        # caller's process outright (SIGSEGV/SIGBUS). It now returns cleanly instead.
        #
        # The tradeoff is explicit: this mode misses reads SILENTLY. It is the cheap in-process
        # option, and `isolate=true` (the default) is what catches loads — asserted directly above.
        script = """
        using StrictMode
        include($(repr(MEMSAFE_KERNELS_FILE)))
        r = memsafe_report(memsafe_oob_read_kernel!, zeros(8), rand(8); isolate=false)
        print(stdout, r.violation === nothing ? "SURVIVED_CLEAN" : "DETECTED")
        """
        cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -e $script`
        outbuf = IOBuffer()
        proc = run(pipeline(cmd; stdout = outbuf, stderr = devnull); wait = false)
        wait(proc)
        @test proc.termsignal == 0                                   # no longer kills the process
        @test occursin("SURVIVED_CLEAN", String(take!(outbuf)))      # …and misses the read, as documented
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

@testitem "@assert_memsafe rejects a dotted using_module path with a clear error, not a MethodError" begin
    using StrictMode
    err = try
        eval(:(@assert_memsafe using_module = Foo.Bar f(x)))
        nothing
    catch e
        e
    end
    @test err isa LoadError
    @test err.error isa ArgumentError
    @test occursin("dotted submodule path", err.error.msg)
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
    if Sys.iswindows()
        @test_skip false   # _guarded_array needs mmap/mprotect/getpagesize, POSIX-only
    else
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
end

@testitem "MemsafeReport show renders pass/fail" begin
    using StrictMode
    clean = StrictMode.MemsafeReport("f(Int)", true, nothing)
    @test occursin("clean", sprint(show, clean))

    bad = StrictMode.MemsafeReport("f(Int)", true, "boom")
    @test occursin("VIOLATION", sprint(show, bad))
    @test occursin("boom", sprint(show, bad))
end

@testitem "the canary poison is PER-BUFFER — a copy kernel cannot launder it" begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        # Regression guard for a false negative that a single shared poison byte would produce, on
        # this package's MOTIVATING kernel shape rather than some corner case.
        #
        # With one shared poison value, a kernel that copies between two guarded buffers launders it:
        # the overrunning load pulls the poison out of the source's canary and the overrunning store
        # writes that same byte into the destination's, so BOTH canaries read back clean on a kernel
        # that overruns a read AND a write. Measured before the fix — source clean, destination
        # clean, violation === nothing. Distinct per-buffer bytes make the copied value differ from
        # the destination's own poison, so the store is seen.
        function copy_overrun!(out::Vector{Float64}, a::Vector{Float64})
            n = length(a) + 1                      # one element past the end of both
            @inbounds for i in 1:n
                unsafe_store!(pointer(out), unsafe_load(pointer(a), i), i)
            end
            return out
        end
        r = memsafe_report(copy_overrun!, zeros(8), ones(8); isolate = false)
        @test r.violation !== nothing
        @test occursin("WRITE", r.violation)
        @test occursin("argument 1", r.violation)          # the destination is the one written past

        # And the poison really is distinct per argument position.
        @test StrictMode._poison_for(1) != StrictMode._poison_for(2)
    end
end
