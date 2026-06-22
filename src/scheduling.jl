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

_kr_bound(r::KernelReport) =
    !r.vectorized ? :scalar : (r.intensity ≥ 2.0 ? :compute : (r.intensity ≥ 0.75 ? :balanced : :memory))

"""
    kernel_report(f, types) -> KernelReport

A **performance-quality diagnostic** for a numeric kernel — the layer *beneath* the pass/fail
guarantees. `@assert_vectorized`/`@assert_noalloc` confirm a loop is vectorized and allocation-free,
but say nothing about whether it's a *good* microkernel: a naive `Vec` loop and a register-blocked
one both pass them, yet can differ several-fold. `kernel_report` reads the **arithmetic intensity**
(FP vector ops : memory vector ops) from the LLVM IR, so a green-but-slow kernel can be *seen* to be
memory-bound — pointing straight at register/cache blocking rather than discovered by benchmarking.

Fields: `vectorized`, `width`, `fp_ops`, `mem_ops`, `intensity` (= `fp_ops/mem_ops`). **Heuristic
and advisory** — it never fails, and does not replace a profiler/roofline.

```julia
kernel_report(syrk_naive!, (Matrix{Float64},))   # intensity ≈ 0.7 → memory-bound (add blocking)
kernel_report(syrk_tiled!, (Matrix{Float64},))   # intensity ≈ 1.3 → balanced
```
"""
function kernel_report(@nospecialize(f), @nospecialize(types::Tuple))
    target = _func_name(f) * _sig_string(types)
    s = _llvm_ir(f, types)
    isempty(s) && return KernelReport(target, false, 0, 0, 0, 0.0)
    width = maximum((parse(Int, m[1]) for m in eachmatch(r"<(\d+) x (?:float|double|half)>", s)); init = 0)
    vop(p) = count(_ -> true, eachmatch(Regex(p * raw" <\d+ x (?:float|double|half)>"), s))
    fma = count(_ -> true, eachmatch(r"@llvm\.(?:fmuladd|fma)\.v\d+", s))
    fp = vop("fmul") + vop("fadd") + vop("fsub") + vop("fdiv") + fma
    mem = count(_ -> true, eachmatch(r"(?:load|store) <\d+ x (?:float|double|half)>", s))
    intensity = mem == 0 ? (fp == 0 ? 0.0 : Inf) : fp / mem
    return KernelReport(target, width > 0, width, fp, mem, intensity)
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
    return
end
