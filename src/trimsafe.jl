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

Fail unless `f(args...)` looks compatible with `juliac --trim=safe`: its typed IR has no dynamic
dispatch (a call whose result infers to `Any`) or reflection (`return_types`, `invokelatest`,
`which`, `methods`), via `TypeContracts.trim_report`. **Best-effort, advisory** — juliac's
whole-program verifier is authoritative — so it is **not** part of [`@strict`](@ref). Each argument
is evaluated once; disabled builds expand to the bare call. The reactive counterpart, for a real
build failure, is [`explain_trim`](@ref).
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

"""
    StrictMode.explain_trim(output; entry_path = "", source_files = String[]) -> TypeContracts.TrimFailure

Reactive trim diagnostics: translate raw `juliac --trim` verifier output into a readable,
source-mapped explanation with per-site hints (via `TypeContracts.explain_trim_failure`). Pair it
with the proactive [`@assert_trim_safe`](@ref) / `:trimsafe` guarantee, e.g.:

```julia
out = read(pipeline(`juliac --trim=safe --output-exe app entry.jl`; stderr = "trim.log"), String)
showerror(stderr, StrictMode.explain_trim(out; entry_path = "entry.jl", source_files = ["src/MyPkg.jl"]))
```
"""
explain_trim(output::AbstractString; entry_path::AbstractString = "", source_files = String[]) =
    TypeContracts.explain_trim_failure(output; entry_path, source_files)
