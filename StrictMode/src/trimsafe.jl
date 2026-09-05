# Trim-safety guarantee, powered by TypeContracts (already a core dep — no backend needed).
#
# PROACTIVE: `@assert_trim_safe` and the `:trimsafe` guarantee scan a method's typed IR for what
# `juliac --trim=safe` rejects — dynamic dispatch (a call whose result infers to `Any`), a call left
# unresolved by exceeding the union-split limit (`_union_split_findings`), and
# reflection (`return_types`/`invokelatest`/`which`/`methods`) — via `TypeContracts.trim_report`.
# Value-free and dependency-free.
#
# REACTIVE: `explain_trim` translates raw `juliac --trim` verifier output into a source-mapped
# explanation (via `TypeContracts.explain_trim_failure`).

_base_trim_report(@nospecialize(f), @nospecialize(types::Tuple)) = TypeContracts.trim_report(f, Tuple{types...})

# The union-split rule (issue #13). `TypeContracts.trim_report` finds dynamic dispatch by asking
# whether a call's RESULT infers to `Any`; this class infers a perfectly concrete result and is
# still rejected, so that rule structurally cannot see it.
#
# juliac materializes a call's specializations only while the product of its arguments' union
# cardinalities stays within inference's `max_union_splitting`. Past that the call is left
# unresolved, and `verify_typeinf_trim` rejects it from the ccallable root. The signal is therefore
# a call that SURVIVES optimization with union-typed arguments whose product exceeds the limit. It
# agrees with the verifier on the shapes that bracket the boundary:
#
#   sink(::Val,::Val,::Val,::Val) = 0, four runtime Vals   verifier PASS   no call survives (inlined)
#   two runtime Vals into a large callee                   verifier PASS   no call survives (2^2 = 4)
#   three runtime Vals into a large callee                 verifier FAIL   :call, product 8
#   four runtime Vals into a large callee                  verifier FAIL   :call, product 16
#
# The two passing cases produce no signal on their own — a callee small enough to inline leaves no
# call to resolve, and a product within the limit is split by inference before optimization ends.
# So no callee size or opacity threshold is needed: the IR has already applied both.
# A resolved `:invoke` is excluded because it names one MethodInstance — there is nothing left to
# materialize.
function _union_split_findings(@nospecialize(f), @nospecialize(types::Tuple))
    out = String[]
    limit = Core.Compiler.InferenceParams().max_union_splitting
    sig = Base.signature_type(f, Tuple{types...})
    ci = try
        first(code_typed(f, Tuple{types...}; optimize = true))[1]
    catch
        return out                      # unanalyzable here is the caller's problem to report
    end
    for st in ci.code
        Meta.isexpr(st, :call) || continue
        callee = _static_callee(ci, st.args[1])
        # Builtins and intrinsics take `Any` without dispatching, so they never union-split.
        (callee isa Core.Builtin || callee isa Core.IntrinsicFunction) && continue
        product = 1
        nunion = 0
        for a in st.args[2:end]
            T = _stmt_arg_type(ci, sig, a)
            T isa Union || continue
            nunion += 1
            product *= length(Base.uniontypes(T))
        end
        product > limit || continue
        name = callee === nothing ? "call" : string(callee)
        push!(
            out,
            "unresolved call to `$name` with $nunion union-typed argument(s): $product " *
                "specializations exceeds max_union_splitting ($limit), so juliac cannot " *
                "materialize them and the call stays unresolved"
        )
    end
    return out
end

function _trim_report(@nospecialize(f), @nospecialize(types::Tuple))
    r = _base_trim_report(f, types)
    extra = _union_split_findings(f, types)
    isempty(extra) && return r
    return TypeContracts.TrimReport(r.entry, vcat(r.findings, extra), false)
end

# `_union_split_findings` covers the class the base scan misses, but the scan as a whole is still
# not the verifier: it models neither juliac.s wider reachability analysis nor the Base patches
# juliac applies before trim inference. A PASS reached only through it therefore gets a one-time
# session note, so a fast dev loop that never runs TrimCheck is not left reading a bare green.
# `status`/`reason` on the structured `StrictFinding` are deliberately left untouched (a heuristic
# PASS stays `:pass` with an empty reason, matching every other guarantee and the existing
# back-compat contract) — this is macro-path-only visibility, not a findings/check API change.
const _TRIM_HEURISTIC_CAVEAT = "StrictMode: this trim-safety PASS is from the static heuristic scan only " *
    "(TypeContracts.trim_report plus StrictMode's union-split rule), not juliac's authoritative " *
    "verifier — it models neither juliac's full reachability analysis nor the Base patches juliac " *
    "applies before trim inference. Verify with " *
    "`StrictModeTest.@test_trim_compatible` (or a real `juliac --trim=safe` build) before relying " *
    "on this pass alone."

const _TRIM_SAFE_DEPRECATED = "StrictMode: `@assert_trim_safe` is deprecated and will be removed. " *
    "It runs the same scan as `@assert_trim_compatible`, which is the name to use — the two spellings " *
    "answer one question. `StrictModeTest.@test_trim_compatible` remains the verifier-backed gate."

function _assert_trim_safe(target, @nospecialize(f), @nospecialize(types::Tuple))
    @warn _TRIM_SAFE_DEPRECATED maxlog = 1
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

!!! warning "Deprecated"
    Use [`@assert_trim_compatible`](@ref) instead — it runs this exact scan under the name that
    describes it. Two spellings for one question is surface with nothing behind it. This macro
    warns once per session and will be removed; `StrictModeTest`'s `@test_trim_compatible` remains
    the verifier-backed gate.

The same static scan as [`@assert_trim_compatible`](@ref), under an older name.

Report if `f(args...)` looks incompatible with `juliac --trim=safe` by a value-free
`TypeContracts.trim_report` scan of the typed IR: dynamic dispatch (a call whose result infers to
`Any`), reflection (`return_types`, `invokelatest`, `which`, `methods`), or a surviving call whose
arguments union-split past `max_union_splitting`. It never runs the verifier, so it needs no
`TrimCheck` dependency.

**This reports; it does not gate** — the scan does not model juliac's reachability limit, so a PASS
is incomplete and a FAIL is a guess about the same territory. `StrictModeTest`'s
`@test_trim_compatible` runs the real verifier and does gate. Advisory either way, so **not** part
of [`@strict`](@ref). Each argument is evaluated once; disabled builds expand to the bare call. The
reactive counterpart, for a real build failure, is [`explain_trim`](@ref).

!!! note "union-split call sites"
    A third rule covers the class the dispatch rule structurally cannot see: a call that survives
    optimization with union-typed arguments whose specialization product exceeds inference's
    `max_union_splitting`. juliac cannot materialize those, so the call stays unresolved and the
    verifier rejects it — while the caller still infers a concrete return type, which is why the
    "result infers to `Any`" rule misses it. A callee small enough to inline leaves no call behind,
    and a product within the limit is split before optimization ends, so neither needs a size or
    opacity threshold to be excluded.

!!! note "a PASS here is still not the verifier"
    This scan models neither juliac's full reachability analysis nor the Base patches juliac applies
    before trim inference, so a PASS logs a one-time session note saying so. Use
    `StrictModeTest.@test_trim_compatible` before relying on a green pass for a `juliac --trim` build.
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

Report if `f(args...)` looks incompatible with `juliac --trim=safe`: a static IR scan for dynamic
dispatch (a call whose result infers to `Any`), reflection
(`return_types`/`invokelatest`/`which`/`methods`), and calls left unresolved by exceeding the
union-split limit. Cheap, value-free, and needs no extra dependency.

**This reports; it does not gate.** The scan does not model juliac's reachability limit, so a PASS
is incomplete and a FAIL is a guess about the same territory. The authoritative check is
`StrictModeTest`'s `@test_trim_compatible`, which drives juliac's own `verify_typeinf_trim`
verifier over this exact signature and does gate. Advisory either way — *not* part of
[`@strict`](@ref), since juliac's whole-program verifier over the real build is the final word.

Each argument is evaluated once; disabled builds expand to the bare call. The reactive counterpart,
for a real build failure, is [`explain_trim`](@ref).

!!! note "a PASS here is still not the verifier"
    The scan models neither juliac's full reachability analysis nor the Base patches juliac applies
    before trim inference, so a PASS logs a one-time session note saying so.
    `StrictModeTest.@test_trim_compatible` runs the real verifier.
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
