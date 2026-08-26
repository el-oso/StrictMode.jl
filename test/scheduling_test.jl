@testitem "@assert_vectorized flags a loop that cannot vectorize" begin
    using StrictMode
    # A plain float reduction can't reassociate → never vectorizes (robust across CPU targets).
    # Whether the `@simd` version *does* vectorize depends on the build's target features (a generic
    # CI runner has no AVX), so a portable test asserts only the negative + that the API returns a Bool.
    novec(a::Vector{Float64}) = (
        s = 0.0; for x in a
            s += x
        end; s
    )
    vec(a::Vector{Float64}) = (
        s = 0.0; @inbounds @simd for x in a
            s += x
        end; s
    )
    A = rand(64)

    @test StrictMode._vectorized(novec, (Vector{Float64},)) == false
    @test StrictMode._vectorized(vec, (Vector{Float64},)) isa Bool
    @test_throws StrictViolation @assert_vectorized novec(A)      # not vectorized → fails loudly
end

@testitem "@assert_effects checks inferred effects" begin
    using StrictMode
    add(a::Float64, b::Float64) = a + b
    @test (@assert_effects add(1.0, 2.0) (:nothrow,)) === 3.0      # float add is nothrow

    thrower(x::Int) = x > 0 ? x : error("neg")
    @test_throws StrictViolation @assert_effects thrower(2) (:nothrow,)   # can throw → not :nothrow
end

@testitem "descend asks for Cthulhu when it isn't loaded" begin
    using StrictMode
    f(x) = x + 1
    # Cthulhu is not in the test environment → descend logs an @info and returns (never throws).
    @test descend(f, (Int,)) === nothing
end

@testitem "llvmcall escape hatch round-trips and stays verifiable" begin
    using StrictMode
    # The escape hatch for scheduling-bound kernels: hand-written LLVM IR. StrictMode's role is to
    # keep it *verifiable* — you can still assert it's on the fast path.
    addllvm(x::Int64, y::Int64) = Base.llvmcall("%z = add i64 %0, %1\nret i64 %z", Int64, Tuple{Int64, Int64}, x, y)
    @test addllvm(2, 3) == 5
    @test (@assert_noalloc addllvm(2, 3)) == 5      # the hand-written kernel is allocation-free
end

@testitem "F31 register_report returns a RegisterReport (shape; counts are machine-dependent)" begin
    using StrictMode
    # Any concrete function works — register counts depend on the target CPU, so we only assert
    # on shape (isa, field invariants) rather than specific values.
    dot3(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    rr = register_report(dot3, (NTuple{3, Float64}, NTuple{3, Float64}))
    @test rr isa StrictMode.RegisterReport
    @test rr.vec_regs_total == 0 || rr.vec_regs_total == 32   # either no zmm or AVX-512
    @test rr.vec_regs_used >= 0
    @test rr.vec_spills >= 0
    @test rr.vec_regs_used <= rr.vec_regs_total || rr.vec_regs_total == 0
    # show must not error
    @test sprint(show, rr) isa String
end

@testitem "F32 scalar_fp_loops sees a scalar TAIL after a SIMD body (issue #22 regression)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore
    # The canonical defect: an explicit `while i + W <= n` SIMD body followed by a `while i < n`
    # scalar cleanup. A tail is a pure STORE loop (load, compute, store) and carries no loop-carried
    # FP accumulator, so the old per-region test — which required a `phi double` on top of a region
    # already known to be a loop — missed it while the IR still held scalar FP ops.
    function tail_scalar!(p::Ptr{Float64}, n::Int, a::Float64)
        V = Vec{8, Float64}; i = 0
        while i + 8 <= n
            vstore(muladd(vload(V, p + i * 8), V(a), vload(V, p + i * 8)), p + i * 8); i += 8
        end
        while i < n
            unsafe_store!(p, muladd(a, unsafe_load(p, i + 1), unsafe_load(p, i + 1)), i + 1); i += 1
        end
        return nothing
    end
    # Same kernel with the tail MASKED — the fix for the defect, and it must read clean.
    function tail_masked!(p::Ptr{Float64}, n::Int, a::Float64)
        V = Vec{8, Float64}; i = 0
        while i + 8 <= n
            vstore(muladd(vload(V, p + i * 8), V(a), vload(V, p + i * 8)), p + i * 8); i += 8
        end
        if i < n
            m = Vec((1, 2, 3, 4, 5, 6, 7, 8)) <= (n - i)
            vstore(muladd(vload(V, p + i * 8, m), V(a), vload(V, p + i * 8, m)), p + i * 8, m)
        end
        return nothing
    end
    @test scalar_fp_loops(tail_scalar!, (Ptr{Float64}, Int, Float64))         # the defect
    @test !scalar_fp_loops(tail_masked!, (Ptr{Float64}, Int, Float64))        # the fix reads clean
end

@testitem "F31 register_report counts registers in BOTH asm syntaxes (issue #21 regression)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore
    using InteractiveUtils: code_native
    # The shape-only test above passes when `vec_regs_used == 0`, which is exactly how the AT&T-only
    # regex (`%zmm…`) went unnoticed: Julia emits INTEL syntax by default here, so the match set was
    # always empty and every kernel reported 0/0 — silently, and in the safe-looking direction.
    # This pins the report against the assembly itself: if the asm names zmm registers, so must the
    # report. Self-gating, so it is meaningful on AVX-512 and inert elsewhere.
    function zkernel!(p::Ptr{Float64}, n::Int)
        V = Vec{8, Float64}; i = 0
        while i + 8 <= n
            vstore(vload(V, p + i * 8) * V(2.0), p + i * 8); i += 8
        end
        return nothing
    end
    io = IOBuffer()
    code_native(io, zkernel!, (Ptr{Float64}, Int); debuginfo = :none)
    asm = String(take!(io))
    rr = register_report(zkernel!, (Ptr{Float64}, Int))
    if occursin(r"\bzmm\d+\b", asm)          # AVX-512 host: the report must SEE them
        @test rr.vec_regs_used > 0
        @test rr.vec_regs_total == 32
    else
        @test rr.vec_regs_used == 0          # no zmm in the asm ⇒ zeros are correct
    end
    # Syntax independence directly: the regex must match an AT&T operand as well as an Intel one.
    @test occursin(r"\bzmm(\d+)\b", "vaddpd %zmm1, %zmm2, %zmm3")   # AT&T
    @test occursin(r"\bzmm(\d+)\b", "vaddpd zmm3, zmm2, zmm1")      # Intel
end

@testitem "scheduling asserts validate a real SIMD.jl Vec kernel (item 4)" begin
    using StrictMode
    using SIMD: Vec, vload, vstore
    # Explicit SIMD.jl `Vec` ops emit `<N x double>` in the LLVM IR *regardless of CPU target*
    # (unlike `@simd` auto-vectorization, which is target-gated) — this mirrors PureFFT's
    # vload/vstore-over-preallocated-scratch hot kernels, the real pattern we validated against.
    function vscale!(dst::Vector{Float64}, src::Vector{Float64})
        @inbounds for i in 1:8:length(src)
            v = vload(Vec{8, Float64}, src, i)
            vstore(v * 2.0, dst, i)
        end
        return dst
    end
    D = zeros(64); S = rand(64); vscale!(D, S)

    @test StrictMode._vectorized(vscale!, (Vector{Float64}, Vector{Float64}))   # explicit Vec → vector IR
    @test (@assert_vectorized vscale!(D, S)) === D                             # passes on a real SIMD kernel
    @test (@assert_noalloc vscale!(D, S)) === D                                # and stays allocation-free
    # @assert_effects API works (we don't assert platform-specific effect *values*).
    eff = StrictMode.effects(vscale!, (Vector{Float64}, Vector{Float64}))
    @test StrictMode.effect_holds(eff, :terminates) isa Bool
end
