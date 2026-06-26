# Trim-safety guarantee, powered by TypeContracts (already a core dep — no backend needed).
#
# PROACTIVE: `@assert_trim_safe` and the `:trimsafe` guarantee scan a method's typed IR for what
# `juliac --trim=safe` rejects — dynamic dispatch (a call whose result infers to `Any`) and
# reflection (`return_types`/`invokelatest`/`which`/`methods`) — via `TypeContracts.trim_report`.
# Value-free, so it works in both `:fast` and `:full` with no AllocCheck/JET backend.
#
# REACTIVE: `explain_trim` translates raw `juliac --trim` verifier output into a source-mapped
# explanation (via `TypeContracts.explain_trim_failure`).

_trim_report(@nospecialize(f), @nospecialize(types::Tuple)) = TypeContracts.trim_report(f, Tuple{types...})

function _assert_trim_safe(target, @nospecialize(f), @nospecialize(types::Tuple))
    r = _trim_report(f, types)
    r.passed || _fail(
        :trimsafe, target,
        "likely trim-unsafe ($(length(r.findings)) site(s); juliac --trim=safe is authoritative):\n  " *
            join(r.findings, "\n  ")
    )
    return nothing
end

"""
    @assert_trim_safe f(args...)

The **static-only subset** of [`@assert_trim_compatible`](@ref), kept for compatibility — **prefer
`@assert_trim_compatible`**, which is identical here but *escalates* to juliac's real verifier in `:full`.

Fail unless `f(args...)` looks compatible with `juliac --trim=safe` by a value-free `TypeContracts.trim_report`
scan of the typed IR: no dynamic dispatch (a call whose result infers to `Any`) or reflection
(`return_types`, `invokelatest`, `which`, `methods`). It never runs the verifier, so it needs no `TrimCheck`
dependency and stays cheap in *any* mode — use it only when you specifically want the always-static check.
**Best-effort, advisory** — juliac's whole-program verifier is authoritative — so **not** part of
[`@strict`](@ref). Each argument is evaluated once; disabled builds expand to the bare call. The reactive
counterpart, for a real build failure, is [`explain_trim`](@ref).
"""
macro assert_trim_safe(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)
    checked = quote
        $(binds...)
        local _val = $litcall
        $(_assert_trim_safe)($target, $fe, $types)
        _val
    end
    return _gate(checked, esc(call))
end

# ── `trim_compatible`: escalating trim guarantee ──────────────────────────────────────────────────
# `:fast` (or when TrimCheck is not loaded) = TypeContracts static IR scan (the `@assert_trim_safe`
# subset). `:full` + TrimCheck loaded = juliac's authoritative `verify_typeinf_trim` verifier (via the
# `_be_trim_validate` backend). Returns `(passed, findings, authoritative)`.
function _trim_compatible_check(@nospecialize(f), @nospecialize(types::Tuple))
    if analysis_mode() === :full && trimcheck_available()
        passed, findings = _be_trim_validate(f, Tuple{types...})
        return (passed, findings, true)
    end
    r = _trim_report(f, types)
    return (r.passed, r.findings, false)
end

function _assert_trim_compatible(target, @nospecialize(f), @nospecialize(types::Tuple))
    passed, findings, authoritative = _trim_compatible_check(f, types)
    passed || _fail(
        :trim_compatible, target,
        (authoritative ?
            "trim-incompatible — juliac --trim=safe verifier rejected $(length(findings)) site(s):\n  " :
            "likely trim-incompatible ($(length(findings)) site(s); static heuristic — add TrimCheck and " *
                "run in :full for the authoritative juliac verifier):\n  ") *
            join(findings, "\n  ")
    )
    return nothing
end

"""
    @assert_trim_compatible f(args...)

Fail unless `f(args...)` is compatible with `juliac --trim=safe`. **Escalating** by [`analysis_mode`](@ref):

- `:fast` (or when `TrimCheck` is not loaded) — TypeContracts' static IR scan for dynamic dispatch (a
  call whose result infers to `Any`) and reflection (`return_types`/`invokelatest`/`which`/`methods`).
  Cheap and value-free.
- `:full` with `TrimCheck` loaded — juliac's authoritative `verify_typeinf_trim` verifier over this exact
  signature.

Advisory and **opt-in** — *not* part of [`@strict`](@ref): juliac's whole-program verifier over the real
build is the final word. Each argument is evaluated once; disabled builds expand to the bare call. The
cheaper static-only form is [`@assert_trim_safe`](@ref); the reactive counterpart, for a real build
failure, is [`explain_trim`](@ref).
"""
macro assert_trim_compatible(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)
    checked = quote
        $(binds...)
        local _val = $litcall
        $(_assert_trim_compatible)($target, $fe, $types)
        _val
    end
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
