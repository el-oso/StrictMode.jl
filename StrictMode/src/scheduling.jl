# Surface & (partly) force the scheduling / vectorization layer — the residual gap vs Rust that
# lives *below* user code. StrictMode cannot match rustc's instruction scheduler (an explicit
# non-goal); what it can do is make that layer **visible** (`@assert_vectorized`, `@assert_effects`,
# `descend`) and **reachable** (the documented `@assume_effects` / `@simd ivdep` / `llvmcall`
# escape hatches). All of these use only Base + InteractiveUtils — no AllocCheck/JET backend.

# Best-effort: did the method's LLVM IR contain SIMD vector ops? (`<N x double>` & friends.)
#
# A compiler-generated forwarder stands between a call and the code it runs in two cases: a method
# with a default argument compiles its shorter call form to a body that calls the same function
# with the default filled in, and a method with keyword arguments compiles its positional entry to a
# body that calls the method's keyword body (`#f#N`) with the defaults. The checks read the body
# they are handed, so on either form they inspected no loop at all, and `@assert_no_spill` passed
# for want of anything to spill. The signature the forwarder calls is the one to read. The body must
# make no other call, and do nothing else either: no branch or loop, and no statement other than a
# pure read (`_FORWARDER_PURE`). Work that inlines makes no call — a loop of intrinsics, a store
# into a global — so counting calls alone read such a body as a forwarder and checked its callee
# instead. A body that does any real work, and a wrapper a user wrote, is read as itself.
function _forwarded_sig(@nospecialize(sig))
    for _ in 1:8                       # a chain of trailing defaults forwards once per default
        cts = try
            _code_typed_by_type(sig; optimize = true)
        catch
            return sig
        end
        length(cts) == 1 || return sig
        code = first(cts[1]).code
        ret = code[end]
        (ret isa Core.ReturnNode && isdefined(ret, :val)) || return sig
        # The one call the forwarder makes. Its result is returned, or — when the callee's return
        # type is a singleton such as `Nothing`, which a `!` kernel usually returns — inference
        # replaces the returned value with that constant and the call's result goes unused.
        calls = [j for (j, s) in enumerate(code) if Meta.isexpr(s, :invoke) || Meta.isexpr(s, :foreigncall)]
        length(calls) == 1 || return sig
        j = only(calls)
        all(k -> k == j || k == length(code) || _forwarder_trivial(code[k]), eachindex(code)) || return sig
        st = code[j]
        Meta.isexpr(st, :invoke) || return sig
        v = ret.val
        (v == Core.SSAValue(j) || !(v isa Core.SSAValue || v isa Core.Argument || v isa Core.SlotNumber)) ||
            return sig
        mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
        mi isa Core.MethodInstance || return sig
        target = mi.specTypes
        # A callee whose signature dispatches to another method, as an `invoke` of a wider method
        # names, is not one a forwarder calls, and reading its signature would read that other method.
        _callee_key(mi) === target || return sig
        callee = target.parameters[1]
        callee === sig.parameters[1] || _is_kwbody_of(callee, sig) || return sig
        sig = target
    end
    return sig
end

# Statements a compiler-generated forwarder can hold besides its one call: values, renames, and the
# side-effect-free reads that unpack a keyword `NamedTuple` or build an argument tuple.
const _FORWARDER_PURE = (:getfield, :tuple, :isdefined, :(===), :typeassert, :isa, :fieldtype)

function _forwarder_trivial(@nospecialize(s))
    (isnothing(s) || s isa Core.SSAValue || s isa Core.Argument || s isa Core.PiNode ||
        s isa QuoteNode || s isa GlobalRef) && return true
    s isa Expr || return false                    # a GotoNode, GotoIfNot or PhiNode is control flow
    s.head === :call || return false
    c = s.args[1]
    c isa GlobalRef || return false
    return (c.mod === Core || c.mod === Base) && c.name in _FORWARDER_PURE
end

# Whether `callee` is the keyword body (`#f#N`) of the method `sig` dispatches to, recognized by its
# name. `Base.bodyfunction` is not used: it returns the last function a method calls, so on a body
# method it names an ordinary callee, and following that reads the callee with the caller's own
# values arriving as arguments — the escape analysis then sees a handle passed in rather than made.
function _is_kwbody_of(@nospecialize(callee), @nospecialize(sig))
    (callee isa DataType && isdefined(callee, :instance)) || return false
    cn = nameof(callee.instance)
    startswith(string(cn), "#") || return false
    m = try
        Base.which(sig)
    catch
        return false
    end
    return m isa Method && _demangle(cn) === m.name
end

# The function and argument types a check should read for the call `f(types...)`.
function _forwarded_call(@nospecialize(f), @nospecialize(types::Tuple))
    sig = _sigtype(f, types)
    fsig = _forwarded_sig(sig)
    fsig === sig && return (f, types)
    ft = fsig.parameters[1]
    ft isa DataType || return (f, types)
    return (_callee(ft), Tuple(fsig.parameters[2:end]))
end

_forwarded_types(@nospecialize(f), @nospecialize(types::Tuple)) = last(_forwarded_call(f, types))

_vectorized(@nospecialize(f), @nospecialize(types::Tuple)) = _ir_vectorized(_llvm_ir(f, types))

# An in-order floating-point reduction: `@llvm.vector.reduce.fadd`/`fmul` called without `reassoc`
# or `fast`. LLVM's loop vectorizer emits it for a strict (non-`@simd`) accumulation on targets
# that allow ordered reductions (AArch64). It compiles to one scalar operation per lane, chained
# through the accumulator (`fadd d0, d0, d1` on NEON, `fadda` on SVE): scalar arithmetic on
# vector-loaded data.
const _ORDERED_REDUCE = raw"call(?: (?!reassoc\b|fast\b)[a-z]+)* (?:double|float|half) @llvm\.vector\.reduce\.f(?:add|mul)\."
const _ORDERED_REDUCE_RE = Regex(_ORDERED_REDUCE)

# A vector type in text IR, fixed (`<2 x double>`) or scalable (`<vscale x 2 x double>`, SVE/SME).
const _VEC_ELT_RE = r"<(?:vscale x )?\d+ x (?:float|double|half|i\d+)>"

# Statements that name a vector type and do no vector work: a load, a lane extraction, a phi,
# and an in-order reduction.
const _NOT_VECTOR_WORK_RE = Regex(raw"= (?:load|extractelement|phi) <|" * _ORDERED_REDUCE)

# Whether text IR holds vector work: a statement naming a vector type (`vec_re`) other than those
# of `_NOT_VECTOR_WORK_RE`. Vector loads alone are not vector work, because a loop that loads
# `<2 x double>` and feeds it to an in-order reduction adds one lane at a time.
_vector_work(ir::AbstractString, vec_re::Regex) =
    any(l -> occursin(vec_re, l) && !occursin(_NOT_VECTOR_WORK_RE, l), eachsplit(ir, '\n'))

# Whether one loop region vectorized. A loop whose accumulation is an in-order reduction did not,
# whatever else it holds: its vector multiplies feed a chain of scalar adds, which sets its speed.
# x86 leaves the same source loop entirely scalar, so both targets give it one verdict.
_loop_vectorized(r::AbstractString) = _vector_work(r, _VEC_RE) && !occursin(_ORDERED_REDUCE_RE, r)

# Whether a whole body vectorized: vector work somewhere outside the loops that reduce in order.
# An enclosing loop is dropped together with the in-order loop nested in it.
function _ir_vectorized(ir::AbstractString)
    for r in _loop_regions(ir)
        occursin(_ORDERED_REDUCE_RE, r) && (ir = replace(ir, r => ""))
    end
    return !occursin(_ORDERED_REDUCE_RE, ir) && _vector_work(ir, _VEC_ELT_RE)
end

# Names of the non-inlined callees (`:invoke` targets) in `f`'s optimized body — where SIMD may
# live if it isn't in `f` itself (a thin dispatcher). Used to make `@assert_vectorized`'s failure
# point at the leaf kernels.
function _invoke_callees(@nospecialize(f), @nospecialize(types::Tuple))
    out = String[]
    cts = try
        _code_typed(f, Tuple{types...}; optimize = true)
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
    ir = _llvm_ir(f, types)
    isempty(ir) && return _fail(:vectorized, target, _output_unread(f, types))
    _ir_vectorized(ir) && return nothing
    # `@assert_vectorized` inspects the *leaf* compiled body. A thin dispatcher has no vector ops of
    # its own — point the user at the non-inlined callees where the SIMD actually is (F11).
    callees = _invoke_callees(f, types)
    hint = isempty(callees) ? "" :
        " The SIMD may be in non-inlined callee(s) — assert on those directly: $(join(callees, ", "))."
    _fail(
        :vectorized, target,
        "no vector arithmetic in this method body: no `<N x …>` ops outside loads and loops that reduce in order (best-effort)." * hint *
            " (Try `@inbounds @simd`/`@simd ivdep`, or `descend` to see why.)"
    )
    return nothing
end

"""
    @assert_vectorized f(args...)

Fail unless `f(args...)` compiled to SIMD vector instructions (**best-effort**): StrictMode scans
the method's LLVM IR for operations on vector types (`<N x …>`). A vector load does not count, and
neither does a loop whose accumulation is an in-order reduction (`@llvm.vector.reduce.fadd` without
`reassoc`, which AArch64 emits for a strict accumulation), even one that also multiplies vectors: it
adds one lane at a time. A failure means the compiler did not vectorize
the loop under the current settings — informative, not a proof, so it is **not** part of
[`@strict`](@ref). Each argument is evaluated once; disabled builds expand to the bare call.

It inspects the **leaf compiled body**: a thin dispatcher that forwards to non-inlined kernels has
no vector ops of its own, so assert on the kernels where the SIMD lives (the failure message names
the non-inlined callees to help). See also [`kernel_report`](@ref) for *why-not-fast-enough*
diagnostics when a loop vectorizes but is still slow.

```julia
@assert_vectorized simd_dot(a, b)   # ok: emits <N x double>
@assert_vectorized branchy(a)      # throws: a data-dependent branch blocked vectorization
```
"""
macro assert_vectorized(args...)
    pos, opts = _macro_call("@assert_vectorized", args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_vectorized needs a call expression"))
    call = pos[1]
    checked = _guarantee_expr(call, _assert_vectorized; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
end

# --- @assert_effects (via Base.infer_effects) -------------------------------------------------

function _assert_effects(target, @nospecialize(f), @nospecialize(types::Tuple), required)
    isnothing(_typed_body(_sigtype(f, types))) && return _fail(:effects, target, _NO_BODY_WHY)
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
`:terminates`, `:consistent`, `:nonoverlayed`, `:notaskstate`, `:noub`, `:inaccessiblememonly` and
`:nortcall`. A signature no method matches fails: there is no code to have effects. This is the *verify* side of effects; to *declare*
them (and influence codegen), use `Base.@assume_effects`. Each argument is evaluated once.

```julia
@assert_effects dot3(a, b) (:nothrow, :effect_free)   # ok if the compiler agrees
```
"""
macro assert_effects(args...)
    pos, opts = _macro_call("@assert_effects", args, (:types,))
    length(pos) >= 2 || throw(ArgumentError("@assert_effects needs a call expression and a required-effects tuple"))
    call, required = pos[1], pos[2]
    checked = _guarantee_expr(call, _assert_effects, esc(required); types = get(opts, :types, nothing))
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

Base.@kwdef struct KernelReport
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
    working_set_bytes::Union{Nothing, Int}   # user-supplied; enables cache-residency annotation
    # F22
    int_ops::Int        # vector integer arithmetic ops (add/sub/mul/and/or/xor/shl/icmp on <N x iN>)
    int_mem_ops::Int    # vector integer loads + stores
    # F24
    branch_count::Int   # conditional branches (br i1) coexisting with vector ops — mispredict risk (F24)
    # F28
    serial_dep_count::Int # high-latency ops (div/rem/sqrt) in functions with loop-carried phi — serialization risk (F28)
    # F29
    noalias_missing_count::Int  # pointer params without noalias in LLVM IR define line — aliasing risk (F29)
    # F33
    shuffle_ops::Int            # shufflevector + x86 shuffle/permute/pshufb/palignr intrinsics — port-5 work
    # F34
    prefetch_ops::Int           # @llvm.prefetch count (its absence in a low-intensity loop ⇒ maybe latency-bound)
    has_loop_phi::Bool          # loop-carried integer phi present (the loop check for the latency-bound hint)
    # F38 — FP ops carrying fast-math flags (contract/reassoc/nnan/ninf/nsz/arcp/afn/fast): `@simd`/
    # `@fastmath` permit floating-point reassociation and NaN/Inf assumptions that can change
    # numerical results, not just speed — surfaced explicitly rather than silently folded into `fp_ops`.
    fastmath_ops::Int
    # In-order FP reductions (`_ORDERED_REDUCE_RE`): scalar accumulation over vector-loaded data.
    # Not part of `fp_ops`. A loop holding one is not vectorized.
    ordered_reduce_ops::Int = 0
end

# A call runs the code compiled for its concrete argument types. For a signature that is not
# concrete, `code_llvm` and `code_native` print the matching method compiled for the abstract types
# (under "WARNING: This code may not match what actually runs"): one method's body, dispatching at
# run time where the abstract types leave a call open, and not the code any concrete call runs.
# `_llvm_ir` and `_native_asm` therefore return "" for it, as they do when the printer raises, and a
# guarantee reports an empty text as unevaluated (`_output_unread`), never as a pass or a failure.
#
# The signature judged is the one asked about, not the one read. A forwarder is read at its
# callee's compilation signature, which widens an argument the callee does not specialize on and is
# still the code the call runs.
function _has_compiled_body(@nospecialize(f), @nospecialize(types::Tuple))
    return try
        Base.isdispatchtuple(_sigtype(f, types))
    catch
        false
    end
end

# Why `_llvm_ir` or `_native_asm` came back empty for `f(types...)`.
_output_unread(@nospecialize(f), @nospecialize(types::Tuple)) =
    _has_compiled_body(f, types) ?
    "the compiled output could not be read (`code_llvm` / `code_native` raised or printed nothing)" :
    "the signature is not concrete, so it names no compiled body to read; give the argument " *
    "types a call would have"

# `code_llvm` (`native = false`) or `code_native` for a signature, with the keywords `_llvm_ir` and
# `_native_asm` pass. Julia 1.12's printers take a function value only, so there this is their body
# with the method instance found by the signature.
@static if VERSION >= v"1.13.0-"
    _print_code_by_type(io::IO, @nospecialize(tt), native::Bool) = native ?
        InteractiveUtils.code_native(io, tt; debuginfo = :none) :
        InteractiveUtils.code_llvm(io, tt; debuginfo = :none, optimize = true)
else
    function _print_code_by_type(io::IO, @nospecialize(tt), native::Bool)
        world = Base.get_world_counter()
        mi = Base.specialize_method(Base._which(tt; world))
        src = Base.Compiler.typeinf_code(Base.Compiler.NativeInterpreter(world), mi, true)
        src isa Core.CodeInfo || error("failed to infer source for $mi")
        params = Base.CodegenParams(;
            debug_info_kind = Cint(0), debug_info_level = Cint(2), safepoint_on_entry = false, gcstack_arg = false
        )
        IU = InteractiveUtils
        print(
            io, native ? IU._dump_function_native_assembly(mi, src, false, :intel, :none, false, false, params) :
                IU._dump_function_llvm(mi, src, false, true, false, true, :none, params)
        )
        return nothing
    end
end

function _llvm_ir(@nospecialize(f), @nospecialize(types::Tuple))
    _has_compiled_body(f, types) || return ""
    f, types = _forwarded_call(f, types)
    io = IOBuffer()
    try
        f isa _Callable ? _print_code_by_type(io, _sigtype(f, types), false) :
            InteractiveUtils.code_llvm(io, f, types; debuginfo = :none, optimize = true)
    catch
        return ""
    end
    return String(take!(io))
end

function _native_asm(@nospecialize(f), @nospecialize(types::Tuple))
    _has_compiled_body(f, types) || return ""
    f, types = _forwarded_call(f, types)
    io = IOBuffer()
    try
        f isa _Callable ? _print_code_by_type(io, _sigtype(f, types), true) :
            InteractiveUtils.code_native(io, f, types; debuginfo = :none)
    catch
        return ""
    end
    return String(take!(io))
end

# The text a public report is built from, or a raise. A report built from no text shows zero
# spills, no scalar loop and no vector work, which is how a clean kernel reads.
function _report_text(
        reader, report::Symbol, @nospecialize(f), @nospecialize(types::Tuple)
    )
    s = reader(f, types)
    isempty(s) && throw(_UnanalyzableSignature(report, f, types, _output_unread(f, types)))
    return s
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
    # F33 — shuffle-port-bound: several shuffles with low arithmetic intensity ⇒ the bottleneck is the
    # shuffle port (vpshufb/vperm, ~1/cycle), not FLOP:byte. The `shuffle_ops >= fp_ops` + `eff < 2.0`
    # guards keep a transpose-heavy *compute* kernel (high intensity) classified as :compute.
    if r.shuffle_ops >= 2 && r.shuffle_ops >= r.fp_ops && eff < 2.0
        return :shuffle
    end
    eff >= 2.0 && return :compute
    eff >= 0.75 && return :balanced
    return :memory
end

# Defaults; overwritten at load time by StrictModeCpuIdExt when `using CpuId` is in scope.
# Override for non-standard hardware: StrictMode._CACHE_BYTES[] = (l1=…, l2=…, l3=…)
const _CACHE_BYTES = Ref((l1 = 32_768, l2 = 524_288, l3 = 16_777_216))

# Robust ingest of a `CpuId.cachesize()` result. On CPUs CpuId doesn't recognize (brand-new models like
# EPYC 9455/Zen5, or VMs/hypervisors that mask the deterministic-cache CPUID leaf) `cachesize()` returns
# an EMPTY tuple `()`. The extension's __init__ must NOT blindly destructure it (`l1,l2,l3 = cachesize()`
# → BoundsError, which crashes the whole ext load and takes `using CpuId`/downstream packages down with
# it). Guard: keep the safe default unless we got ≥3 positive sizes. Returns whether it applied (for tests).
function _set_cache_bytes!(cs)
    (length(cs) >= 3 && cs[1] > 0 && cs[2] > 0) || return false
    _CACHE_BYTES[] = (l1 = Int(cs[1]), l2 = Int(cs[2]), l3 = Int(cs[3]))
    return true
end

# The extension's whole `__init__` body, lifted here so it is TESTABLE ON ANY ARCH.
#
# `cachesize()` does not only return `()` on CPUs CpuId cannot describe — on a host with no cache
# leaves at all it THROWS (`_throw_unsupported_leaf`), because CpuId's non-x86 `cpuid` is an
# all-zeros stub. That is every aarch64 host. An exception out of an extension `__init__` is fatal
# during precompilation, so it made StrictMode+CpuId dependents uninstallable on Apple Silicon.
#
# Taking the probe as a FUNCTION rather than calling `cachesize()` inline is the point: a throwing
# probe can then be injected from a test running on x86 CI, which otherwise cannot reach this path at
# all (a real `cachesize()` only throws on non-x86 hardware). Returns whether the sizes were applied.
function _init_cache_bytes(probe)
    return try
        _set_cache_bytes!(probe())
    catch err
        @debug "StrictMode: cache-size probe unavailable on this CPU (expected on any non-x86 \
                host); keeping the defaults." exception = (err, catch_backtrace())
        false
    end
end

# LLVM inserts fast-math flags (`fast`, `nnan`, `ninf`, `nsz`, `arcp`, `contract`, `afn`,
# `reassoc`) between a floating-point opcode/call and its result type whenever
# `@fastmath`/`@simd`-style reassociation is proven safe — e.g. `fmul contract <8 x double>`,
# `fadd reassoc contract double`, `call reassoc contract double @llvm.fmuladd.f64(...)`. A regex
# anchored on opcode-immediately-followed-by-type misses every flagged op, which silently
# undercounts FP work and can misclassify a compute-bound `@simd` kernel as memory-bound — the
# exact misdiagnosis `kernel_report` exists to prevent. This fragment absorbs zero or more such
# flag tokens wherever an FP opcode/call precedes its type.
const _FMF = raw"(?: [a-z]+)*"
# One-or-more form: requires a fast-math flag to actually be present, for F38's explicit
# fast-math-usage count (as opposed to `_FMF`'s zero-or-more, used to count FP work regardless of
# whether it carries these flags).
const _FMF1 = raw"(?: [a-z]+)+"

"""
    kernel_report(f, types) -> KernelReport

A **performance-quality diagnostic** for a numeric kernel — the layer *beneath* the pass/fail
guarantees. `@assert_vectorized`/`@assert_noalloc` confirm a loop is vectorized and allocation-free,
but say nothing about whether it's a *good* microkernel: a naive `Vec` loop and a register-blocked
one both pass them, yet can differ several-fold. `kernel_report` reads the **arithmetic intensity**
(FP vector ops : memory vector ops) from the LLVM IR, so a green-but-slow kernel can be *seen* to be
memory-bound — pointing straight at register/cache blocking rather than discovered by benchmarking.

Fields: `vectorized`, `width`, `fp_ops`, `mem_ops`, `intensity` (= `fp_ops/mem_ops`),
`ordered_reduce_ops` (in-order `@llvm.vector.reduce.fadd`/`fmul` calls — scalar accumulation over
vector-loaded data, which AArch64 emits for a strict reduction; never part of `fp_ops`, and a loop
holding one is not `vectorized`, whatever vector arithmetic feeds it),
`unaligned_mem_ops` (vector loads/stores with alignment < vector width — a proxy for unaligned
access), `masked_mem_ops` (masked/variable-length memory ops — a proxy for irregular trip counts),
`fastmath_ops` (FP ops carrying `contract`/`reassoc`/`nnan`/`ninf`/`nsz`/`arcp`/`afn`/`fast` flags —
from `@simd`/`@fastmath` — counted into `fp_ops` like any other FP work, but also reported
separately and printed as an explicit warning: these flags permit floating-point reassociation and
NaN/Inf assumptions that can change numerical RESULTS, not just codegen, so a nonzero count is a
numerics-risk signal worth a second look, not just a tuning note).
**Heuristic and advisory** — it judges nothing, and does not replace a profiler/roofline. IR that
cannot be read raises `_UnanalyzableSignature`, naming the signature and the reason, rather than
returning a report of zeros: that is the case for a signature that is not concrete.

Pass `working_set_bytes` to get a cache-residency annotation: if the working set fits L1/L2,
low intensity is expected and acceptable; if it spills L2 and the kernel is already
compute-bound, the report notes the cache-blocking (packing) gap that per-kernel IR analysis
cannot close.

```julia
kernel_report(syrk_naive!, (Matrix{Float64},))   # intensity ≈ 0.7 → memory-bound (add blocking)
kernel_report(syrk_tiled!, (Matrix{Float64},))   # intensity ≈ 1.3 → balanced
kernel_report(syrk_tiled!, (Matrix{Float64},); working_set_bytes = 8*512*512)
# → compute-bound with note about packing at this problem size
```
"""
function kernel_report(
        @nospecialize(f), @nospecialize(types::Tuple);
        working_set_bytes::Union{Nothing, Int} = nothing
    )
    return _kernel_report(
        _func_name(f) * _sig_string(types), _report_text(_llvm_ir, :kernel_report, f, types),
        working_set_bytes
    )
end

# `kernel_report` over text IR: the classification depends on the IR alone, so IR captured on one
# target can be classified on another.
function _kernel_report(target, s::AbstractString, working_set_bytes)
    isempty(s) && return KernelReport(;
        target, vectorized = false, width = 0, fp_ops = 0, mem_ops = 0, intensity = 0.0,
        unaligned_mem_ops = 0, masked_mem_ops = 0, working_set_bytes,
        int_ops = 0, int_mem_ops = 0, branch_count = 0, serial_dep_count = 0,
        noalias_missing_count = 0, shuffle_ops = 0, prefetch_ops = 0, has_loop_phi = false,
        fastmath_ops = 0
    )
    width = maximum((parse(Int, m[1]) for m in eachmatch(r"<(?:vscale x )?(\d+) x (?:float|double|half|i\d+)>", s)); init = 0)
    vop(p) = count(_ -> true, eachmatch(Regex(p * _FMF * raw" <(?:vscale x )?\d+ x (?:float|double|half)>"), s))
    fma = count(_ -> true, eachmatch(r"@llvm\.(?:fmuladd|fma)\.(?:nx)?v\d+", s))
    fp = vop("fmul") + vop("fadd") + vop("fsub") + vop("fdiv") + fma
    mem = count(_ -> true, eachmatch(r"(?:load|store) <(?:vscale x )?\d+ x (?:float|double|half)>", s))
    intensity = mem == 0 ? (fp == 0 ? 0.0 : Inf) : fp / mem
    # F13 — alignment signal: count vector loads/stores where recorded align < vector width in bytes
    _elem_bytes = Dict("double" => 8, "float" => 4, "half" => 2)
    unaligned = 0
    for m in eachmatch(r"(?:load|store) <(?:vscale x )?(\d+) x (float|double|half)>.*?align (\d+)", s)
        vb = parse(Int, m[1]) * get(_elem_bytes, m[2], 8)
        parse(Int, m[3]) < vb && (unaligned += 1)
    end
    # F13 — masking signal: @llvm.masked.* → variable-length / remainder tiles
    masked = count(_ -> true, eachmatch(r"@llvm\.masked\.(load|store|gather|scatter)", s))
    # F22 — integer vector ops: arithmetic on <N x iN>
    ivop(p) = count(_ -> true, eachmatch(Regex(p * raw" <(?:vscale x )?\d+ x i\d+>"), s))
    int_arith = ivop("add") + ivop("sub") + ivop("mul") + ivop("and") + ivop("or") +
        ivop("xor") + ivop("shl") + ivop("lshr") + ivop("ashr")
    int_icmp_count = count(_ -> true, eachmatch(r"icmp \w+ <(?:vscale x )?\d+ x i\d+>", s))
    int_ops_val = int_arith + int_icmp_count
    int_mem_val = count(_ -> true, eachmatch(r"(?:load|store) <(?:vscale x )?\d+ x i\d+>", s))
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
    # F33 — shuffle/permute ops: the work of byte-transcoding/validation kernels, invisible to fp/int counts
    shuffle_val = count(_ -> true, eachmatch(r"shufflevector <\d+ x", s)) +
        count(_ -> true, eachmatch(r"@llvm\.x86\.\w+\.(?:pshuf\.?b?|perm[di]?|palignr|valign)", s))
    # F34 — prefetch presence; its absence in a low-intensity streaming loop ⇒ possibly latency-bound
    prefetch_val = count(_ -> true, eachmatch(r"@llvm\.prefetch", s))
    # F38 — fast-math-flagged FP op count (see `_FMF1` above): `@simd`/`@fastmath` change floating-
    # point semantics (reassociation, NaN/Inf assumptions), not just codegen — worth a standing
    # warning independent of the (unaffected) intensity/bound classification.
    vopf(p) = count(_ -> true, eachmatch(Regex(p * _FMF1 * raw" <(?:vscale x )?\d+ x (?:float|double|half)>"), s))
    scalarf(p) = count(_ -> true, eachmatch(Regex(p * _FMF1 * raw" (?:double|float)\b"), s))
    fastmath_val = vopf("fmul") + vopf("fadd") + vopf("fsub") + vopf("fdiv") +
        scalarf("fmul") + scalarf("fadd") + scalarf("fsub") + scalarf("fdiv") +
        count(_ -> true, eachmatch(Regex(raw"call" * _FMF1 * raw" (?:double|float) @llvm\.(?:fma|fmuladd)"), s))
    return KernelReport(;
        target, vectorized = _ir_vectorized(s), width, fp_ops = fp, mem_ops = mem, intensity,
        unaligned_mem_ops = unaligned, masked_mem_ops = masked, working_set_bytes,
        int_ops = int_ops_val, int_mem_ops = int_mem_val, branch_count = branch_count_val,
        serial_dep_count = serial_dep_val, noalias_missing_count = noalias_missing_val,
        shuffle_ops = shuffle_val, prefetch_ops = prefetch_val, has_loop_phi,
        fastmath_ops = fastmath_val,
        ordered_reduce_ops = count(_ -> true, eachmatch(_ORDERED_REDUCE_RE, s))
    )
end

# --- F20: scalar FP loop scan — best-effort whole-function detection --------------------------
#
# `@assert_vectorized` audits only kernels you point it at. A scalar floating-point loop in
# the "glue" between audited kernels can silently dominate runtime. `scalar_fp_loops` scans
# the optimized LLVM IR for the co-presence of a loop back-edge (`!llvm.loop` metadata or a
# labeled branch) and scalar (non-vector) FP arithmetic on `double`/`float`.

# Scalar FP op patterns in optimized IR (non-vector forms only). Allows fast-math flags between
# the opcode/call and its type — see `_FMF` above; `@fastmath`/`@simd` scalar remainder/tail code
# emits e.g. `fadd reassoc contract double`, which the unflagged form silently misses.
const _SCALAR_FP_RE = Regex(
    raw"(?:fadd|fmul|fsub|fdiv)" * _FMF * raw" double|" *
        raw"(?:fadd|fmul|fsub|fdiv)" * _FMF * raw" float|" *
        raw"call" * _FMF * raw" double @llvm\.(?:fma|fmuladd)\.f64|" *
        raw"call" * _FMF * raw" float @llvm\.(?:fma|fmuladd)\.f32" * "|" *
        _ORDERED_REDUCE
)

# Loop-carried FP accumulator: a `phi double`/`phi float` node indicates a loop with a
# loop-carried FP variable. More portable than `!llvm.loop` (which LLVM emits inconsistently
# across Julia versions and opt levels).
const _LOOP_RE = r"\bphi (?:double|float)\b"

# F22 — scalar integer loop indicators
const _SCALAR_INT_RE = r"\b(?:add|sub|mul|and|or|xor|shl|lshr|ashr) i(?:8|16|32|64)\b"
const _LOOP_INT_RE = r"\bphi i(?:8|16|32|64)\b"

# Vector op in the text IR (any `<N x …>` value). Read per-loop to decide whether a given loop
# vectorized — see `_loop_regions` / `scalar_fp_loops`.
const _VEC_RE = r"<(?:vscale x )?\d+ x "

# Block names LLVM's own loop vectorizer inserts around any loop it vectorizes, whether the
# source loop carries `@simd` or is plain scalar code. A scalar region built from these blocks is
# the vectorizer's own remainder/epilogue, bounded to under one vector-width's worth of
# iterations — not evidence of source code the optimizer failed to vectorize.
const _VECTORIZER_SCAFFOLD_RE = r"\b(?:vector\.ph|vector\.body|middle\.block|scalar\.ph|min\.iters\.check|bc\.resume\.val)\b"

# Split the optimized text IR into loop regions. A loop is a back-edge: a `br … label %X` whose target
# label `X` is defined *at or before* the branch line. Every label a `br` names is a candidate: a
# conditional latch lists its loop header first as often as last. The region is the IR text from the
# loop header (label `X`) through the back-edge line — enough to scan that one loop for vector vs scalar ops.
# Coarse (text, not a CFG), but enough to reason per-loop instead of whole-function.
function _loop_regions(ir::AbstractString)
    lines = split(ir, '\n')
    labelpos = Dict{SubString{String}, Int}()
    for (i, l) in enumerate(lines)
        m = match(r"^([A-Za-z0-9._]+):", l)
        m !== nothing && (labelpos[m.captures[1]] = i)
    end
    regions = String[]
    for (i, l) in enumerate(lines)
        occursin(r"\bbr\b", l) || continue
        for m in eachmatch(r"\blabel %([A-Za-z0-9._]+)", l)
            j = get(labelpos, m.captures[1], 0)
            0 < j <= i && push!(regions, join(view(lines, j:i), '\n'))   # back-edge ⇒ loop region
        end
    end
    return regions
end

"""
    scalar_fp_loops(f, types::Tuple) -> Bool

**Best-effort** detection: returns `true` if `f`'s optimized LLVM IR contains a loop region
(a back-edge branch) with scalar (non-`<N x>` vector) FP or integer arithmetic on its
loop-carried index, and that region isn't LLVM's own bounded remainder/epilogue of a loop it
already vectorized elsewhere. An in-order reduction (`@llvm.vector.reduce.fadd` without `reassoc`)
is scalar FP arithmetic, and a loop holding one is a scalar loop even when vector loads or vector
multiplies feed it.

This is intentionally coarse — it operates on text IR, not a structured IR graph. A loop region
is any back-edge found by `_loop_regions`; a region counts as scalar hot work if it
contains scalar FP arithmetic (`_SCALAR_FP_RE`), or an integer loop-carried index (`phi iN`)
combined with scalar integer arithmetic (`_SCALAR_INT_RE`). Neither branch requires a
loop-carried FP accumulator (`phi double`/`phi float`): a region is already proven to be a loop
by construction (it was found via a back-edge), and a plain load/compute/store loop with no
reduction has no such accumulator — its FP values are freshly loaded each iteration.

LLVM's own auto-vectorizer wraps every loop it vectorizes — `@simd`-annotated or not — in a
recognizable scaffold (`vector.ph`/`vector.body`/`middle.block`/`scalar.ph`/`min.iters.check`/
`bc.resume.val`); the `scalar.ph`-rooted remainder handles at most one vector-width's worth of
leftover iterations and is not a sign of unvectorized source code, so a scalar region built from
that scaffold is excluded — UNLESS the function also contains a genuinely hand-vectorized loop
(vector ops with none of that scaffolding, e.g. explicit `SIMD.jl` code). In that case the
function's numeric intent was already fully vectorized by hand, so a second, separate scalar
loop is real glue work even if LLVM partially rescued it with its own vectorization attempt.

Use it as a triage signal: a `true` result means "look here for a vectorization opportunity"; a
`false` result does not prove every loop is vectorized. IR that cannot be read (a signature that is
not concrete names no compiled body) raises `_UnanalyzableSignature` rather than returning `false`. See [`@assert_vectorized`](@ref) for
per-kernel vectorization enforcement and [`@assert_no_scalar_loops`](@ref) for the guarded form.
"""
scalar_fp_loops(@nospecialize(f), @nospecialize(types::Tuple))::Bool =
    _scalar_fp_loops(_report_text(_llvm_ir, :scalar_fp_loops, f, types))

function _scalar_fp_loops(s::AbstractString)
    isempty(s) && return false
    # F32: per-loop, not whole-function. The old `_vectorized(f) && return false` short-circuit hid a
    # scalar hot loop whenever the function *also* contained any `<N x …>` op (e.g. a SIMD kernel with a
    # scalar tail/glue loop). Now we scan each loop region: a loop that has scalar FP/int hot ops but no
    # vector op of its own is a scalar loop — even if a *different* loop in the same function vectorized.
    regions = _loop_regions(s)
    if isempty(regions)   # no detectable back-edge: fall back to the whole-function scan (unchanged)
        _ir_vectorized(s) && return false
        return (occursin(_LOOP_RE, s) && occursin(_SCALAR_FP_RE, s)) ||
            (occursin(_LOOP_INT_RE, s) && occursin(_SCALAR_INT_RE, s))
    end
    # A hand-vectorized loop (vector ops, none of LLVM's own scaffolding) means the author
    # already vectorized this function's numeric work — any separate scalar loop is glue.
    hand_vectorized = any(regions) do r
        _loop_vectorized(r) && !occursin(_VECTORIZER_SCAFFOLD_RE, r)
    end
    for r in regions
        _loop_vectorized(r) && continue   # this loop vectorized → fine
        is_scalar_hot = occursin(_SCALAR_FP_RE, r) ||
            (occursin(_LOOP_INT_RE, r) && occursin(_SCALAR_INT_RE, r))
        is_scalar_hot || continue
        # An in-order reduction sits in the vectorizer's MAIN loop (`vector.body`), which runs the
        # whole trip count, so the bounded-remainder exclusion does not apply to it.
        occursin(_VECTORIZER_SCAFFOLD_RE, r) && !hand_vectorized && !occursin(_ORDERED_REDUCE_RE, r) && continue
        return true
    end
    return false
end

function _assert_no_scalar_loops(target, @nospecialize(f), @nospecialize(types::Tuple))
    ir = _llvm_ir(f, types)
    isempty(ir) && return _fail(:no_scalar_loops, target, _output_unread(f, types))
    _scalar_fp_loops(ir) || return nothing
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
@assert_no_scalar_loops apply_T!(Y, T, W)   # warns if TᵀW is a scalar triple-loop
```
"""
macro assert_no_scalar_loops(args...)
    pos, opts = _macro_call("@assert_no_scalar_loops", args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_no_scalar_loops needs a call expression"))
    call = pos[1]
    checked = _guarantee_expr(call, _assert_no_scalar_loops; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
end

# F38 — fast-math usage warning: `contract`/`reassoc`/`nnan`/`ninf`/`nsz`/`arcp`/`afn`/`fast` flags
# (from `@simd`/`@fastmath`) permit floating-point reassociation and NaN/Inf assumptions that can
# change numerical RESULTS, not just codegen — a numerics-risk signal independent of vectorization
# (`@fastmath` alone flags plain scalar ops), so it must print whether or not `r.vectorized`.
function _print_fastmath_warning(io::IO, r::KernelReport)
    r.fastmath_ops > 0 || return nothing
    printstyled(io, "  ⚠ fast-math ops: $(r.fastmath_ops)"; color = :red, bold = true)
    print(
        io, " — this kernel uses `@simd`/`@fastmath`-relaxed floating-point (reassociation, ",
        "NaN/Inf assumptions). Results may differ from strict IEEE 754 evaluation order; verify ",
        "against a non-fast-math reference if bit-for-bit reproducibility matters.\n"
    )
    return nothing
end

function _print_ordered_reduce_warning(io::IO, r::KernelReport)
    r.ordered_reduce_ops > 0 || return nothing
    printstyled(io, "  ⚠ in-order reductions: $(r.ordered_reduce_ops)"; color = :red, bold = true)
    print(
        io, " — `@llvm.vector.reduce.fadd`/`fmul` without `reassoc`: the accumulation runs one ",
        "scalar operation per lane, in sequence, and is not counted as vector arithmetic. ",
        "`@simd` (or an explicit vector accumulator) permits the reordering that vectorizes it.\n"
    )
    return nothing
end

function Base.show(io::IO, r::KernelReport)
    printstyled(io, "KernelReport"; bold = true)
    print(io, ": ", r.target, "\n")
    if !r.vectorized
        printstyled(io, "  not vectorized"; color = :red)
        if r.ordered_reduce_ops > 0
            print(io, " — the accumulation is an in-order reduction (see `@assert_vectorized`).\n")
            _print_ordered_reduce_warning(io, r)
        else
            print(io, " — no `<N x …>` ops (see `@assert_vectorized`).\n")
        end
        _print_fastmath_warning(io, r)
        return
    end
    printstyled(io, "  vectorized"; color = :green)
    print(io, " — `<", r.width, " x>`\n")
    _print_ordered_reduce_warning(io, r)
    print(
        io, "  FP vector ops : memory vector ops = ", r.fp_ops, " : ", r.mem_ops,
        "  → arithmetic intensity ", round(r.intensity; digits = 2), "\n"
    )
    if r.fp_ops == 0 && r.int_ops > 0
        int_intensity = r.int_mem_ops > 0 ? r.int_ops / r.int_mem_ops : Inf
        print(
            io, "  integer vector ops : integer memory ops = ", r.int_ops, " : ", r.int_mem_ops,
            "  → integer intensity ", round(int_intensity; digits = 2), "\n"
        )
    end
    _print_fastmath_warning(io, r)
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
    elseif b === :shuffle
        printstyled(io, "  → shuffle/port-bound"; color = :yellow)
        print(
            io, ": dominated by vpshufb/vperm/shufflevector (the shuffle port, ~1/cycle), not arithmetic. ",
            "Speed it with WIDER vectors (SSE→AVX2→AVX-512) or FEWER shuffles — register/cache blocking does not apply."
        )
    else
        printstyled(io, "  → compute-bound"; color = :green)
        print(io, ": good FLOP:byte balance.")
    end
    # F33 — shuffle ops are invisible to the arithmetic-intensity counts above; surface them explicitly
    if r.shuffle_ops > 0
        print(io, "\n")
        printstyled(io, "  shuffle/permute vector ops: $(r.shuffle_ops)"; color = :cyan)
        print(io, " — pshufb/perm/shufflevector; not counted in the intensity above (the work of lookup/transcode kernels).")
    end
    # F34 — streaming-load loop, low intensity, no prefetch ⇒ likely latency-bound, not bandwidth-bound
    if r.vectorized && r.prefetch_ops == 0 && r.has_loop_phi && (r.mem_ops + r.int_mem_ops) > 0 && b in (:memory, :balanced)
        print(io, "\n")
        printstyled(io, "  no prefetch in a streaming loop"; color = :yellow)
        print(
            io, " — if this is a forward scan it is likely memory-LATENCY-bound (not bandwidth-bound): ",
            "prefetch ~1 chunk ahead with `@llvm.prefetch`. A bandwidth-bound loop won't benefit (then it's a real ceiling)."
        )
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

# Count unique zmm registers and stack spills in post-register-allocation assembly. Takes the
# assembly as a string, so the parse is exercisable against fixed input in both syntaxes.
#
# `\bzmm(\d+)\b`, NOT `%zmm…`: `code_native` emits Intel syntax (bare `zmm0`) on some platforms and
# AT&T (`%zmm0`) on others, and which one you get varies by platform and Julia version. The word
# boundary matches both, since `%` is a non-word character. Pinning the AT&T sigil made this report
# a silent zero for every kernel on an Intel-syntax host — 201 `zmm` occurrences in the assembly,
# `used = 0` (issue #21). `@assert_no_spill` below already avoids this trap by reading LLVM's
# Spill/Reload comments instead of operand punctuation; this had not caught up.
function _zmm_counts(s::AbstractString)
    regs = Set(m[1] for m in eachmatch(r"\bzmm(\d+)\b", s))
    spills = count(l -> occursin("zmm", l) && occursin("rsp", l), split(s, '\n'))
    return (used = length(regs), total = isempty(regs) ? 0 : 32, spills = spills)
end

"""
    register_report(f, types) -> RegisterReport

Read the native assembly for `f` specialized on `types` and count zmm vector register usage
and stack spills. Complements [`kernel_report`](@ref): where `kernel_report` works from LLVM IR
(pre-register-allocation), `register_report` reads post-allocation `code_native`, so it captures
whether the kernel is register-saturated (all 32 zmm in use) and how many spills occurred.

A saturated kernel with spills (32/32, N > 0) is at the LLVM portable-compiler ceiling; adding
more ILP will only spill further and may regress. The last ~15% over LLVM-compiled Rust requires
hand-written assembly.

Only meaningful for x86-64 AVX-512 kernels; non-AVX-512 targets return zeros. Assembly that
cannot be read raises `_UnanalyzableSignature` rather than returning zeros, so a zero count always
describes assembly that was read.
"""
function register_report(@nospecialize(f), @nospecialize(types::Tuple))
    c = _zmm_counts(_report_text(_native_asm, :register_report, f, types))
    return RegisterReport(_func_name(f) * _sig_string(types), c.used, c.total, c.spills)
end

# --- @assert_no_spill: vector-register spill diagnostic as a hard gate --------------------------
#
# `register_report`/`RegisterReport` above are advisory (never fail). `@assert_no_spill` is the
# codegen analogue of `@assert_noalloc`: a hard, gate-able guarantee that the compiled kernel
# doesn't spill vector registers to the stack. Detection reads the `# ... Spill`/`# ... Reload`
# comments LLVM's register allocator emits next to the spilling instruction — these are present
# regardless of assembly syntax (AT&T vs Intel; `code_native`'s default varies by platform/Julia
# version), unlike a register-name regex tied to one syntax's operand punctuation. A line only
# counts if it also names a vector register — a scalar (GPR) spill from ordinary stack traffic is not
# what this guarantee is about. The comment marker and the register names are per architecture: x86
# writes `#` and names `xmm`/`ymm`/`zmm`; AArch64 writes `//` (`;` on macOS) and names its
# floating-point and vector registers `b`/`h`/`s`/`d`/`q`/`v`, SVE's `z` and SME's `za`.
const _SPILL_RELOAD_RE = r"(?:#|//|;).*\b(?:Spill|Reload)\b"
# Any other architecture has no pattern: its spill lines name registers neither pattern matches, so
# reading them with one would count zero spills.
function _vec_reg_re(arch::Symbol)
    arch === :aarch64 && return r"\b(?:[bhsdqvz]\d+|za\w*)\b"
    arch in (:x86_64, :i686) && return r"\b(?:xmm|ymm|zmm)\d+\b"
    return nothing
end

# Why vector spills cannot be counted on `arch`, or `nothing` when they can.
_spill_arch_unread(arch::Symbol = Sys.ARCH) = isnothing(_vec_reg_re(arch)) ?
    "vector spills cannot be counted on $arch: StrictMode knows the vector register names of x86 " *
    "and AArch64 only" : nothing

"""
    SpillReport

The result of [`spill_report`](@ref): `target` (the checked signature, as a string) and three counts
of vector-register spill/reload lines — `vec_spills` over the whole function, `loop_spills` inside
any loop, and `innermost_spills` inside an innermost loop.
"""
struct SpillReport
    target::String
    vec_spills::Int        # every line carrying both a vector register and a Spill/Reload annotation
    loop_spills::Int       # those inside a loop: code that runs more than once per call
    innermost_spills::Int  # those inside an innermost loop
end

# The loop each line of `asm` sits in, read from LLVM's block annotations: a block starts at a label
# (`.LBB0_3:`, `LBB0_3:` on macOS) or a fall-through marker (`# %bb.4:`, `//` or `;` on AArch64), and the comment lines that open it name its loop
# — `=>This Loop Header: Depth=N` or `=>  This Inner Loop Header: Depth=N` for a header, and
# `in Loop: Header=BB0_3 Depth=N` for a block inside one. "Inner" marks an innermost loop. Returns the
# depth of each line (0 outside every loop) and whether it is in an innermost loop.
function _asm_loop_depths(lines::AbstractVector{<:AbstractString})
    label = r"^\s*\.?L(BB\d+_\d+):"
    fallthrough = r"^\s*(?:#|//|;) %bb\.\d+:"
    innermost = Set{String}()
    cur = ""
    for l in lines
        m = match(label, l)
        isnothing(m) || (cur = m.captures[1])
        occursin(fallthrough, l) && (cur = "")
        occursin("This Inner Loop Header", l) && !isempty(cur) && push!(innermost, cur)
    end
    depth = zeros(Int, length(lines))
    inner = falses(length(lines))
    d = 0
    hdr = ""
    cur = ""
    for (k, l) in enumerate(lines)
        m = match(label, l)
        if !isnothing(m)
            cur = m.captures[1]
            d = 0
            hdr = ""
        elseif occursin(fallthrough, l)
            cur = ""
            d = 0
            hdr = ""
        end
        if (h = match(r"Loop Header: Depth=(\d+)", l); !isnothing(h))
            d = parse(Int, h.captures[1])
            hdr = cur
        elseif (h = match(r"in Loop: Header=(BB\d+_\d+) Depth=(\d+)", l); !isnothing(h))
            d = parse(Int, h.captures[2])
            hdr = h.captures[1]
        end
        depth[k] = d
        inner[k] = d > 0 && hdr in innermost
    end
    return depth, inner
end

"""
    spill_report(f, types) -> SpillReport

Read the native assembly for `f` specialized on `types` and count vector-register spill/reload
events (LLVM's `# ... Spill`/`# ... Reload` annotations on a line naming a vector register: `xmm`/`ymm`/`zmm` on x86, `b`/`h`/`s`/`d`/`q`/`v`/`z`/`za` on AArch64).
A nonzero count means the kernel needs more live vector registers than the target ISA provides —
the codegen analogue of an allocation: still correct, but paying stack traffic on every spill/
reload instead of running from registers. Complements [`register_report`](@ref) (which reads
zmm-saturation specifically) and [`kernel_report`](@ref) (which works from pre-allocation LLVM IR
and can't see spills at all). Assembly that cannot be read raises
`_UnanalyzableSignature`, naming the signature and the reason, rather than reporting zero spills:
that is the case for a signature that is not concrete, which names no compiled body.
On an architecture other than x86 and AArch64, whose vector register names it does not know, it
raises too.

Each spill is placed by the loop its block is in, from LLVM's own loop annotations. `loop_spills`
leaves out code that runs once per call — the prologue and the epilogue that stores a tile's
results — where a spill costs one store and one load per call rather than per iteration.
`innermost_spills` keeps only innermost loops; note that an innermost loop can be a remainder loop,
so it is not the same as the hot loop.
"""
function spill_report(@nospecialize(f), @nospecialize(types::Tuple))
    why = _spill_arch_unread()
    isnothing(why) || throw(_UnanalyzableSignature(:spill_report, f, types, why))
    return _spill_report(
        _func_name(f) * _sig_string(types), _report_text(_native_asm, :spill_report, f, types)
    )
end

function _spill_report(target::AbstractString, asm::AbstractString)
    isempty(asm) && return SpillReport(target, 0, 0, 0)
    total, inloop, ininner = _spill_counts(split(asm, '\n'), Sys.ARCH)
    return SpillReport(target, total, inloop, ininner)
end

# Vector spill and reload lines in `lines`: over the whole function, inside a loop, inside an innermost
# loop. On AArch64 the calling convention makes `d8`–`d15` callee-saved, so a function that keeps a float
# across a call saves them in its prologue and restores them in its epilogue — outside every loop, and
# marked `Spill` by LLVM. x86-64 has no callee-saved vector register, so those lines are not counted.
function _spill_counts(lines::AbstractVector{<:AbstractString}, arch::Symbol)
    re = _vec_reg_re(arch)
    isnothing(re) && throw(ArgumentError(_spill_arch_unread(arch)))
    depth, inner = _asm_loop_depths(lines)
    total = 0
    inloop = 0
    ininner = 0
    for (k, l) in enumerate(lines)
        (occursin(_SPILL_RELOAD_RE, l) && occursin(re, l)) || continue
        (arch === :aarch64 && depth[k] == 0 && _arm_callee_saved_only(l, re)) && continue
        total += 1
        depth[k] > 0 && (inloop += 1)
        inner[k] && (ininner += 1)
    end
    return (total, inloop, ininner)
end

function _arm_callee_saved_only(l::AbstractString, re::Regex)
    regs = [m.match for m in eachmatch(re, l)]
    return !isempty(regs) && all(r -> (m = match(r"^d(\d+)$", r); !isnothing(m) && 8 <= parse(Int, m[1]) <= 15), regs)
end

const _SPILL_SCOPES = (:loops, :innermost, :function)

function _spill_count(r::SpillReport, scope::Symbol)
    scope === :loops && return r.loop_spills
    scope === :innermost && return r.innermost_spills
    scope === :function && return r.vec_spills
    throw(ArgumentError("spill scope must be one of $(_SPILL_SCOPES), got :$scope"))
end

function Base.show(io::IO, r::SpillReport)
    printstyled(io, "SpillReport"; bold = true)
    print(io, ": ", r.target, "\n")
    if r.vec_spills == 0
        printstyled(io, "  clean"; color = :green)
        print(io, ": no vector-register spills.")
    else
        color = r.loop_spills > 0 ? :red : :yellow
        printstyled(io, "  $(r.vec_spills) vector-register spill/reload line(s)"; color)
        print(
            io, " — $(r.loop_spills) inside a loop, $(r.innermost_spills) inside an innermost loop."
        )
        r.loop_spills > 0 && print(
            io, " Reduce the live accumulator/tile count, or split into multiple passes. See " *
                "`register_report` for zmm-saturation diagnostics."
        )
    end
    return nothing
end

function _assert_no_spill(target, @nospecialize(f), @nospecialize(types::Tuple), scope::Symbol = :loops)
    why = _spill_arch_unread()
    isnothing(why) || return _fail(:no_spill, target, why)
    asm = _native_asm(f, types)
    isempty(asm) && return _fail(:no_spill, target, _output_unread(f, types))
    r = _spill_report(_func_name(f) * _sig_string(types), asm)
    n = _spill_count(r, scope)
    iszero(n) && return nothing
    where_ = scope === :function ? "" : scope === :loops ? " inside a loop" : " inside an innermost loop"
    _fail(
        :no_spill, target,
        "vector register(s) spilled to the stack$where_ ($n spill/reload line(s)) — the " *
            "kernel needs more live vector registers than the target ISA provides. Reduce the " *
            "live accumulator/tile count, or split into multiple passes."
    )
    return nothing
end

"""
    @assert_no_spill f(args...)

Fail if `f(args...)` compiled to code that **spills a vector register to the stack**
(**best-effort**): StrictMode scans the post-register-allocation `code_native` output for LLVM's
`# ... Spill`/`# ... Reload` annotations on a line naming a vector register (`xmm`/`ymm`/`zmm` on x86, `b`/`h`/`s`/`d`/`q`/`v`/`z`/`za` on AArch64; any other architecture fails, since its registers would read as no spill). This is
the codegen analogue of [`@assert_noalloc`](@ref) — a kernel can be type-stable, allocation-free,
and vectorized, and still be "correct but slower" because it needs more live vector registers than
the target ISA provides (LLVM's portable register allocator has no choice but to spill). A
failure means the kernel needs fewer live accumulators/tiles, not more optimization flags.

Each argument is evaluated once; disabled builds expand to the bare call. Hard-gate-able (unlike
[`kernel_report`](@ref)/[`register_report`](@ref), which are advisory and never fail) since a
spill is unambiguous evidence of register pressure, not a heuristic judgment call.

`scope` chooses which spills count. The default, `:loops`, counts spills inside any loop and leaves
out code that runs once per call, such as the epilogue that stores a tile's results: a spill there is
one store and one load per call, not register pressure in the loop. `:innermost` counts innermost
loops only, which can include a remainder loop; `:function` counts every spill.

```julia
@assert_no_spill dtrsm_tile!(B, A)                     # throws if the tile spills inside its loop
@assert_no_spill dtrsm_tile!(B, A) scope = :function   # any spill at all
```
"""
macro assert_no_spill(args...)
    pos, opts = _macro_call("@assert_no_spill", args, (:types, :scope))
    isempty(pos) && throw(ArgumentError("@assert_no_spill needs a call expression"))
    call = pos[1]
    scope = get(opts, :scope, QuoteNode(:loops))
    scope isa QuoteNode && scope.value in _SPILL_SCOPES || throw(
        ArgumentError("@assert_no_spill: scope must be one of $(_SPILL_SCOPES), got $scope")
    )
    checked = _guarantee_expr(call, _assert_no_spill, scope; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
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
