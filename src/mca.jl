# F16-tier2/issue #16: `mca_report`/`@assert_mca` — llvm-mca-backed codegen-quality report.
#
# `@assert_no_spill` (scheduling.jl, Tier 1) is a cheap, dep-free, hard-gate-able check for one
# specific codegen pathology (register spilling). `mca_report` is the heavier Tier 2 sibling: run
# `llvm-mca` on the kernel's own native assembly to estimate steady-state throughput/IPC — catches
# a kernel that is register-clean and vectorized but *latency-bound* (e.g. a fused kernel whose
# dependency chain serializes it well below the hardware's real throughput ceiling).
#
# INFORMATIONAL BY DESIGN, not a hard-gate guarantee: a naive whole-function llvm-mca run models
# the function body as a single loop, and a store→reload of the same output pointer at the
# boundary creates a FALSE loop-carried dependency that serializes the estimate — ground-truth
# runtime disagreed with a naive mca run in the motivating case. Region markers
# (`# LLVM-MCA-BEGIN`/`# LLVM-MCA-END`) around the actual innermost hot loop sidestep that trap,
# but the region-extraction here is a text-based heuristic (not a real CFG), so `@assert_mca`
# fails ONLY on bounds the caller explicitly supplies — it is never boundless by default.
#
# Sanitization: Julia's `code_native` output carries a `; Function Signature: ...` comment line —
# `;` is a GAS statement separator on x86, not a comment character, so llvm-mca's assembler chokes
# on it (`unexpected token in argument list`) unless it's stripped first. Non-ASCII lines are
# dropped for the same reason (the assembler errors on the raw bytes).

function _sanitize_asm_for_mca(asm::AbstractString)
    lines = split(asm, '\n')
    keep = filter(lines) do l
        s = lstrip(l)
        !startswith(s, ";") && all(isascii, l)
    end
    return join(keep, '\n')
end

# A GAS label definition: `NAME:` at the start of a line (after whitespace), name made of the
# usual assembler-identifier characters plus `.`/`$` (local/temp labels like `.LBB0_6`).
const _ASM_LABEL_RE = r"^\s*([A-Za-z_.$][A-Za-z0-9_.$]*):"
# A jump/branch mnemonic (`j*`) naming a label operand — deliberately excludes `call`/`jmp *reg`
# (indirect) forms, which don't name a static label this text scan can resolve.
const _ASM_JUMP_RE = r"^\s*j[a-z]*\s+([A-Za-z_.$][A-Za-z0-9_.$]*)\b"
# Deliberately `ymm|zmm` only, NOT `xmm`: x86 SSE scalar ops (`addsd`/`vmovsd`/`vfmadd231sd`, …)
# also operate on the xmm register file — a scalar remainder/tail loop can be full of `%xmm0`
# mentions despite doing no packed work at all (verified against real Julia-generated asm: the
# scalar tail loop of a vectorized dot product uses only xmm; the packed SIMD loop uses zmm).
# ymm/zmm are exclusively packed-width register forms in x86-64, so they're an unambiguous signal.
const _ASM_VEC_REG_RE = r"%(?:ymm|zmm)\d+\b"

# Every (start_line, end_line) span whose end is a backward jump to its own start — a loop, by the
# same "label position <= branch line" back-edge test `_loop_regions` (scheduling.jl) uses for LLVM
# IR text, adapted to GAS label/jump syntax. Coarse (text, not a CFG) but enough to bound a region.
function _asm_loop_spans(lines::AbstractVector{<:AbstractString})
    labelpos = Dict{SubString{String}, Int}()
    for (i, l) in enumerate(lines)
        m = match(_ASM_LABEL_RE, l)
        m !== nothing && (labelpos[m.captures[1]] = i)
    end
    spans = Tuple{Int, Int}[]
    for (i, l) in enumerate(lines)
        m = match(_ASM_JUMP_RE, l)
        m === nothing && continue
        j = get(labelpos, m.captures[1], 0)
        0 < j <= i && push!(spans, (j, i))
    end
    return spans
end

const _ASM_ZMM_RE = r"%zmm\d+\b"

"""
    _innermost_loop_span(sanitized_asm) -> Union{Nothing, Tuple{Int,Int}}

Find the hot loop to bound an `llvm-mca` region around: among every detected loop span (a label
targeted by a backward jump), prefer spans that contain a vector register mention (the actual SIMD
kernel core, as opposed to an incidental scalar remainder/tail loop, which is typically smaller in
line count but not what a codegen-quality report should focus on); among those, prefer spans using
`%zmm` over `%ymm`-only (LLVM's unroll-epilogue vectorization emits a narrower-width "cleanup" loop
alongside the main wide loop, and the main loop is the one worth reporting on); ties (including the
nested-loop case, where an inner loop's span is a sub-range of any loop containing it) go to the
smallest span. `nothing` if no loop was found at all (the caller then falls back to a whole-function
run, flagged with a caveat).

**Known limitation, inherent to a text-based heuristic with no real CFG**: two DISJOINT
(non-nested) vectorized loops of comparable width in the same function are not distinguished by
runtime weight — the smaller one wins regardless of which one actually dominates. This is why
[`mca_report`](@ref)'s result is informational-only and [`@assert_mca`](@ref) never hard-gates
without an explicit bound; pass `region = :whole_function`, or point `f` at a smaller helper
containing only the loop you actually want measured, if this matters for your case.
"""
function _innermost_loop_span(sanitized_asm::AbstractString)
    lines = split(sanitized_asm, '\n')
    spans = _asm_loop_spans(lines)
    isempty(spans) && return nothing
    has_match(re, a, b) = any(l -> occursin(re, l), view(lines, a:b))
    vec_spans = filter(((a, b),) -> has_match(_ASM_VEC_REG_RE, a, b), spans)
    pool = if isempty(vec_spans)
        spans
    else
        zmm_spans = filter(((a, b),) -> has_match(_ASM_ZMM_RE, a, b), vec_spans)
        isempty(zmm_spans) ? vec_spans : zmm_spans
    end
    return pool[argmin(b - a for (a, b) in pool)]
end

"""
    _wrap_mca_region(sanitized_asm, span) -> String

Insert `# LLVM-MCA-BEGIN hot` / `# LLVM-MCA-END` around `span` (1-indexed, inclusive line range)
in `sanitized_asm`, so `llvm-mca` analyzes only that region instead of modeling the whole function
body as one loop (the false loop-carried-dependency trap a naive whole-function run hits).
"""
function _wrap_mca_region(sanitized_asm::AbstractString, span::Tuple{Int, Int})
    lines = split(sanitized_asm, '\n')
    a, b = span
    out = String[]
    append!(out, lines[1:(a - 1)])
    push!(out, "# LLVM-MCA-BEGIN hot")
    append!(out, lines[a:b])
    push!(out, "# LLVM-MCA-END")
    append!(out, lines[(b + 1):end])
    return join(out, '\n')
end

# --- -mcpu validation -----------------------------------------------------------------------------

"""
    _resolve_mcpu(requested) -> (mcpu::String, fellback::Bool)

Validate `requested` against `llvm-mca -mcpu=help`'s own recognized-CPU list (a mismatch between
the host's real microarchitecture name and what the bundled `LLVM_full_jll` version recognizes is
a real, observed failure mode, e.g. a brand-new CPU name an older LLVM release doesn't know about
yet) — unlike Julia's own codegen path (which warns and silently continues), `llvm-mca`'s CLI
**hard-fails** (nonzero exit, no report at all) on an unrecognized `-mcpu`, so this must be
checked proactively rather than relying on the tool's own fallback (there isn't one). Falls back
to `"generic"` (always valid) with a warning if `requested` isn't recognized.
"""
function _resolve_mcpu(requested::AbstractString)
    cpus = _be_mca_cpus()
    requested in cpus && return (requested, false)
    @warn "StrictMode mca_report: `-mcpu=$requested` is not recognized by this llvm-mca build " *
        "(got $(length(cpus)) known CPU name(s); this can happen on a CPU newer than the bundled " *
        "LLVM_full_jll release) — falling back to `-mcpu=generic`. Numbers will be less precise " *
        "for this host; consider updating LLVM_full_jll." maxlog = 1
    return ("generic", true)
end

# --- report parsing ---------------------------------------------------------------------------

"""
    McaReport

`llvm-mca`'s steady-state throughput estimate for a kernel's hot loop (or whole function, if no
loop region could be found — see `whole_function`). **Informational only** — see the module notes
above for why a naive run can disagree with ground truth, and why `@assert_mca` never fails by
default.

Fields: `target`, `mcpu` (the CPU model actually used — see `_resolve_mcpu`), `mcpu_fellback`
(whether the requested `mcpu` wasn't recognized and `generic` was substituted), `whole_function`
(`true` if no loop region was found — the whole-function fallback, flagged since it's the shape
most likely to hit the false-loop-carried-dependency trap), `iterations`, `instructions`,
`total_cycles`, `total_uops`, `dispatch_width`, `uops_per_cycle`, `ipc`, `block_rthroughput`. Any
field defaults to `NaN`/`0` if `llvm-mca`'s output didn't contain that line (its report format has
shifted across LLVM releases before).
"""
Base.@kwdef struct McaReport
    target::String
    mcpu::String
    mcpu_fellback::Bool
    whole_function::Bool
    iterations::Int = 0
    instructions::Int = 0
    total_cycles::Int = 0
    total_uops::Int = 0
    dispatch_width::Int = 0
    uops_per_cycle::Float64 = NaN
    ipc::Float64 = NaN
    block_rthroughput::Float64 = NaN
end

function _mca_int(text, re)
    m = match(re, text)
    return m === nothing ? 0 : parse(Int, m[1])
end
function _mca_float(text, re)
    m = match(re, text)
    return m === nothing ? NaN : parse(Float64, m[1])
end

# Parse llvm-mca's plain-text summary block. Deliberately tolerant (each field independently
# regex-matched, missing ⇒ default) — the exact report format is not a stable API across LLVM
# releases, and a report meant to be informational should degrade gracefully, not throw, on a
# format it doesn't fully recognize.
function _parse_mca_output(text::AbstractString)
    return (
        iterations = _mca_int(text, r"Iterations:\s*(\d+)"),
        instructions = _mca_int(text, r"Instructions:\s*(\d+)"),
        total_cycles = _mca_int(text, r"Total Cycles:\s*(\d+)"),
        total_uops = _mca_int(text, r"Total uOps:\s*(\d+)"),
        dispatch_width = _mca_int(text, r"Dispatch Width:\s*(\d+)"),
        uops_per_cycle = _mca_float(text, r"uOps Per Cycle:\s*([\d.]+)"),
        ipc = _mca_float(text, r"IPC:\s*([\d.]+)"),
        block_rthroughput = _mca_float(text, r"Block RThroughput:\s*([\d.]+)"),
    )
end

"""
    mca_report(f, types; mcpu = Sys.CPU_NAME, region = :innermost_loop) -> McaReport

Run `llvm-mca` on `f`'s native assembly and return a steady-state throughput/IPC estimate.
**Informational, advisory** — never fails; use [`@assert_mca`](@ref) for a gate, which only fails
on bounds you explicitly supply. Needs `LLVM_full_jll` (`using LLVM_full_jll`, a ~680MiB weak
dependency — see [`StrictMode.mca_available`](@ref)).

- `mcpu`: the target CPU model name; defaults to the host's own (`Sys.CPU_NAME`), validated
  against what this `llvm-mca` build actually recognizes and substituted with `"generic"` (warned
  once) if not — a real failure mode, since `llvm-mca`'s CLI hard-fails on an unrecognized `-mcpu`
  rather than falling back itself.
- `region = :innermost_loop` (default): wrap the smallest detected loop containing a vector op in
  `# LLVM-MCA-BEGIN`/`# LLVM-MCA-END` markers before running `llvm-mca`, so the estimate reflects
  the actual hot loop rather than the false loop-carried dependency a naive whole-function run
  hits (see the module notes). `region = :whole_function` skips region detection entirely.

```julia
using LLVM_full_jll
r = mca_report(dot_kernel!, (Vector{Float64}, Vector{Float64}))
r.ipc            # steady-state instructions/cycle estimate
r.whole_function # true if no loop region was found (a caveat, not a hard failure)
```
"""
function mca_report(
        @nospecialize(f), @nospecialize(types::Tuple);
        mcpu::AbstractString = Sys.CPU_NAME, region::Symbol = :innermost_loop
    )
    _require_mca()
    target = _func_name(f) * _sig_string(types)
    resolved_mcpu, fellback = _resolve_mcpu(mcpu)
    asm = _sanitize_asm_for_mca(_native_asm_att(f, types))
    span = region === :innermost_loop ? _innermost_loop_span(asm) : nothing
    whole_function = span === nothing
    input = whole_function ? asm : _wrap_mca_region(asm, span)
    raw = _be_mca_run(input, resolved_mcpu)
    parsed = _parse_mca_output(raw)
    return McaReport(; target, mcpu = resolved_mcpu, mcpu_fellback = fellback, whole_function, parsed...)
end

# `_native_asm` (scheduling.jl) defaults to the platform's native syntax (Intel on this Julia); the
# mca path specifically needs AT&T (`llvm-mca`'s assembler defaults to AT&T parsing).
function _native_asm_att(@nospecialize(f), @nospecialize(types::Tuple))
    io = IOBuffer()
    try
        InteractiveUtils.code_native(io, f, types; debuginfo = :none, syntax = :att)
    catch
        return ""
    end
    return String(take!(io))
end

function Base.show(io::IO, r::McaReport)
    printstyled(io, "McaReport"; bold = true)
    print(io, ": ", r.target, " (mcpu=", r.mcpu, r.mcpu_fellback ? ", fell back from request" : "", ")\n")
    if r.whole_function
        printstyled(io, "  whole-function fallback"; color = :yellow)
        print(io, " — no loop region detected; a naive whole-function mca run can disagree with ground truth (see the module notes). Numbers below are informational only.\n")
    end
    print(
        io, "  ", r.iterations, " iteration(s), ", r.instructions, " instruction(s), ",
        r.total_cycles, " cycle(s)\n"
    )
    print(
        io, "  Dispatch width ", r.dispatch_width, "  uOps/cycle ", round(r.uops_per_cycle; digits = 2),
        "  IPC ", round(r.ipc; digits = 2), "  Block RThroughput ", round(r.block_rthroughput; digits = 2)
    )
    return nothing
end

function _assert_mca(target, @nospecialize(f), @nospecialize(types::Tuple); mcpu, region, max_rthroughput, min_ipc)
    r = mca_report(f, types; mcpu, region)
    problems = String[]
    max_rthroughput !== nothing && r.block_rthroughput > max_rthroughput && push!(
        problems,
        "Block RThroughput $(round(r.block_rthroughput; digits = 2)) exceeds max_rthroughput=$max_rthroughput"
    )
    min_ipc !== nothing && r.ipc < min_ipc && push!(
        problems,
        "IPC $(round(r.ipc; digits = 2)) is below min_ipc=$min_ipc"
    )
    isempty(problems) || _fail(
        :mca, target,
        "llvm-mca bound(s) violated: " * join(problems, "; ") *
            (r.whole_function ? " (whole-function fallback — no loop region detected, numbers are less reliable)" : "")
    )
    return nothing
end

"""
    @assert_mca f(args...)
    @assert_mca max_rthroughput=N f(args...)
    @assert_mca min_ipc=N f(args...)
    @assert_mca mcpu="znver4" region=:whole_function f(args...)

Run [`mca_report`](@ref) on `f(args...)` and fail **only if you supply `max_rthroughput=`/
`min_ipc=`** and the report violates them — with neither bound given, this always passes (the
report is purely informational; see the module notes on why a naive `llvm-mca` estimate can
disagree with ground truth). Each argument is evaluated once; the macro evaluates to the call's
value; disabled builds expand to the bare call. Needs `LLVM_full_jll` loaded (a ~680MiB weak
dependency) — not part of [`@strict`](@ref)/[`@kernel`](@ref).

```julia
using LLVM_full_jll
@assert_mca fma_kernel!(C, A, B)                        # always passes; logs the McaReport
@assert_mca min_ipc=2.0 fma_kernel!(C, A, B)             # throws if steady-state IPC < 2.0
```
"""
macro assert_mca(args...)
    pos, opts = _macro_call(args, (:types, :mcpu, :region, :max_rthroughput, :min_ipc))
    isempty(pos) && throw(ArgumentError("@assert_mca needs a call expression"))
    call = pos[1]
    target = string(call)
    p = _call_parts(call; types = get(opts, :types, nothing))
    mcpu_expr = haskey(opts, :mcpu) ? esc(opts[:mcpu]) : :(Sys.CPU_NAME)
    region_expr = haskey(opts, :region) ? esc(opts[:region]) : QuoteNode(:innermost_loop)
    max_rt_expr = haskey(opts, :max_rthroughput) ? esc(opts[:max_rthroughput]) : nothing
    min_ipc_expr = haskey(opts, :min_ipc) ? esc(opts[:min_ipc]) : nothing

    checked = quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_assert_mca)(
            $target, $(p.checkfn), $(p.types);
            mcpu = $mcpu_expr, region = $region_expr, max_rthroughput = $max_rt_expr, min_ipc = $min_ipc_expr
        )
        _val
    end
    return _gate(checked, esc(call))
end
