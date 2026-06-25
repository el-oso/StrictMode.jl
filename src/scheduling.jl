# Surface & (partly) force the scheduling / vectorization layer — the residual gap vs Rust that
# lives *below* user code. StrictMode cannot match rustc's instruction scheduler (an explicit
# non-goal); what it can do is make that layer **visible** (`@assert_vectorized`, `@assert_effects`,
# `descend`) and **reachable** (the documented `@assume_effects` / `@simd ivdep` / `llvmcall`
# escape hatches). All of these use only Base + InteractiveUtils — no AllocCheck/JET backend.

# Best-effort: did the method's LLVM IR contain SIMD vector ops? (`<N x double>` & friends.)
function _vectorized(@nospecialize(f), @nospecialize(types::Tuple))
    io = IOBuffer()
    try
        InteractiveUtils.code_llvm(io, f, types; debuginfo = :none, optimize = true)
    catch
        return false
    end
    return occursin(r"<\d+ x (float|double|half|i\d+)>", String(take!(io)))
end

# Names of the non-inlined callees (`:invoke` targets) in `f`'s optimized body — where SIMD may
# live if it isn't in `f` itself (a thin dispatcher). Used to make `@assert_vectorized`'s failure
# point at the leaf kernels.
function _invoke_callees(@nospecialize(f), @nospecialize(types::Tuple))
    out = String[]
    cts = try
        Base.code_typed(f, Tuple{types...}; optimize = true)
    catch
        return out
    end
    isempty(cts) && return out
    for st in first(cts).first.code
        if Meta.isexpr(st, :invoke)
            a1 = st.args[1]
            mi = a1 isa Core.CodeInstance ? a1.def : a1
            mi isa Core.MethodInstance && push!(out, string(mi.def.name))
        end
    end
    return unique!(out)
end

function _assert_vectorized(target, @nospecialize(f), @nospecialize(types::Tuple))
    _vectorized(f, types) && return nothing
    # `@assert_vectorized` inspects the *leaf* compiled body. A thin dispatcher has no vector ops of
    # its own — point the user at the non-inlined callees where the SIMD actually is (F11).
    callees = _invoke_callees(f, types)
    hint = isempty(callees) ? "" :
        " The SIMD may be in non-inlined callee(s) — assert on those directly: $(join(callees, ", "))."
    _fail(
        :vectorized, target,
        "no `<N x …>` vector ops in this method body (best-effort)." * hint *
            " (Try `@inbounds @simd`/`@simd ivdep`, or `descend` to see why.)"
    )
    return nothing
end

"""
    @assert_vectorized f(args...)

Fail unless `f(args...)` compiled to SIMD vector instructions (**best-effort**): StrictMode scans
the method's LLVM IR for vector types (`<N x …>`). A failure means the compiler did not vectorize
the loop under the current settings — informative, not a proof, so it is **not** part of
[`@strict`](@ref). Each argument is evaluated once; disabled builds expand to the bare call.

It inspects the **leaf compiled body**: a thin dispatcher that forwards to non-inlined kernels has
no vector ops of its own, so assert on the kernels where the SIMD lives (the failure message names
the non-inlined callees to help). See also [`kernel_report`](@ref) for *why-not-fast-enough*
diagnostics when a loop vectorizes but is still slow.

```julia
@inbounds @simd_dot(a, b)          # vectorizes → ok
@assert_vectorized branchy(a)      # throws: a data-dependent branch blocked vectorization
```
"""
macro assert_vectorized(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)
    checked = quote
        $(binds...)
        local _val = $litcall
        $(_assert_vectorized)($target, $fe, $types)
        _val
    end
    return _gate(checked, esc(call))
end

# --- @assert_effects (via Base.infer_effects) -------------------------------------------------

function _assert_effects(target, @nospecialize(f), @nospecialize(types::Tuple), required)
    eff = effects(f, types)
    missing_eff = Symbol[s for s in required if !effect_holds(eff, s)]
    isempty(missing_eff) || _fail(
        :effects, target,
        "inferred effects missing $(join(missing_eff, ", ")) for the requested guarantee (have: $eff)."
    )
    return nothing
end

"""
    @assert_effects f(args...) (:nothrow, :effect_free, ...)

Fail unless the compiler infers the requested [effects](https://docs.julialang.org/en/v1/base/base/#Base.@assume_effects)
for `f(args...)`, via `Base.infer_effects`. Effects are one or more of `:nothrow`, `:effect_free`,
`:terminates`, `:consistent`, `:nonoverlayed`. This is the *verify* side of effects; to *declare*
them (and influence codegen), use `Base.@assume_effects`. Each argument is evaluated once.

```julia
@assert_effects dot3(a, b) (:nothrow, :effect_free)   # ok if the compiler agrees
```
"""
macro assert_effects(call, required)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)
    checked = quote
        $(binds...)
        local _val = $litcall
        $(_assert_effects)($target, $fe, $types, $(esc(required)))
        _val
    end
    return _gate(checked, esc(call))
end

# --- descend escape hatch (Cthulhu weak-dep extension fills this in) ---------------------------

const _CTHULHU_DESCEND = Ref{Any}(nothing)

"""
    descend(f, types)

Drop into [Cthulhu](https://github.com/JuliaDebug/Cthulhu.jl)'s interactive descent on the method
`f(::types...)` to *see* the layer StrictMode can't control — inlining decisions, inferred
effects, type-stability, and the LLVM/native code. Requires Cthulhu (`using Cthulhu`); it is an
optional heavy weak dependency, loaded only when you want to look. This is the visibility escape
hatch for scheduling-bound kernels.
"""
function descend(@nospecialize(f), @nospecialize(types))
    _CTHULHU_DESCEND[] === nothing &&
        return @info "StrictMode.descend needs Cthulhu — run `using Cthulhu` first (it's an optional weak dependency)."
    return _CTHULHU_DESCEND[](f, types)
end

# --- kernel_report: a *performance-quality* diagnostic (not a pass/fail guarantee) -------------
#
# The correctness-style guarantees (`@assert_vectorized`/`@assert_noalloc`/`@assert_typestable`)
# are NECESSARY but NOT SUFFICIENT for speed: a naive `Vec` loop and a register-blocked microkernel
# both pass them identically, yet differ ~2–6×. What separates a toy SIMD loop from a microkernel is
# arithmetic intensity (FLOP : memory traffic) — reuse of loaded data across many FMAs. This reads
# that signal from the LLVM IR (FP vector ops : memory vector ops), so a green-but-slow kernel can be
# *seen* to be memory-bound. Heuristic and advisory — it does not replace a profiler or a roofline.

struct KernelReport
    target::String
    vectorized::Bool
    width::Int         # widest vector seen (N in `<N x …>`)
    fp_ops::Int        # vector FP arithmetic ops (fmul/fadd/fsub/fdiv + fma/fmuladd intrinsics)
    mem_ops::Int       # vector loads + stores
    intensity::Float64 # fp_ops / mem_ops — an arithmetic-intensity proxy (∞ when no memory ops)
    # F13
    unaligned_mem_ops::Int          # vector loads/stores where recorded align < vector width
    masked_mem_ops::Int             # @llvm.masked.* ops → irregular/variable-length trips
    # F14/F15
    working_set_bytes::Union{Nothing,Int}   # user-supplied; enables cache-residency annotation
    # F22
    int_ops::Int        # vector integer arithmetic ops (add/sub/mul/and/or/xor/shl/icmp on <N x iN>)
    int_mem_ops::Int    # vector integer loads + stores
    # F24
    branch_count::Int   # conditional branches (br i1) coexisting with vector ops — mispredict risk (F24)
    # F28
    serial_dep_count::Int # high-latency ops (div/rem/sqrt) in functions with loop-carried phi — serialization risk (F28)
    # F29
    noalias_missing_count::Int  # pointer params without noalias in LLVM IR define line — aliasing risk (F29)
end

function _llvm_ir(@nospecialize(f), @nospecialize(types::Tuple))
    io = IOBuffer()
    try
        InteractiveUtils.code_llvm(io, f, types; debuginfo = :none, optimize = true)
    catch
        return ""
    end
    return String(take!(io))
end

function _native_asm(@nospecialize(f), @nospecialize(types::Tuple))
    io = IOBuffer()
    try
        InteractiveUtils.code_native(io, f, types; debuginfo = :none)
    catch
        return ""
    end
    return String(take!(io))
end

function _kr_bound(r::KernelReport)
    !r.vectorized && return :scalar
    # Use FP intensity if available; fall back to integer intensity for integer-only kernels
    eff = if r.fp_ops > 0
        r.intensity
    elseif r.int_mem_ops > 0
        r.int_ops / r.int_mem_ops
    else
        0.0
    end
    eff >= 2.0 && return :compute
    eff >= 0.75 && return :balanced
    return :memory
end

# Defaults; overwritten at load time by StrictModeCpuIdExt when `using CpuId` is in scope.
# Override for non-standard hardware: StrictMode._CACHE_BYTES[] = (l1=…, l2=…, l3=…)
const _CACHE_BYTES = Ref((l1 = 32_768, l2 = 524_288, l3 = 16_777_216))

"""
    kernel_report(f, types) -> KernelReport

A **performance-quality diagnostic** for a numeric kernel — the layer *beneath* the pass/fail
guarantees. `@assert_vectorized`/`@assert_noalloc` confirm a loop is vectorized and allocation-free,
but say nothing about whether it's a *good* microkernel: a naive `Vec` loop and a register-blocked
one both pass them, yet can differ several-fold. `kernel_report` reads the **arithmetic intensity**
(FP vector ops : memory vector ops) from the LLVM IR, so a green-but-slow kernel can be *seen* to be
memory-bound — pointing straight at register/cache blocking rather than discovered by benchmarking.

Fields: `vectorized`, `width`, `fp_ops`, `mem_ops`, `intensity` (= `fp_ops/mem_ops`),
`unaligned_mem_ops` (vector loads/stores with alignment < vector width — a proxy for unaligned
access), `masked_mem_ops` (masked/variable-length memory ops — a proxy for irregular trip counts).
**Heuristic and advisory** — it never fails, and does not replace a profiler/roofline.

Pass `working_set_bytes` to get a cache-residency annotation: if the working set fits L1/L2,
low intensity is expected and acceptable; if it spills L2 and the kernel is already
compute-bound, the report notes the cache-blocking (packing) gap that per-kernel IR analysis
cannot close (F15 ceiling).

```julia
kernel_report(syrk_naive!, (Matrix{Float64},))   # intensity ≈ 0.7 → memory-bound (add blocking)
kernel_report(syrk_tiled!, (Matrix{Float64},))   # intensity ≈ 1.3 → balanced
kernel_report(syrk_tiled!, (Matrix{Float64},); working_set_bytes = 8*512*512)
# → compute-bound with note about packing at this problem size
```
"""
function kernel_report(@nospecialize(f), @nospecialize(types::Tuple);
                       working_set_bytes::Union{Nothing,Int} = nothing)
    target = _func_name(f) * _sig_string(types)
    s = _llvm_ir(f, types)
    isempty(s) && return KernelReport(target, false, 0, 0, 0, 0.0, 0, 0, working_set_bytes, 0, 0, 0, 0, 0)
    width = maximum((parse(Int, m[1]) for m in eachmatch(r"<(\d+) x (?:float|double|half|i\d+)>", s)); init = 0)
    vop(p) = count(_ -> true, eachmatch(Regex(p * raw" <\d+ x (?:float|double|half)>"), s))
    fma = count(_ -> true, eachmatch(r"@llvm\.(?:fmuladd|fma)\.v\d+", s))
    fp = vop("fmul") + vop("fadd") + vop("fsub") + vop("fdiv") + fma
    mem = count(_ -> true, eachmatch(r"(?:load|store) <\d+ x (?:float|double|half)>", s))
    intensity = mem == 0 ? (fp == 0 ? 0.0 : Inf) : fp / mem
    # F13 — alignment signal: count vector loads/stores where recorded align < vector width in bytes
    _elem_bytes = Dict("double" => 8, "float" => 4, "half" => 2)
    unaligned = 0
    for m in eachmatch(r"(?:load|store) <(\d+) x (float|double|half)>.*?align (\d+)", s)
        vb = parse(Int, m[1]) * get(_elem_bytes, m[2], 8)
        parse(Int, m[3]) < vb && (unaligned += 1)
    end
    # F13 — masking signal: @llvm.masked.* → variable-length / remainder tiles
    masked = count(_ -> true, eachmatch(r"@llvm\.masked\.(load|store|gather|scatter)", s))
    # F22 — integer vector ops: arithmetic on <N x iN>
    ivop(p) = count(_ -> true, eachmatch(Regex(p * raw" <\d+ x i\d+>"), s))
    int_arith = ivop("add") + ivop("sub") + ivop("mul") + ivop("and") + ivop("or") +
                ivop("xor") + ivop("shl") + ivop("lshr") + ivop("ashr")
    int_icmp_count = count(_ -> true, eachmatch(r"icmp \w+ <\d+ x i\d+>", s))
    int_ops_val = int_arith + int_icmp_count
    int_mem_val = count(_ -> true, eachmatch(r"(?:load|store) <\d+ x i\d+>", s))
    # F24 — conditional branches coexisting with vector ops: mispredict risk
    branch_count_val = width > 0 ? count(_ -> true, eachmatch(r"\bbr i1\b", s)) : 0
    # F28 — serial dep: high-latency op (div/rem/sqrt/fdiv) in a function with a loop-carried phi
    has_loop_phi = occursin(r"\bphi i(?:8|16|32|64|128)\b", s)
    high_lat = count(_ -> true, eachmatch(r"\b(?:s|u)div\b|\b(?:s|u)rem\b|\b@llvm\.sqrt\b", s))
    serial_dep_val = has_loop_phi ? high_lat : 0
    # F29 — noalias missing: pointer params in the define line without noalias attribute.
    # Julia 1.12+ emits opaque `ptr` types. The first line is a comment; search for "define".
    define_line = let found = ""
        for l in eachline(IOBuffer(s))
            startswith(l, "define") && (found = l; break)
        end
        found
    end
    # Count `ptr` tokens only in the parameter section (after the first `(`).
    param_section = let idx = findfirst('(', define_line)
        idx === nothing ? "" : define_line[idx:end]
    end
    total_ptr = count(_ -> true, eachmatch(r"\bptr\b", param_section))
    noalias_ptr = count(_ -> true, eachmatch(r"\bnoalias\b", param_section))
    noalias_missing_val = max(0, total_ptr - noalias_ptr)
    return KernelReport(target, width > 0, width, fp, mem, intensity, unaligned, masked, working_set_bytes, int_ops_val, int_mem_val, branch_count_val, serial_dep_val, noalias_missing_val)
end

# --- F20: scalar FP loop scan — best-effort whole-function detection --------------------------
#
# `@assert_vectorized` audits only kernels you point it at. A scalar floating-point loop in
# the "glue" between audited kernels can silently dominate runtime. `scalar_fp_loops` scans
# the optimized LLVM IR for the co-presence of a loop back-edge (`!llvm.loop` metadata or a
# labeled branch) and scalar (non-vector) FP arithmetic on `double`/`float`.

# Scalar FP op patterns in optimized IR (non-vector forms only).
const _SCALAR_FP_RE = r"(?:fadd|fmul|fsub|fdiv) double|(?:fadd|fmul|fsub|fdiv) float|call double @llvm\.(?:fma|fmuladd)\.f64|call float @llvm\.(?:fma|fmuladd)\.f32"

# Loop-carried FP accumulator: a `phi double`/`phi float` node indicates a loop with a
# loop-carried FP variable. More portable than `!llvm.loop` (which LLVM emits inconsistently
# across Julia versions and opt levels).
const _LOOP_RE = r"\bphi (?:double|float)\b"

# F22 — scalar integer loop indicators
const _SCALAR_INT_RE = r"\b(?:add|sub|mul|and|or|xor|shl|lshr|ashr) i(?:8|16|32|64)\b"
const _LOOP_INT_RE   = r"\bphi i(?:8|16|32|64)\b"

"""
    scalar_fp_loops(f, types::Tuple) -> Bool

**Best-effort** detection: returns `true` if `f`'s optimized LLVM IR shows a loop (back-edge
branch tagged with `!llvm.loop`) alongside scalar (non-`<N x>` vector) floating-point
arithmetic on `double`/`float`, AND the function did not vectorize as a whole.

This is intentionally coarse — it operates on text IR, not a structured IR graph. The loop
indicator is the presence of a `phi double`/`phi float` node (a loop-carried FP accumulator);
this is more portable than `!llvm.loop` metadata, which LLVM emits inconsistently across
optimization levels. A false-negative is possible when the optimizer eliminates all loop-carried
FP variables (e.g. pure store loops, full unrolls with no accumulator). Use it as a triage
signal: a `true` result means "look here for a vectorization opportunity"; a `false` result does
not prove every loop is vectorized. See [`@assert_vectorized`](@ref) for per-kernel vectorization
enforcement and [`@assert_no_scalar_loops`](@ref) for the guarded form.
"""
function scalar_fp_loops(@nospecialize(f), @nospecialize(types::Tuple))::Bool
    s = _llvm_ir(f, types)
    isempty(s) && return false
    _vectorized(f, types) && return false
    (occursin(_LOOP_RE, s) && occursin(_SCALAR_FP_RE, s)) ||
    (occursin(_LOOP_INT_RE, s) && occursin(_SCALAR_INT_RE, s))
end

function _assert_no_scalar_loops(target, @nospecialize(f), @nospecialize(types::Tuple))
    scalar_fp_loops(f, types) || return nothing
    _fail(
        :no_scalar_loops, target,
        "scalar hot loop (FP or integer) detected in a numeric path that did not vectorize. " *
        "Wrap the hot loop in a separate kernel and annotate it with `@assert_vectorized` / " *
        "`@kernel`, or add `@inbounds @simd` / SIMD.jl to the loop body."
    )
    return nothing
end

"""
    @assert_no_scalar_loops f(args...)

Fail if `f(args...)` contains a **scalar hot loop (FP or integer)** that did not vectorize
(**best-effort** IR scan). A scalar hot loop between two audited kernels can silently dominate
runtime — this macro surfaces it.

On failure, the message names the target and instructs you to either wrap the loop in a kernel
annotated with [`@assert_vectorized`](@ref) / [`@kernel`](@ref), or add `@inbounds @simd` /
SIMD.jl. The detection is coarse — it scans LLVM text IR for a loop back-edge and scalar
FP ops — so a `false` result does not guarantee every loop vectorized. Disabled builds expand
to the bare call.

```julia
@assert_no_scalar_loops apply_T!(Y, T, W)   # throws if TᵀW is a scalar triple-loop
```
"""
macro assert_no_scalar_loops(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)
    checked = quote
        $(binds...)
        local _val = $litcall
        $(_assert_no_scalar_loops)($target, $fe, $types)
        _val
    end
    return _gate(checked, esc(call))
end

function Base.show(io::IO, r::KernelReport)
    printstyled(io, "KernelReport"; bold = true)
    print(io, ": ", r.target, "\n")
    if !r.vectorized
        printstyled(io, "  not vectorized"; color = :red)
        print(io, " — no `<N x …>` ops (see `@assert_vectorized`).")
        return
    end
    printstyled(io, "  vectorized"; color = :green)
    print(io, " — `<", r.width, " x>`\n")
    print(
        io, "  FP vector ops : memory vector ops = ", r.fp_ops, " : ", r.mem_ops,
        "  → arithmetic intensity ", round(r.intensity; digits = 2), "\n"
    )
    if r.fp_ops == 0 && r.int_ops > 0
        int_intensity = r.int_mem_ops > 0 ? r.int_ops / r.int_mem_ops : Inf
        print(io, "  integer vector ops : integer memory ops = ", r.int_ops, " : ", r.int_mem_ops,
              "  → integer intensity ", round(int_intensity; digits = 2), "\n")
    end
    b = _kr_bound(r)
    if b === :memory
        printstyled(io, "  → memory-bound"; color = :yellow)
        print(
            io, ": streams more than it computes. Reuse loaded vectors across more FMAs ",
            "(register blocking) and tile the reduction dimension (cache blocking)."
        )
    elseif b === :balanced
        printstyled(io, "  → balanced"; color = :cyan)
        print(io, ": some data reuse; more register/cache blocking may still help.")
    else
        printstyled(io, "  → compute-bound"; color = :green)
        print(io, ": good FLOP:byte balance.")
    end
    # F13 alignment hint
    if r.unaligned_mem_ops > 0
        print(io, "\n")
        printstyled(io, "  unaligned vector memory ops: $(r.unaligned_mem_ops)"; color = :yellow)
        print(io, " — recorded alignment < vector width; may stall on wide SIMD. Ensure buffers are $(r.width * 8)-byte aligned.")
    end
    if r.masked_mem_ops > 0
        print(io, "\n")
        printstyled(io, "  masked/variable-length ops: $(r.masked_mem_ops)"; color = :yellow)
        print(io, " — loop has irregular trip counts (remainder masking). Prefer fixed-width tiles.")
    end
    # F24 branch mispredict risk
    if r.branch_count > 0 && r.vectorized
        print(io, "\n")
        printstyled(io, "  conditional branches: $(r.branch_count)"; color = :yellow)
        print(io, " — data-dependent branches in a vectorized kernel are mispredict candidates. Consider branchless alternatives: `ifelse`, predication, or lookup tables.")
    end
    # F28 serial dep chain risk
    if r.serial_dep_count > 0
        print(io, "\n")
        printstyled(io, "  serial high-latency ops: $(r.serial_dep_count)"; color = :yellow)
        print(io, " — div/rem/sqrt in a loop with a loop-carried variable creates a serial dependency chain. Break the chain: process multiple elements per step, or use division-free extraction (e.g. jeaiii-style).")
    end
    # F29 noalias missing
    if r.noalias_missing_count > 0 && r.vectorized
        print(io, "\n")
        printstyled(io, "  noalias missing: $(r.noalias_missing_count) pointer param(s)"; color = :yellow)
        print(io, " — LLVM may conservatively assume aliasing across iterations. Use `@simd ivdep` to assert no loop-carried deps, or restructure to pass by value.")
    end
    # F14/F15 cache-residency annotation
    if !isnothing(r.working_set_bytes)
        cb = _CACHE_BYTES[]
        ws = r.working_set_bytes
        level = ws ≤ cb.l1 ? "L1" : ws ≤ cb.l2 ? "L2" : ws ≤ cb.l3 ? "L3" : "DRAM"
        print(io, "\n  working set $(Base.format_bytes(ws)) → $level-resident. ")
        if level == "L1" || level == "L2"
            print(io, "Low intensity is acceptable at this size; memory-bound advice applies as n grows.")
        elseif _kr_bound(r) === :compute
            print(io, "Good register intensity, but working set spills $level — BLIS-style packing needed for the cache-locality leg (beyond per-kernel IR analysis).")
        else
            print(io, "Consider cache-blocking (tiling the reduction dimension) to reduce $level traffic.")
        end
    end
    return
end

# F31 — register saturation / spill diagnostic. Reads code_native (post-register-allocation
# assembly) rather than LLVM IR, so it captures what kernel_report cannot: physical zmm register
# count and stack spills. Only meaningful for x86-64 AVX-512; returns zeros for other targets.
struct RegisterReport
    target::String
    vec_regs_used::Int   # unique zmm registers seen (0 = no AVX-512)
    vec_regs_total::Int  # 32 for x86-64 AVX-512; 0 for unknown arch
    vec_spills::Int      # lines with both "zmm" and "rsp" (zmm saved to stack)
end

"""
    register_report(f, types) -> RegisterReport

Read the native assembly for `f` specialised on `types` and count zmm vector register usage
and stack spills. Complements [`kernel_report`](@ref): where `kernel_report` works from LLVM IR
(pre-register-allocation), `register_report` reads post-allocation `code_native`, so it captures
whether the kernel is register-saturated (all 32 zmm in use) and how many spills occurred.

A saturated kernel with spills (32/32, N > 0) is at the LLVM portable-compiler ceiling; adding
more ILP will only spill further and may regress. The last ~15% over LLVM-compiled Rust requires
hand-written assembly.

Only meaningful for x86-64 AVX-512 kernels; non-AVX-512 targets return zeros.
"""
function register_report(@nospecialize(f), @nospecialize(types::Tuple))
    target = _func_name(f) * _sig_string(types)
    s = _native_asm(f, types)
    isempty(s) && return RegisterReport(target, 0, 0, 0)
    zmm_regs = Set(m[1] for m in eachmatch(r"%zmm(\d+)\b", s))
    spills   = count(l -> occursin("zmm", l) && occursin("rsp", l), split(s, '\n'))
    total    = isempty(zmm_regs) ? 0 : 32
    return RegisterReport(target, length(zmm_regs), total, spills)
end

function Base.show(io::IO, r::RegisterReport)
    printstyled(io, "RegisterReport"; bold = true)
    print(io, ": ", r.target, "\n")
    if r.vec_regs_total == 0
        printstyled(io, "  no zmm"; color = :light_black)
        print(io, " — non-AVX-512 target or compilation failed.")
        return
    end
    saturated = r.vec_regs_used >= r.vec_regs_total
    print(io, "  $(r.vec_regs_used)/$(r.vec_regs_total) zmm registers, $(r.vec_spills) spill(s)")
    if saturated
        print(io, "\n")
        printstyled(io, "  → register-saturated"; color = :yellow)
        print(io, ": all $(r.vec_regs_total) zmm in use. Adding more ILP will spill and may regress. This is the LLVM portable-compiler ceiling (~85–87% of hand-asm).")
    elseif r.vec_spills > 0
        print(io, "\n")
        printstyled(io, "  → unexpected spills: $(r.vec_spills)"; color = :yellow)
        print(io, " — zmm registers saved to stack despite headroom. Reduce live register count or shrink the register tile.")
    else
        print(io, "\n")
        printstyled(io, "  → clean"; color = :green)
        print(io, ": $(r.vec_regs_total - r.vec_regs_used) zmm free — room for more ILP or a wider tile.")
    end
    return
end
