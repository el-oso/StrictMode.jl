# In-order reductions: AArch64 compiles a strict FP accumulation to vector loads feeding
# `@llvm.vector.reduce.fadd` without `reassoc`, which adds one lane at a time.

@testitem "an in-order reduction behind vector loads is scalar work (captured IR)" begin
    using StrictMode

    # Optimized IR of `s = 0.0; for i in 1:n; s += unsafe_load(p, i); end` on an Apple M-series
    # core (Julia 1.13, LLVM 20). The native loop is `ldp q1, q2` followed by eight `fadd d0, d0, dN`.
    strict_sum_ir = """
    define double @julia_strict_sum(ptr %"p::Ptr", i64 signext %"n::Int64") local_unnamed_addr #0 {
    top:
      %".n::Int64" = call i64 @llvm.smax.i64(i64 %"n::Int64", i64 0)
      %0 = icmp slt i64 %"n::Int64", 1
      br i1 %0, label %L33, label %L17.preheader

    L17.preheader:                                    ; preds = %top
      %invariant.gep = getelementptr i8, ptr %"p::Ptr", i64 -8
      %min.iters.check = icmp slt i64 %"n::Int64", 8
      br i1 %min.iters.check, label %L17, label %vector.ph

    vector.ph:                                        ; preds = %L17.preheader
      %n.vec = and i64 %".n::Int64", 9223372036854775800
      %1 = or disjoint i64 %n.vec, 1
      br label %vector.body

    vector.body:                                      ; preds = %vector.body, %vector.ph
      %index = phi i64 [ 0, %vector.ph ], [ %index.next, %vector.body ]
      %vec.phi = phi double [ 0.000000e+00, %vector.ph ], [ %9, %vector.body ]
      %2 = getelementptr double, ptr %"p::Ptr", i64 %index
      %3 = getelementptr i8, ptr %2, i64 16
      %4 = getelementptr i8, ptr %2, i64 32
      %5 = getelementptr i8, ptr %2, i64 48
      %wide.load = load <2 x double>, ptr %2, align 1
      %wide.load11 = load <2 x double>, ptr %3, align 1
      %wide.load12 = load <2 x double>, ptr %4, align 1
      %wide.load13 = load <2 x double>, ptr %5, align 1
      %6 = call double @llvm.vector.reduce.fadd.v2f64(double %vec.phi, <2 x double> %wide.load)
      %7 = call double @llvm.vector.reduce.fadd.v2f64(double %6, <2 x double> %wide.load11)
      %8 = call double @llvm.vector.reduce.fadd.v2f64(double %7, <2 x double> %wide.load12)
      %9 = call double @llvm.vector.reduce.fadd.v2f64(double %8, <2 x double> %wide.load13)
      %index.next = add nuw i64 %index, 8
      %10 = icmp eq i64 %index.next, %n.vec
      br i1 %10, label %middle.block, label %vector.body

    middle.block:                                     ; preds = %vector.body
      %cmp.n = icmp eq i64 %"n::Int64", %n.vec
      br i1 %cmp.n, label %L33, label %L17

    L17:                                              ; preds = %L17, %middle.block, %L17.preheader
      %value_phi4 = phi i64 [ %12, %L17 ], [ %1, %middle.block ], [ 1, %L17.preheader ]
      %value_phi6 = phi double [ %11, %L17 ], [ %9, %middle.block ], [ 0.000000e+00, %L17.preheader ]
      %gep = getelementptr double, ptr %invariant.gep, i64 %value_phi4
      %pointerref = load double, ptr %gep, align 1
      %11 = fadd double %value_phi6, %pointerref
      %.not = icmp eq i64 %value_phi4, %".n::Int64"
      %12 = add nuw i64 %value_phi4, 1
      br i1 %.not, label %L33, label %L17

    L33:                                              ; preds = %L17, %middle.block, %top
      %value_phi10 = phi double [ 0.000000e+00, %top ], [ %9, %middle.block ], [ %11, %L17 ]
      ret double %value_phi10
    }
    """
    @test !StrictMode._vector_work(strict_sum_ir, StrictMode._VEC_ELT_RE)
    @test StrictMode._scalar_fp_loops(strict_sum_ir)
    r = StrictMode._kernel_report("strict_sum", strict_sum_ir, nothing)
    @test !r.vectorized
    @test r.width == 2 && r.mem_ops == 4       # the vector loads are still reported
    @test iszero(r.fp_ops)
    @test r.ordered_reduce_ops == 4
    @test StrictMode._kr_bound(r) === :scalar
    shown = sprint(show, r)
    @test occursin("not vectorized", shown)
    @test occursin("in-order reductions: 4", shown)

    # The same loop with a product: the multiplies are `fmul <2 x double>` (`fmul.2d`), the adds
    # are still an in-order reduction. A loop holding any vector arithmetic passes, and the
    # report counts the scalar accumulation beside it.
    strict_dot_ir = replace(
        strict_sum_ir,
        "  %6 = call double @llvm.vector.reduce.fadd.v2f64(double %vec.phi, <2 x double> %wide.load)\n" =>
            "  %m = fmul <2 x double> %wide.load, %wide.load11\n" *
            "  %6 = call double @llvm.vector.reduce.fadd.v2f64(double %vec.phi, <2 x double> %m)\n"
    )
    @test strict_dot_ir != strict_sum_ir
    @test StrictMode._vector_work(strict_dot_ir, StrictMode._VEC_ELT_RE)
    @test !StrictMode._scalar_fp_loops(strict_dot_ir)
    rd = StrictMode._kernel_report("strict_dot", strict_dot_ir, nothing)
    @test rd.vectorized && rd.fp_ops == 1 && rd.ordered_reduce_ops == 4
    @test occursin("in-order reductions: 4", sprint(show, rd))

    # A reduction carrying `reassoc` (or `fast`) is a real vector reduction: the horizontal add
    # after a vector accumulator, which is what `@simd` and SIMD.jl's `sum(::Vec)` emit.
    for flags in ("reassoc", "reassoc contract", "contract reassoc", "fast")
        l = "  %r = call $flags double @llvm.vector.reduce.fadd.v2f64(double -0.000000e+00, <2 x double> %v)"
        @test !occursin(StrictMode._ORDERED_REDUCE_RE, l)
        @test StrictMode._vector_work(l, StrictMode._VEC_ELT_RE)
    end
    for l in (
            "  %r = call double @llvm.vector.reduce.fadd.v4f32(float %acc, <4 x float> %v)",
            "  %r = call contract float @llvm.vector.reduce.fadd.v4f32(float %acc, <4 x float> %v)",
            "  %r = call double @llvm.vector.reduce.fmul.v2f64(double %acc, <2 x double> %v)",
            "  %r = call double @llvm.vector.reduce.fadd.nxv2f64(double %acc, <vscale x 2 x double> %v)",
        )
        @test occursin(StrictMode._ORDERED_REDUCE_RE, l)
        @test !StrictMode._vector_work(l, StrictMode._VEC_ELT_RE)
    end

    # Loads, lane extractions and phis name a vector type without computing on one.
    @test !StrictMode._vector_work(
        """
          %v = load <2 x double>, ptr %p, align 8
          %a = phi <2 x double> [ %v, %top ], [ %v, %L1 ]
          %x = extractelement <2 x double> %v, i64 1
          %s = fadd double %acc, %x
        """, StrictMode._VEC_ELT_RE
    )
    @test StrictMode._vector_work("  store <2 x double> %v, ptr %p, align 8", StrictMode._VEC_ELT_RE)
    @test StrictMode._vector_work("  %c = icmp eq <16 x i8> %a, %b", StrictMode._VEC_ELT_RE)
end

@testitem "scalable vectors (SVE/SME) are read as vectors" begin
    using StrictMode

    # The shape LLVM emits for a `@simd` axpy on an SVE target: every vector type is
    # `<vscale x N x T>` and the intrinsics are mangled `nxvN`.
    sve_axpy_ir = """
    define void @julia_axpy(ptr %y, double %a, ptr %x, i64 %n) {
    top:
      br label %vector.body

    vector.body:                                      ; preds = %vector.body, %top
      %index = phi i64 [ 0, %top ], [ %index.next, %vector.body ]
      %px = getelementptr double, ptr %x, i64 %index
      %py = getelementptr double, ptr %y, i64 %index
      %wide.load = load <vscale x 2 x double>, ptr %px, align 8
      %wide.load1 = load <vscale x 2 x double>, ptr %py, align 8
      %0 = call <vscale x 2 x double> @llvm.fmuladd.nxv2f64(<vscale x 2 x double> %splat, <vscale x 2 x double> %wide.load, <vscale x 2 x double> %wide.load1)
      %1 = fmul contract <vscale x 2 x double> %0, %splat
      store <vscale x 2 x double> %1, ptr %py, align 8
      %index.next = add nuw i64 %index, 2
      %2 = icmp eq i64 %index.next, %n
      br i1 %2, label %exit, label %vector.body

    exit:                                             ; preds = %vector.body
      ret void
    }
    """
    r = StrictMode._kernel_report("axpy", sve_axpy_ir, nothing)
    @test r.vectorized
    @test r.width == 2                 # the minimum width: `vscale` multiplies it at run time
    @test r.fp_ops == 2                # the fmuladd and the fmul
    @test r.mem_ops == 3
    @test r.fastmath_ops == 1
    @test iszero(r.ordered_reduce_ops)
    @test !StrictMode._scalar_fp_loops(sve_axpy_ir)

    # An SVE strict sum: scalable loads feeding an in-order reduction (`fadda`).
    sve_strict_ir = """
    define double @julia_sum(ptr %x, i64 %n) {
    top:
      br label %vector.body

    vector.body:                                      ; preds = %vector.body, %top
      %index = phi i64 [ 0, %top ], [ %index.next, %vector.body ]
      %vec.phi = phi double [ 0.000000e+00, %top ], [ %0, %vector.body ]
      %px = getelementptr double, ptr %x, i64 %index
      %wide.load = load <vscale x 2 x double>, ptr %px, align 8
      %0 = call double @llvm.vector.reduce.fadd.nxv2f64(double %vec.phi, <vscale x 2 x double> %wide.load)
      %index.next = add nuw i64 %index, 2
      %1 = icmp eq i64 %index.next, %n
      br i1 %1, label %exit, label %vector.body

    exit:                                             ; preds = %vector.body
      ret double %0
    }
    """
    rs = StrictMode._kernel_report("sum", sve_strict_ir, nothing)
    @test !rs.vectorized && rs.ordered_reduce_ops == 1 && iszero(rs.fp_ops)
    @test StrictMode._scalar_fp_loops(sve_strict_ir)
end

@testitem "a strict accumulation fails :vectorized on every target (compiled)" begin
    using StrictMode, StrictModeTest

    # No `@simd`, so the adds must stay in order. x86 leaves the loop scalar; AArch64 loads
    # `<2 x double>` and reduces in order. Neither is vector arithmetic.
    @noinline function strict_sum(p::Ptr{Float64}, n::Int)
        s = 0.0
        for i in 1:n
            s += unsafe_load(p, i)
        end
        return s
    end
    @noinline function strict_sum32(p::Ptr{Float32}, n::Int)
        s = 0.0f0
        for i in 1:n
            s += unsafe_load(p, i)
        end
        return s
    end
    x = ones(64)
    x32 = ones(Float32, 64)
    @test GC.@preserve(x, strict_sum(pointer(x), 64)) == 64.0
    @test GC.@preserve(x32, strict_sum32(pointer(x32), 64)) == 64.0f0

    for (f, T) in ((strict_sum, Float64), (strict_sum32, Float32))
        types = (Ptr{T}, Int)
        @test !StrictMode._vectorized(f, types)
        @test scalar_fp_loops(f, types)
        r = kernel_report(f, types)
        @test !r.vectorized
        @test iszero(r.fp_ops)
        @test StrictMode._failed(only(findings(f, types; guarantees = (:vectorized,))))
        @test StrictMode._failed(only(findings(f, types; guarantees = (:no_scalar_loops,))))
        @test_throws StrictViolation test_signatures([(f, types)]; guarantees = (:vectorized,))
        # The report counts exactly the in-order reductions the compiler emitted.
        ir = StrictMode._llvm_ir(f, types)
        @test r.ordered_reduce_ops == count("@llvm.vector.reduce.fadd", ir)
        # Coverage instrumentation keeps the loop scalar, so the vector loads are only there
        # without it.
        if Sys.ARCH === :aarch64 && iszero(Base.JLOptions().code_coverage)
            @test r.ordered_reduce_ops > 0
            @test r.mem_ops > 0 && r.width > 0
        end
    end
    @test_throws StrictViolation GC.@preserve x (@assert_vectorized strict_sum(pointer(x), 64))
end

@testitem "vector fused multiply-adds count as vector arithmetic (compiled)" begin
    using StrictMode, StrictModeTest
    using SIMD: Vec, vload, vstore

    # 128-bit vectors, so the kernels are native on NEON as well as on AVX.
    @noinline function vec_axpy!(p::Ptr{T}, q::Ptr{T}, n::Int, a::T, ::Val{N}) where {T, N}
        V = Vec{N, T}
        i = 0
        while i + N <= n
            o = i * sizeof(T)
            vstore(muladd(vload(V, q + o), V(a), vload(V, p + o)), p + o)
            i += N
        end
        return nothing
    end
    # A vector accumulator and one horizontal add at the end: a `reassoc` reduction.
    @noinline function vec_sum(p::Ptr{Float64}, n::Int)
        V = Vec{2, Float64}
        acc = V(0.0)
        i = 0
        while i + 2 <= n
            acc += vload(V, p + i * 8)
            i += 2
        end
        return sum(acc)
    end
    y = ones(64)
    x = ones(64)
    GC.@preserve x y vec_axpy!(pointer(y), pointer(x), 64, 2.0, Val(2))
    @test all(==(3.0), y)
    @test GC.@preserve(x, vec_sum(pointer(x), 64)) == 64.0

    for (T, N) in ((Float64, 2), (Float32, 4))
        types = (Ptr{T}, Ptr{T}, Int, T, Val{N})
        @test StrictMode._vectorized(vec_axpy!, types)
        @test !scalar_fp_loops(vec_axpy!, types)
        r = kernel_report(vec_axpy!, types)
        @test r.vectorized && r.width == N
        @test r.fp_ops >= 1            # `@llvm.fmuladd.vN…`, or an `fmul` + `fadd` pair
        @test r.mem_ops >= 3
        @test iszero(r.ordered_reduce_ops)
        @test only(findings(vec_axpy!, types; guarantees = (:vectorized,))).status === :pass
        @test only(findings(vec_axpy!, types; guarantees = (:no_scalar_loops,))).status === :pass
        if Sys.ARCH === :aarch64
            # The op counted above is the one NEON runs as `fmla`.
            @test occursin(r"\bfmla\b", StrictMode._native_asm(vec_axpy!, types))
        end
    end

    types = (Ptr{Float64}, Int)
    @test StrictMode._vectorized(vec_sum, types)
    @test !scalar_fp_loops(vec_sum, types)
    r = kernel_report(vec_sum, types)
    @test r.vectorized && r.fp_ops >= 1 && iszero(r.ordered_reduce_ops)
end
