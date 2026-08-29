# Trim-safety guarantee, powered by TypeContracts (already a core dep — no backend needed).
#
# PROACTIVE: `@assert_trim_safe` and the `:trimsafe` guarantee scan a method's typed IR for what
# `juliac --trim=safe` rejects — dynamic dispatch (a call whose result infers to `Any`) and
# reflection (`return_types`/`invokelatest`/`which`/`methods`) — via `TypeContracts.trim_report`.
# Value-free and dependency-free.
#
# REACTIVE: `explain_trim` translates raw `juliac --trim` verifier output into a source-mapped
# explanation (via `TypeContracts.explain_trim_failure`).

_trim_report(@nospecialize(f), @nospecialize(types::Tuple)) = TypeContracts.trim_report(f, Tuple{types...})

# issue #13: the static heuristic (`TypeContracts.trim_report`) misses a real trim-incompatibility
# class that TrimCheck's authoritative `verify_typeinf_trim` catches — N simultaneous
# runtime `Union{Val,...}`-shaped arguments whose 2^N specialization count can exceed juliac's
# reachability/union-split limit. A trivial, small callee does NOT trip this (the trimmer resolves
# every instance when the callee is simple); it only shows up with a large/opaque callee where the
# union propagates past what inference can collapse — so a per-call-site static scan cannot
# reliably discriminate the safe case from the dangerous one (flagging heuristically would
# false-positive on exactly the callees the issue's own repro proves are fine). No warn-tier
# heuristic is added for that reason; instead, a PASS reached only via the static scan (not the
# authoritative verifier) gets a one-time session note that this class isn't covered — a fast
# dev-loop check that never reaches TrimCheck would otherwise get no signal at all
# for it. `status`/`reason` on the structured `StrictFinding` are deliberately left untouched (a
# heuristic PASS stays `:pass` with an empty reason, matching every other guarantee and the
# existing back-compat contract) — this is macro-path-only visibility, not a findings/check API
# change.
const _TRIM_HEURISTIC_CAVEAT = "StrictMode: this trim-safety PASS is from the static heuristic scan only " *
    "(TypeContracts.trim_report), not juliac's authoritative verifier — it does not cover " *
    "reachability-limit union-splits (N simultaneous small-Union arguments whose 2^N specialization " *
    "count can exceed juliac's split limit on a large/opaque callee). Verify with " *
    "`StrictModeTest.@test_trim_compatible` (or a real `juliac --trim=safe` build) before relying " *
    "on this pass alone."

function _assert_trim_safe(target, @nospecialize(f), @nospecialize(types::Tuple))
    r = _trim_report(f, types)
    if r.passed
        @info _TRIM_HEURISTIC_CAVEAT maxlog = 1
        return nothing
    end
    _fail(
        :trimsafe, target,
        "likely trim-unsafe ($(length(r.findings)) site(s); juliac --trim=safe is authoritative):\n  " *
            join(r.findings, "\n  ")
    )
    return nothing
end

"""
    @assert_trim_safe f(args...)

The same static scan as [`@assert_trim_compatible`](@ref), kept as a distinct name for call sites
that want to say "static scan" explicitly.

Report if `f(args...)` looks incompatible with `juliac --trim=safe` by a value-free
`TypeContracts.trim_report` scan of the typed IR: dynamic dispatch (a call whose result infers to
`Any`) or reflection (`return_types`, `invokelatest`, `which`, `methods`). It never runs the
verifier, so it needs no `TrimCheck` dependency.

**This reports; it does not gate** — the scan does not model juliac's reachability limit, so a PASS
is incomplete and a FAIL is a guess about the same territory. `StrictModeTest`'s
`@test_trim_compatible` runs the real verifier and does gate. Advisory either way, so **not** part
of [`@strict`](@ref). Each argument is evaluated once; disabled builds expand to the bare call. The
reactive counterpart, for a real build failure, is [`explain_trim`](@ref).

!!! note "known gap: reachability-limit union-splits"
    This static scan does **not** catch every trim-incompatibility juliac's real verifier does — in
    particular, N simultaneous runtime `Union{Val,…}`-shaped arguments whose 2ᴺ specialization count
    can exceed juliac's reachability/union-split limit when the callee is large/opaque enough that
    inference can't collapse it (a trivial callee resolves fine and does *not* trip this). A scan
    that flagged every small-`Union`-heavy call site would false-positive on exactly the callees that
    are fine, so no heuristic is added for it — a PASS from this macro logs a one-time session note
    that this class isn't covered. Use `StrictModeTest.@test_trim_compatible` before relying on a
    green pass here for a `juliac --trim` build.
"""
macro assert_trim_safe(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_trim_safe needs a call expression"))
    call = pos[1]
    checked = _guarantee_expr(call, _assert_trim_safe; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
end

# ── `trim_compatible` ─────────────────────────────────────────────────────────────────────────────
# The TypeContracts static IR scan — the same engine as the `@assert_trim_safe` subset. juliac's
# authoritative `verify_typeinf_trim` verifier is `StrictModeTest`'s `@test_trim_compatible`.
function _assert_trim_compatible(target, @nospecialize(f), @nospecialize(types::Tuple))
    r = _trim_report(f, types)
    if r.passed
        @info _TRIM_HEURISTIC_CAVEAT maxlog = 1
        return nothing
    end
    _fail(
        :trim_compatible, target,
        "likely trim-incompatible ($(length(r.findings)) site(s); static scan — " *
            "`@test_trim_compatible` runs the authoritative juliac verifier):\n  " *
            join(r.findings, "\n  ")
    )
    return nothing
end

"""
    @assert_trim_compatible f(args...)

Report if `f(args...)` looks incompatible with `juliac --trim=safe`: TypeContracts' static IR scan
for dynamic dispatch (a call whose result infers to `Any`) and reflection
(`return_types`/`invokelatest`/`which`/`methods`). Cheap, value-free, and needs no extra dependency.

**This reports; it does not gate.** The scan does not model juliac's reachability limit, so a PASS
is incomplete and a FAIL is a guess about the same territory. The authoritative check is
`StrictModeTest`'s `@test_trim_compatible`, which drives juliac's own `verify_typeinf_trim`
verifier over this exact signature and does gate. Advisory either way — *not* part of
[`@strict`](@ref), since juliac's whole-program verifier over the real build is the final word.

Each argument is evaluated once; disabled builds expand to the bare call. The reactive counterpart,
for a real build failure, is [`explain_trim`](@ref).

!!! note "known gap: reachability-limit union-splits"
    A PASS here does not cover N-simultaneous-small-`Union`-argument call sites that can exceed
    juliac's reachability limit on a large/opaque callee (see [`@assert_trim_safe`](@ref) for why no
    heuristic is added for it), and it logs a one-time session note saying so.
    `StrictModeTest.@test_trim_compatible` does catch this class.
"""
macro assert_trim_compatible(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_trim_compatible needs a call expression"))
    call = pos[1]
    checked = _guarantee_expr(call, _assert_trim_compatible; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
end

"""
    StrictMode.explain_trim(output; entry_path = "", source_files = String[]) -> TypeContracts.TrimFailure

Reactive trim diagnostics: translate raw `juliac --trim` verifier output into a readable,
source-mapped explanation with per-site hints (via `TypeContracts.explain_trim_failure`). Pair it
with the proactive [`@assert_trim_compatible`](@ref) / `:trim_compatible` guarantee, e.g.:

```julia
out = read(pipeline(`juliac --trim=safe --output-exe app entry.jl`; stderr = "trim.log"), String)
showerror(stderr, StrictMode.explain_trim(out; entry_path = "entry.jl", source_files = ["src/MyPkg.jl"]))
```
"""
explain_trim(output::AbstractString; entry_path::AbstractString = "", source_files = String[]) =
    TypeContracts.explain_trim_failure(output; entry_path, source_files)
