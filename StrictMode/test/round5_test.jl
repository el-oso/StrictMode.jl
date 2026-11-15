# Round 5 (BlazingPorts faer Cholesky port): F10 kernel_report, F11 callee-aware @assert_vectorized,
# F12 empty-sweep warning + the :vectorized guarantee.

@testitem "kernel_report reads arithmetic intensity (F10)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore
    # Explicit SIMD.jl Vec → vector IR regardless of CPU target (robust on any CI runner).
    # memory-bound: one multiply per load+store.
    mem!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in 1:8:length(x)
            vstore(vload(Vec{8, Float64}, x, i) * 2.0, y, i)
        end; y
    )
    # compute-bound: a Horner polynomial on the loaded vector — many FMAs per load+store.
    comp!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in 1:8:length(x)
            v = vload(Vec{8, Float64}, x, i)
            vstore((((v * 0.1 + 0.2) * v + 0.3) * v + 0.4) * v + 0.5, y, i)
        end; y
    )
    rm = kernel_report(mem!, (Vector{Float64}, Vector{Float64}))
    rc = kernel_report(comp!, (Vector{Float64}, Vector{Float64}))

    @test rm.vectorized && rc.vectorized                # both have <N x> ops
    @test rm.intensity < rc.intensity                   # compute-bound has higher FP:mem (robust ordering)
    @test StrictMode._kr_bound(rc) === :compute         # many FMAs per access → compute-bound
    @test occursin("intensity", sprint(show, rm))       # the report renders the diagnostic
end

@testitem "kernel_report counts fast-math-flagged FP ops (F38)" begin
    using StrictMode
    # `@fastmath` rewrites `+`/`*`/… to their fast-math intrinsic variants unconditionally, so it
    # flags scalar ops with LLVM fast-math flags regardless of whether the loop auto-vectorizes.
    # `@simd` alone doesn't: its fast-math flags land only on ops the auto-vectorizer actually
    # widens into `<N x …>`, which depends on the target CPU's SIMD width — this genuinely differs
    # between a local AVX-capable machine and a CI runner (found via a real CI failure: `@simd`
    # didn't vectorize on the runner, so `r.vectorized` was false). `@fastmath` is the portable way
    # to exercise this signal; the `@simd` case below is checked best-effort, not asserted.
    function fastmath_dot(a::Vector{Float64}, b::Vector{Float64})
        s = 0.0
        @fastmath @inbounds for i in eachindex(a, b)
            s += a[i] * b[i]
        end
        return s
    end
    r = kernel_report(fastmath_dot, (Vector{Float64}, Vector{Float64}))
    # Fast-math changes FP semantics (reassociation, NaN/Inf assumptions), not just codegen — this
    # must surface as an explicit warning, not just be silently folded into fp_ops. Must hold
    # whether or not the kernel vectorized (a real bug fixed here: the warning used to be
    # unreachable code in `show` whenever `!r.vectorized`).
    @test r.fastmath_ops > 0
    @test occursin("fast-math", sprint(show, r))

    # `@inbounds @simd` grants the compiler reassociation permission, which LLVM records as
    # fast-math flags between the opcode and its type on the ops it actually vectorizes (`fmul
    # contract <8 x double>`). Best-effort: whether this loop widens into `<N x …>` ops (and so
    # whether these flags appear at all) is target-CPU dependent, not a portability guarantee.
    function simd_dot(a::Vector{Float64}, b::Vector{Float64})
        s = 0.0
        @inbounds @simd for i in eachindex(a, b)
            s += a[i] * b[i]
        end
        return s
    end
    r_simd = kernel_report(simd_dot, (Vector{Float64}, Vector{Float64}))
    if r_simd.vectorized
        @test r_simd.fp_ops > 0
        @test StrictMode._kr_bound(r_simd) !== :memory
    end

    # A plain (no fastmath at all) scalar loop carries no fast-math flags — no false positive.
    function plain_dot(a::Vector{Float64}, b::Vector{Float64})
        s = 0.0
        for i in eachindex(a, b)
            s += a[i] * b[i]
        end
        return s
    end
    r_plain = kernel_report(plain_dot, (Vector{Float64}, Vector{Float64}))
    @test r_plain.fastmath_ops == 0
    @test !occursin("fast-math", sprint(show, r_plain))
end

@testitem "@assert_vectorized names non-inlined callees (F11)" begin
    using StrictMode
    @noinline leaf!(y, x) = (
        @inbounds @simd for i in eachindex(y)
            y[i] = x[i] * 2.0
        end; y
    )
    wrapper!(y, x) = leaf!(y, x)            # thin dispatcher: SIMD lives in the non-inlined leaf
    err = try
        @assert_vectorized wrapper!(zeros(8), rand(8))
        nothing
    catch e
        e
    end
    @test err isa StrictViolation
    @test occursin("leaf!", err.details)   # the message points at the leaf kernel
end

@testitem "the compiled sweep warns when empty; :vectorized is a guarantee (F12)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore
    module EmptyMod end
    @test_logs (:warn, r"no compiled method specializations") StrictMode._findings_compiled(EmptyMod)

    # :vectorized is now a valid engine guarantee (what F12's audit invocation passed).
    vk!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in 1:8:length(x)
            vstore(vload(Vec{8, Float64}, x, i) * 2.0, y, i)
        end; y
    )
    fs = findings(vk!, (Vector{Float64}, Vector{Float64}); guarantees = (:vectorized,))
    @test first(fs).status === :pass
end

@testitem "F13/F14/F15 kernel_report extensions" begin
    using StrictMode
    using SIMD: Vec, vload, vstore

    # Reuse the kernels from the F10 test (same shapes suffice)
    mem!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in 1:8:length(x)
            vstore(vload(Vec{8, Float64}, x, i) * 2.0, y, i)
        end; y
    )
    comp!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in 1:8:length(x)
            v = vload(Vec{8, Float64}, x, i)
            vstore((((v * 0.1 + 0.2) * v + 0.3) * v + 0.4) * v + 0.5, y, i)
        end; y
    )

    # F13 masking: a plain non-power-of-2 loop lets LLVM emit masked remainder ops
    scalar_loop!(y::Vector{Float64}, x::Vector{Float64}) = (
        @inbounds for i in eachindex(y)
            y[i] = x[i] * 2.0
        end; y
    )

    rm = kernel_report(mem!, (Vector{Float64}, Vector{Float64}))
    rc = kernel_report(comp!, (Vector{Float64}, Vector{Float64}))
    rsl = kernel_report(scalar_loop!, (Vector{Float64}, Vector{Float64}))

    # F13 struct fields exist and are integers
    @test rm.unaligned_mem_ops isa Int
    @test rm.masked_mem_ops isa Int
    @test rc.unaligned_mem_ops isa Int
    @test rc.masked_mem_ops isa Int

    # F14: working_set_bytes stored correctly
    r_l1 = kernel_report(mem!, (Vector{Float64}, Vector{Float64}); working_set_bytes = 1024)
    r_dram = kernel_report(comp!, (Vector{Float64}, Vector{Float64}); working_set_bytes = 32 * 1024 * 1024)
    @test r_l1.working_set_bytes == 1024
    @test r_dram.working_set_bytes == 32 * 1024 * 1024

    # F14: L1-resident shows "acceptable" note
    s_l1 = sprint(show, r_l1)
    @test occursin("L1", s_l1)
    @test occursin("acceptable", s_l1)

    # F14/F15: large working set + compute-bound → packing note
    s_dram = sprint(show, r_dram)
    @test occursin(r"L3|DRAM", s_dram)
    @test occursin("packing", s_dram)

    # F15: large working set + memory-bound → cache-blocking note (not packing)
    r_mem_large = kernel_report(mem!, (Vector{Float64}, Vector{Float64}); working_set_bytes = 32 * 1024 * 1024)
    s_mem_large = sprint(show, r_mem_large)
    @test occursin("cache-blocking", s_mem_large) || occursin("tiling", s_mem_large)

    # no-kwarg path unchanged (backward compat)
    @test isnothing(rm.working_set_bytes)
    @test occursin("intensity", sprint(show, rm))
end

@testitem "register_report is assembly-syntax agnostic (issue #21)" begin
    using StrictMode
    # `code_native` emits Intel syntax (`zmm0`) on some platform/Julia combinations and AT&T
    # (`%zmm0`) on others. A register regex pinned to the AT&T `%` sigil reports `used = 0` on an
    # Intel-syntax host however much vector work the kernel does — a silent zero, which for an
    # advisory report is worse than an error. `_zmm_counts` is the parser `register_report` itself
    # runs; driving it over fixed assembly keeps the check independent of what this host emits.
    att = "\tvmulpd\t%zmm1, %zmm2, %zmm3\n\tvaddpd\t%zmm3, %zmm4, %zmm1\n\tvmovupd\t%zmm5, 64(%rsp)\n"
    intel = "\tvmulpd\tzmm1, zmm2, zmm3\n\tvaddpd\tzmm3, zmm4, zmm1\n\tvmovupd\tzmmword ptr [rsp + 64], zmm5\n"
    @test StrictMode._zmm_counts(att) == (used = 5, total = 32, spills = 1)
    @test StrictMode._zmm_counts(intel) == (used = 5, total = 32, spills = 1)
    # No zmm at all: `total = 0` is what marks a report "non-AVX-512" rather than "clean", so a
    # regex loose enough to match `xmm`/`ymm` would silently turn every SSE kernel into a 0/32 one.
    @test StrictMode._zmm_counts("\tvaddsd\t%xmm0, %xmm1, %xmm0\n") == (used = 0, total = 0, spills = 0)

    # Live path: the report has to agree with the assembly it was read from. Conditioning on the raw
    # text rather than on the host CPU keeps the assertion falsifiable where AVX-512 exists and
    # honest where it doesn't.
    saxpy!(y::Vector{Float64}, a::Float64, x::Vector{Float64}) = (
        @inbounds @simd for i in eachindex(y, x)
            y[i] += a * x[i]
        end; y
    )
    types = (Vector{Float64}, Float64, Vector{Float64})
    r = register_report(saxpy!, types)
    @test r isa StrictMode.RegisterReport
    if occursin("zmm", StrictMode._native_asm(saxpy!, types))
        @test r.vec_regs_used > 0
        @test r.vec_regs_total == 32
    else
        @test r.vec_regs_used == 0
        @test r.vec_regs_total == 0
    end
end

@testitem "_alloc_signals memoizes the top body, and clear_cache! invalidates it" begin
    using StrictMode
    f_memo(a::Vector{Float64}, b::Vector{Float64}) = (s = 0.0; @inbounds @simd for i in eachindex(a, b)
            s += a[i] * b[i]
        end; s)
    tt = (Vector{Float64}, Vector{Float64})
    f_memo(rand(4), rand(4))

    StrictMode.clear_cache!()
    sig = Base.signature_type(f_memo, Tuple{tt...})
    @test !haskey(StrictMode._TOP_SIGNAL_MEMO, sig)

    first_result = StrictMode._alloc_signals(f_memo, tt)
    @test haskey(StrictMode._TOP_SIGNAL_MEMO, sig)
    # The cached answer must equal the uncached one, field for field — a memo that returns
    # something else is worse than no memo.
    @test StrictMode._alloc_signals(f_memo, tt) == first_result
    @test StrictMode._alloc_signals_uncached(f_memo, tt, sig, StrictMode._FAST_ALLOC_DEPTH[]) == first_result

    # Keyed by depth as well as signature, so a different depth is a different question.
    StrictMode._alloc_signals(f_memo, tt; depth = 0)
    @test length(StrictMode._TOP_SIGNAL_MEMO[sig]) == 2

    StrictMode.clear_cache!()
    @test !haskey(StrictMode._TOP_SIGNAL_MEMO, sig)
end

@testitem "compiled-output checks read past a default-argument forwarder" begin
    using StrictMode
    # Omitting a defaulted argument calls a forwarder that only calls the full method. Without
    # following it the checks read no loop, and a spill check passes for want of anything to spill.
    @noinline function fwd_kernel!(y::Vector{Float64}, x::Vector{Float64}, ::Val{B} = Val(false)) where {B}
        @inbounds @simd for i in eachindex(y, x)
            y[i] = y[i] * x[i] + x[i]
        end
        return y
    end
    V = Vector{Float64}
    fwd_kernel!(rand(64), rand(64))
    @test StrictMode._forwarded_types(fwd_kernel!, (V, V)) == (V, V, Val{false})
    @test StrictMode._vectorized(fwd_kernel!, (V, V)) == StrictMode._vectorized(fwd_kernel!, (V, V, Val{false}))
    @test StrictMode.spill_report(fwd_kernel!, (V, V)).vec_spills ==
        StrictMode.spill_report(fwd_kernel!, (V, V, Val{false})).vec_spills

    # A body that is not a forwarder is read as itself.
    plain(x::Vector{Float64}) = sum(x)
    @test StrictMode._forwarded_types(plain, (V,)) == (V,)
end

@testitem "a forwarder to a kernel returning nothing is read past too" begin
    using StrictMode
    # When the callee returns `nothing`, inference returns that constant from the forwarder and
    # leaves the call's own result unused, so the forwarder does not return the call.
    @noinline function fwd_void!(y::Vector{Float64}, x::Vector{Float64}, ::Val{B} = Val(false)) where {B}
        @inbounds @simd for i in eachindex(y, x)
            y[i] = y[i] * x[i] + x[i]
        end
        return nothing
    end
    V = Vector{Float64}
    fwd_void!(rand(64), rand(64))
    @test StrictMode._forwarded_types(fwd_void!, (V, V)) == (V, V, Val{false})
    @test StrictMode._vectorized(fwd_void!, (V, V)) == StrictMode._vectorized(fwd_void!, (V, V, Val{false}))
end

@testitem "spills are placed by the loop LLVM's annotations put them in" begin
    using StrictMode
    # Canned x86 assembly in the shape LLVM prints: a prologue, an outer loop with an inner loop and
    # a remainder loop, and an epilogue. One spill sits in each place.
    asm = """
    julia_k:
    \tvmovups\t%ymm0, (%rsp)                # 32-byte Spill
    .LBB0_3:                                # %L13
                                            # =>This Loop Header: Depth=1
                                            #     Child Loop BB0_6 Depth 2
    \tvmovups\t%ymm1, 32(%rsp)              # 32-byte Spill
    .LBB0_6:                                # %L28
                                            #   Parent Loop BB0_3 Depth=1
                                            # =>  This Inner Loop Header: Depth=2
    \tvmovups\t64(%rsp), %ymm2              # 32-byte Reload
    \tjne\t.LBB0_6
    # %bb.7:                                #   in Loop: Header=BB0_3 Depth=1
    \tjne\t.LBB0_3
    .LBB0_12:                               # %L170
    \tvmovsd\t(%rsp), %xmm3                 # 8-byte Reload
    \tretq
    """
    lines = split(asm, '\n')
    depth, inner = StrictMode._asm_loop_depths(lines)
    at(pat) = findfirst(l -> occursin(pat, l), lines)
    @test depth[at("%ymm0, (%rsp)")] == 0          # prologue
    @test depth[at("%ymm1, 32(%rsp)")] == 1        # outer loop body
    @test !inner[at("%ymm1, 32(%rsp)")]
    @test depth[at("64(%rsp), %ymm2")] == 2        # innermost loop
    @test inner[at("64(%rsp), %ymm2")]
    @test depth[at("%xmm3")] == 0                  # epilogue
end

@testitem "compiled-output checks and the escape scan read past a keyword forwarder" begin
    using StrictMode
    # A method with keywords compiles its positional entry to a body that calls `#f#N`.
    @noinline function kwfwd_kernel!(y::Vector{Float64}, x::Vector{Float64}; scale = 1.0)
        @inbounds @simd for i in eachindex(y, x)
            y[i] = y[i] * x[i] * scale
        end
        return nothing
    end
    V = Vector{Float64}
    kwfwd_kernel!(rand(64), rand(64))
    f, ts = StrictMode._forwarded_call(kwfwd_kernel!, (V, V))
    @test f !== kwfwd_kernel!
    @test StrictMode._vectorized(kwfwd_kernel!, (V, V)) == StrictMode._vectorized(f, ts)

    # A body that calls an ordinary function last is not a forwarder to it.
    @noinline inner_read(v::Vector{Float64}) = v[1]
    outer_kw(v::Vector{Float64}; k = 1) = inner_read(v) + k
    outer_kw([1.0])
    body = Base.signature_type(first(StrictMode._forwarded_call(outer_kw, (V,))),
        Tuple{last(StrictMode._forwarded_call(outer_kw, (V,)))...})
    @test StrictMode._forwarded_sig(body) === body
end
