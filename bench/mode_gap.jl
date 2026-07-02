# Quantify the :fast ↔ :full gap on real corpora.
#
# For every compiled concrete specialization of the corpus modules (PureFFT + the BlazingPorts
# crates — warm real kernels first), run `findings` in BOTH modes for the mode-sensitive
# guarantees and record: agreement tallies (with :full as ground truth), every divergent case in
# full local detail, and per-call wall times. Saves everything to bench/results/mode_gap.json —
# regenerate analyses from that file, don't re-run (re-running is noisy and slow).
#
# Run:
#   julia --project=<env with StrictMode(dev) + PureFFT + BlazingPorts + AllocCheck + JET + SIMD + JSON> \
#         bench/mode_gap.jl
#
# The corpus is "whatever the warmup compiled" — the same usage-driven scope check_compiled sees.

using StrictMode, AllocCheck, JET
using PureFFT, BlazingPorts
using SIMD: Vec
using JSON

StrictMode.backend_available() || error("need `using AllocCheck, JET` (backend) for :full")

const GS = (:typestable, :noalloc, :noboxing, :inlined)

# ── warm the corpora (mirrors the repos' own audit warmups) ─────────────────────────────────────
function warm_purefft()
    for n in (64, 97, 289, 576, 578, 768, 769, 1024, 1080, 2880)
        p = PureFFT.autoplan(ComplexF64, n)
        x = randn(ComplexF64, n)
        pfft!(x, p)
    end
    prfft(randn(64)); r2r(randn(64), PureFFT.REDFT10); dct(randn(64))
    return nothing
end

function warm_blazingports()
    SM = BlazingPorts.SmallMatrix
    a = SM.Vec3(1.0, 2.0, 3.0); b = SM.Vec3(4.0, 5.0, 6.0)
    SM.dot(a, b); SM.cross(a, b); SM.norm(a); SM.normalize(a); a + b; 2.0 * a
    v = SM.Vec4(1.0, 2.0, 3.0, 4.0); m = SM.Mat4(v, v, v, v); m * v; m * m
    F = BlazingPorts.Factorizations
    A = [i == j ? 16.0 : 0.25 for i in 1:16, j in 1:16]
    F.cholesky_llt!(A)
    SS = BlazingPorts.StringSearch
    h = rand(UInt8, 4096); pat = h[4000:4031]
    GC.@preserve h pat SS._find_substr(pointer(h), length(h), pointer(pat), length(pat))
    SS.find_substr(h, pat)
    IF = BlazingPorts.IntFormat
    buf = Vector{UInt8}(undef, 24); IF.format_int!(buf, 12345)
    SD = BlazingPorts.SwissDict
    d = SD.SwissDict{UInt64, UInt64}()
    for i in UInt64(1):UInt64(1000)
        d[i] = i * 2
    end
    SD._ht_keyindex(d, UInt64(500))
    B3 = BlazingPorts.Blake3
    data = [UInt8(i % 251) for i in 0:(8 * B3.CHUNK_LEN - 1)]
    GC.@preserve data begin
        p = pointer(data)
        ptrs = ntuple(k -> p + (k - 1) * B3.CHUNK_LEN, Val(8))
        B3._compress_N_chunks_full(ptrs, B3.KEY1, B3.KEY2, B3.KEY3, B3.KEY4, B3.KEY5, B3.KEY6, B3.KEY7, B3.KEY8, UInt64(0))
    end
    U = BlazingPorts.Utf8
    U.isvalid_utf8("café — 日本語 𝄞")
    input = Vec{32, UInt8}(ntuple(i -> UInt8(0xE0 + (i % 16)), 32))
    prev1 = Vec{32, UInt8}(ntuple(i -> UInt8(0x80 + (i % 16)), 32))
    U._check_special(input, prev1)
    B = BlazingPorts.ByteOps
    B._enc24(Vec{32, UInt8}(ntuple(i -> UInt8(i + 33), 32)))
    return nothing
end

# ── enumerate compiled concrete specializations (the check_compiled walk) ───────────────────────
function corpus_items(mod::Module)
    items = Any[]
    for nm in names(mod; all = true)
        isdefined(mod, nm) || continue
        f = getfield(mod, nm)
        (f isa Function && parentmodule(f) === mod) || continue
        for mth in methods(f)
            for mi in StrictMode._specializations(mth)
                tt = try
                    Tuple((mi.specTypes::DataType).parameters[2:end])
                catch
                    continue
                end
                all(isconcretetype, tt) || continue
                push!(items, (f, tt))
            end
        end
    end
    return items
end

warm_purefft()
warm_blazingports()

const MODULES = [
    PureFFT,
    BlazingPorts.SmallMatrix, BlazingPorts.Factorizations, BlazingPorts.StringSearch,
    BlazingPorts.IntFormat, BlazingPorts.SwissDict, BlazingPorts.Blake3,
    BlazingPorts.Utf8, BlazingPorts.ByteOps,
]

# Stream records as JSONL so a killed run (OOM, timeout) keeps everything measured so far, and
# RESUME on re-run: existing records are loaded, skipped, and included in the final summary.
mkpath(joinpath(@__DIR__, "results"))
const OUT = joinpath(@__DIR__, "results", "mode_gap.jsonl")
const DONE_KEYS = Set{String}()
const PRIOR = Any[]
if isfile(OUT)
    for l in eachline(OUT)
        isempty(strip(l)) && continue
        r = JSON.parse(l)
        push!(PRIOR, r)
        push!(DONE_KEYS, string(r["module"], "|", r["func"], "|", r["sig"]))
    end
    println("resuming: $(length(PRIOR)) records already measured")
end
const IO_OUT = open(OUT, "a")

records = Any[]
for mod in MODULES
    items = corpus_items(mod)
    println("── $(nameof(mod)): $(length(items)) compiled specializations")
    flush(stdout)
    for (f, tt) in items
        fn = string(nameof(f))
        sg = "(" * join(string.(tt), ", ") * ")"
        string(nameof(mod), "|", fn, "|", sg) in DONE_KEYS && continue
        rec = Dict{String, Any}(
            "module" => string(nameof(mod)), "func" => fn, "sig" => sg,
        )
        t0 = time(); fast = try
            StrictMode.findings(f, tt; guarantees = GS, mode = :fast)
        catch e
            missing
        end
        rec["t_fast_s"] = time() - t0
        t0 = time(); full = try
            StrictMode.findings(f, tt; guarantees = GS, mode = :full)
        catch e
            missing
        end
        rec["t_full_s"] = time() - t0
        if fast === missing || full === missing
            rec["error"] = fast === missing ? "fast-errored" : "full-errored"
        else
            fm = Dict(x.guarantee => x for x in fast)
            lm = Dict(x.guarantee => x for x in full)
            for g in GS
                a, b = fm[g], lm[g]
                rec[string(g)] = Dict(
                    "fast" => string(a.status), "full" => string(b.status),
                    "diverged" => (a.status === :fail) != (b.status === :fail),
                    "fast_reason" => (a.status === :fail ? a.reason : ""),
                    "full_reason" => (b.status === :fail ? b.reason : ""),
                )
            end
        end
        push!(records, rec)
        JSON.print(IO_OUT, rec); println(IO_OUT); flush(IO_OUT)
    end
end
close(IO_OUT)
println("wrote $(length(records)) new records → $OUT")
append!(records, PRIOR)

# ── summary ──────────────────────────────────────────────────────────────────────────────────────
using Statistics: median
ok = [r for r in records if !haskey(r, "error")]
println("\ncorpus: $(length(records)) specializations ($(length(records) - length(ok)) errored, excluded)")
println(
    "timing: fast median $(round(median([r["t_fast_s"] for r in ok]) * 1.0e3, digits = 2)) ms, ",
    "full median $(round(median([r["t_full_s"] for r in ok]) * 1.0e3, digits = 2)) ms, ",
    "full total $(round(sum(r["t_full_s"] for r in ok), digits = 1)) s vs fast total $(round(sum(r["t_fast_s"] for r in ok), digits = 1)) s"
)
for g in string.(GS)
    n = length(ok)
    div = [r for r in ok if r[g]["diverged"]]
    fp = count(r -> r[g]["fast"] == "fail", div)   # fast flags, full passes → false positive
    fn_ = length(div) - fp                          # fast passes, full flags → false negative (the bad kind)
    println(rpad(g, 12), " agree $(n - length(div))/$n   fast-FP $fp   fast-FN $fn_")
end
println("\ndivergent cases:")
for r in ok, g in string.(GS)
    r[g]["diverged"] || continue
    d = r[g]
    kind = d["fast"] == "fail" ? "FP" : "FN"
    println("  [$kind $(g)] $(r["module"]).$(r["func"])$(r["sig"])")
    isempty(d["fast_reason"]) || println("      fast: $(d["fast_reason"])")
    isempty(d["full_reason"]) || println("      full: $(d["full_reason"])")
end
