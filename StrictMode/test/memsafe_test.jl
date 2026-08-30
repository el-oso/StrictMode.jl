@testmodule MemsafeFixtures begin
    export memsafe_inbounds_kernel!, memsafe_oob_read_kernel!, memsafe_oob_write_kernel!,
        memsafe_align64_check_kernel!, memsafe_copy_overrun!, memsafe_self_launder_kernel!,
        memsafe_alias_required_kernel!, memsafe_poison_collision_kernel!,
        MemsafeWorkspace, memsafe_struct_kernel!, MEMSAFE_KERNELS_FILE

    const MEMSAFE_KERNELS_FILE = joinpath(@__DIR__, "memsafe_kernels.jl")
    include(MEMSAFE_KERNELS_FILE)
end

@testitem "@assert_memsafe / memsafe_report pass cleanly on an in-bounds kernel" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        r = memsafe_report(memsafe_inbounds_kernel!, zeros(8), rand(8))
        @test isnothing(r.violation)
        @test isempty(r.unguarded)

        out = zeros(4)
        a = [1.0, 2.0, 3.0, 4.0]
        val = @assert_memsafe memsafe_inbounds_kernel!(out, a)
        @test isnothing(val)
        @test out == [2.0, 4.0, 6.0, 8.0]   # the REAL call ran on the original args, not a guarded copy
    end
end

@testitem "@assert_memsafe catches a deterministic out-of-bounds READ — issue #15 acceptance" setup = [MemsafeFixtures] begin
    using StrictMode, StrictModeTest
    if Sys.iswindows()
        @test_skip false
    else
        out, a = zeros(8), rand(8)
        # The literal issue #15 acceptance criterion: typestable/noalloc PASS while memsafe catches
        # the fault on the very same call.
        @test isnothing(@assert_typestable memsafe_oob_read_kernel!(out, a))
        @test isnothing(@assert_noalloc memsafe_oob_read_kernel!(out, a))

        r = memsafe_report(memsafe_oob_read_kernel!, zeros(8), rand(8))
        @test !isnothing(r.violation)
        # SIGSEGV on Linux, SIGBUS on macOS — same fault class, platform-dependent signal.
        @test occursin("SIGSEGV", r.violation) || occursin("SIGBUS", r.violation)
        @test occursin("memsafe_oob_read_kernel!", r.violation)   # the child's own report names the faulting op's frame

        @test_throws StrictViolation (@assert_memsafe memsafe_oob_read_kernel!(zeros(8), rand(8)))
    end
end

@testitem "memsafe_report catches an out-of-bounds WRITE and localizes it" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        r = memsafe_report(memsafe_oob_write_kernel!, rand(8))
        @test !isnothing(r.violation)
        @test occursin("WRITE", r.violation)
        # The canary names the ARGUMENT and BYTE OFFSET. That is not cosmetic: since Julia 1.12 a
        # guard-page write fault's backtrace is destroyed (`unknown function (ip: …)`, zero frames),
        # so without this a write violation would carry no localizing information at all.
        @test occursin(r"argument \d+::", r.violation)
        @test occursin("past its end", r.violation)

        @test_throws StrictViolation (@assert_memsafe memsafe_oob_write_kernel!(rand(8)))
    end
end

@testitem "align= reaches the guard buffer built inside the probe subprocess" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        # 9 Float64s = 72 bytes, not a multiple of 64 — the default (align=sizeof(Float64)=8)
        # placement would NOT be 64-aligned here, so this only passes if `align=64` actually reached
        # the guard buffer the CHILD process built.
        r = memsafe_report(memsafe_align64_check_kernel!, rand(9); align = 64)
        @test isnothing(r.violation)
    end
end

@testitem "the canary covers the alignment slack, so a store into it is still caught" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        # align=64 on 9 Float64s (72 bytes) leaves 56 bytes of slack between the data and the guard
        # pages. The store one element past the end lands in that slack: mapped, writable, and so
        # invisible to the guard pages. Only a canary that covers the slack detects it — and at
        # offset 0, exactly at the end of the data, rather than understating by the slack.
        r = memsafe_report(memsafe_oob_write_kernel!, rand(9); align = 64)
        @test !isnothing(r.violation)
        @test occursin("WRITE", r.violation)
        @test occursin("+0 byte(s) past its end", r.violation)
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

@testitem "the removed isolate= option is rejected with a clear error, not silently accepted" begin
    using StrictMode
    err = try
        eval(:(@assert_memsafe isolate = false f(x)))
        nothing
    catch e
        e
    end
    @test err isa LoadError
    @test err.error isa ArgumentError
    @test occursin("was removed", err.error.msg)

    # …and so does the function form, rather than a MethodError from an unknown keyword.
    @test_throws "was removed" memsafe_report(sum, [1.0]; isolate = false)
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

@testitem "memsafe_report errors clearly on a closure/anonymous function (no source file)" begin
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
        gb32 = StrictMode._guarded_array(rand(3); align = 32)
        @test length(gb32.array) == 3
        StrictMode._free_guarded!(gb32)
    end
end

@testitem "MemsafeReport show renders pass/fail and names unguarded arguments" begin
    using StrictMode
    clean = StrictMode.MemsafeReport("f(Int)", nothing, String[])
    @test occursin("clean", sprint(show, clean))

    bad = StrictMode.MemsafeReport("f(Int)", "boom", String[])
    @test occursin("VIOLATION", sprint(show, bad))
    @test occursin("boom", sprint(show, bad))

    # A clean verdict over a partially covered call must not render like a fully covered one.
    partial = StrictMode.MemsafeReport("f(SubArray)", nothing, ["argument 1::SubArray runs unguarded"])
    s = sprint(show, partial)
    @test occursin("clean", s)
    @test occursin("UNGUARDED", s)
    @test occursin("argument 1::SubArray", s)
end

@testitem "the canary poison is PER-BUFFER — a copy kernel cannot launder it" setup = [MemsafeFixtures] begin
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
        # that overruns a read AND a write. Distinct per-buffer bytes make the copied value differ
        # from the destination's own poison, so the store is seen.
        r = memsafe_report(memsafe_copy_overrun!, zeros(8), ones(8))
        @test !isnothing(r.violation)
        @test occursin("WRITE", r.violation)
        @test occursin("argument 1", r.violation)          # the destination is the one written past

        # And the poison really is distinct per buffer.
        @test StrictMode._poison_for(1) != StrictMode._poison_for(2)
    end
end

@testitem "the canary poison is POSITION-DEPENDENT — a shifted self-copy cannot launder it" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        # A constant fill is identical at every position, so copying a buffer's own canary bytes to
        # a shifted offset past its end writes poison over poison and reads back clean. The
        # position-dependent fill makes the source and destination bytes differ.
        r = memsafe_report(memsafe_self_launder_kernel!, rand(8))
        @test !isnothing(r.violation)
        @test occursin("WRITE", r.violation)

        @test StrictMode._poison_byte(0xa5, 0) != StrictMode._poison_byte(0xa5, 16)
    end
end

@testitem "a store of the poison value itself is still detected" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        # A buffer whose overrunning store happens to write the canary's own byte is missed on
        # every run by a constant fill — deterministic, not a low-probability collision. The
        # kernel writes exactly that byte pattern, so this fails if the fill ever goes constant.
        @test StrictMode._poison_for(1) === UInt8(0xb4)   # the value the kernel stores
        r = memsafe_report(memsafe_poison_collision_kernel!, rand(8))
        @test !isnothing(r.violation)
        @test occursin("WRITE", r.violation)
    end
end

@testitem "aliased arguments share one guarded buffer" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        # `f(A, A)` must reach the kernel aliased, as it would in the real call. Independent copies
        # per argument position both hide aliasing-dependent overruns and break kernels that
        # require the aliasing — this one errors outright when handed distinct buffers, which the
        # probe would then report as a script failure rather than a clean run.
        A = rand(8)
        r = memsafe_report(memsafe_alias_required_kernel!, A, A)
        @test isnothing(r.violation)

        _, handles = StrictMode._guarded_args((A, A, rand(4)); align = nothing)
        @test length(handles) == 2                 # two buffers for three arguments
        @test handles[1][1] == [1, 2]              # …the first standing in for both aliased positions
        foreach(h -> StrictMode._free_guarded!(h[2]), handles)
    end
end

@testitem "arguments the harness cannot guard are named, not silently skipped" setup = [MemsafeFixtures] begin
    using StrictMode
    if Sys.iswindows()
        @test_skip false
    else
        # A view has no relocatable backing store. `memsafe_report` records the gap…
        v = view(rand(8), 1:4)
        r = memsafe_report(memsafe_inbounds_kernel!, zeros(4), collect(v))
        @test isempty(r.unguarded)

        u = StrictMode._unguarded_args((zeros(4), v))
        @test length(u) == 1
        @test u[1][1] == 2 && u[1][2] === :abstractarray

        # …and the macro rejects it, since a passing guarantee must not cover less than it names.
        err = try
            @assert_memsafe memsafe_inbounds_kernel!(zeros(4), v)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("cover less than it claims", err.msg)

        # A struct carrying its buffer in a field is named too — the argument list holds no Array.
        ws = MemsafeWorkspace(rand(4))
        us = StrictMode._unguarded_args((ws,))
        @test length(us) == 1
        @test us[1][2] === :struct
        @test StrictMode._carries_array(MemsafeWorkspace)
        @test !StrictMode._carries_array(Float64)
    end
end
