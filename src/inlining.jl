# `@assert_inlined` — fail unless a call is inlined into its caller. Inlining is a compiler
# *heuristic*, not a guarantee, so this is explicitly **best-effort**: it compiles a tiny wrapper
# that calls `f(args...)`, inspects the wrapper's optimized typed IR, and fails if the call to
# `f` survives as an `:invoke` (i.e. it was *not* absorbed). A "not inlined" result is not
# necessarily a bug — it reports the compiler's decision under the current settings.

# Best-effort inlining detection from `(f, types)` alone (no values, no execution): compile a
# wrapper that calls `f`, scan its optimized IR for a surviving `:invoke` to `f`'s method.
# Returns `true` if the call was *not* inlined, `false` if it was, `nothing` if undeterminable
# (e.g. a builtin/intrinsic with no resolvable method — effectively always inlined).
function _inlined_survives(@nospecialize(f), @nospecialize(types::Tuple))
    local m
    try
        m = which(f, types)
    catch
        return nothing
    end
    wrapper = (args...) -> f(args...)
    cts = Base.code_typed(wrapper, types; optimize = true)
    isempty(cts) && return nothing
    for stmt in first(cts).first.code
        if Meta.isexpr(stmt, :invoke)
            # On recent Julia the `:invoke` target is a `CodeInstance` (whose `.def` is the
            # `MethodInstance`); older Julia uses the `MethodInstance` directly.
            a1 = stmt.args[1]
            mi = a1 isa Core.CodeInstance ? a1.def : a1
            mi isa Core.MethodInstance && mi.def === m && return true
        end
    end
    return false
end

function _assert_inlined(target, @nospecialize(f), @nospecialize(types::Tuple))
    if _inlined_survives(f, types) === true
        _fail(
            :inlined, target,
            "call to `$(which(f, types).name)` was not inlined — it survives as an `:invoke` at " *
                "the call site (inlining is a heuristic; this may be expected)."
        )
    end
    return nothing
end

"""
    @assert_inlined f(args...)

Fail unless the call to `f(args...)` is inlined into its caller (**best-effort**).

StrictMode compiles a tiny wrapper that makes the call, inspects its optimized typed IR, and
fails if the call survives as an `:invoke` — i.e. the compiler chose *not* to inline it. Because
inlining is a heuristic rather than a guarantee, a failure is informational: it means the
compiler did not inline this call under the current settings, which may or may not be a problem.
For that reason `@assert_inlined` is **not** part of [`@strict`](@ref).

Each argument is evaluated once; the macro evaluates to the call's value; disabled builds expand
to the bare call.

```julia
@inline   hot(x) = x * x + 1
@assert_inlined hot(3.0)        # ok: small, inlined

@noinline cold(x) = x * x + 1
@assert_inlined cold(3.0)       # throws: survives as an :invoke
```
"""
macro assert_inlined(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_inlined needs a call expression"))
    call = pos[1]
    target = string(call)
    p = _call_parts(call; types = get(opts, :types, nothing))

    checked = quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_assert_inlined)($target, $(p.checkfn), $(p.types))
        _val
    end
    return _gate(checked, esc(call))
end

# ── inline-suggestion audit ───────────────────────────────────────────────────────────────────
# The *inverse* of `_inlined_survives` (which asks "is `f` itself inlined into a trivial wrapper?").
# Here we walk `f`'s OWN optimized IR and collect the callees that survive as `:invoke` — i.e. the
# ones the compiler chose NOT to inline INTO `f`. Those are inline *candidates*. This is the
# automatic counterpart of `@assert_inlined`: instead of asserting one named call, a whole-package
# `audit(...; inline_suggest=true)` surfaces "consider `@inline` on X" for every non-inlined callee.
#
# Motivating case (PureFFT): a `@generated` SIMD codelet (`avx_colbf_prime`) called inside a runtime
# column loop stayed a non-inlined `:invoke` and ran ~0.7× — one `@inline` fixed it. `@generated`
# bodies are NOT inlined by default and are exactly the high-value flags here, especially in a loop.
#
# Findings are status `:info` — informational, NEVER a hard failure (`nfailures` ignores them). The
# honest floor: this reads Julia's *typed* IR; a tiny callee LLVM still inlines despite a Julia-level
# `:invoke` is a false positive. So the actionable signal is the `@generated` / in-loop flags + a
# benchmark, not the bare `:invoke`.

struct _NonInlinedCallee
    method::Method
    count::Int          # how many `:invoke` sites in `f` call it
    in_loop::Bool       # at least one site is inside a loop (back-edge span)
    generated::Bool     # the callee is a `@generated` method
end

# Back-edges in the optimized IR give a cheap "is statement `i` inside a loop?" test: a GotoNode /
# GotoIfNot whose target index is ≤ its own position spans the loop body `[target, pos]`.
# ponytail: span-overlap heuristic, not a real dominator/CFG loop analysis — upgrade to
# Core.Compiler's CFG if nested-loop precision ever matters; for "is this call in a hot loop" it's enough.
function _loop_spans(code)
    spans = Tuple{Int, Int}[]
    for (p, st) in enumerate(code)
        if st isa Core.GotoNode && st.label <= p
            push!(spans, (st.label, p))
        elseif st isa Core.GotoIfNot && st.dest <= p
            push!(spans, (st.dest, p))
        end
    end
    return spans
end
_in_loop(spans, i) = any(s -> s[1] <= i <= s[2], spans)

# A `@generated` method carries a `.generator`; ordinary methods don't.
_is_generated(mth::Method) = isdefined(mth, :generator)

# Callee `Method` from an `:invoke` arg1 (`CodeInstance` on Julia ≥1.12, `MethodInstance` older).
function _invoke_method(@nospecialize(a1))
    mi = a1 isa Core.CodeInstance ? a1.def : a1
    return mi isa Core.MethodInstance ? mi.def : nothing
end

# Skip Base/Core callees by default — they're rarely the user's to `@inline`, and a non-inlined
# Base call is usually intentional. The user's own kernels (the actionable ones) live elsewhere.
_is_base_core(m::Module) = (r = Base.moduleroot(m); r === Base || r === Core)

# Walk `f`'s optimized IR; aggregate every non-inlined callee by Method.
function _noninlined_callees(@nospecialize(f), @nospecialize(types::Tuple))
    cts = try
        Base.code_typed(f, types; optimize = true)
    catch
        return _NonInlinedCallee[]
    end
    isempty(cts) && return _NonInlinedCallee[]
    code = first(cts).first.code
    spans = _loop_spans(code)
    acc = Dict{Method, _NonInlinedCallee}()
    for (i, st) in enumerate(code)
        Meta.isexpr(st, :invoke) || continue
        mth = _invoke_method(st.args[1])
        mth isa Method || continue
        loop = _in_loop(spans, i)
        prev = get(acc, mth, nothing)
        acc[mth] = prev === nothing ?
            _NonInlinedCallee(mth, 1, loop, _is_generated(mth)) :
            _NonInlinedCallee(mth, prev.count + 1, prev.in_loop | loop, prev.generated)
    end
    return collect(values(acc))
end

# Priority: `@generated`-in-loop first (the regression case), then in-loop, then `@generated`, then rest.
_callee_priority(c::_NonInlinedCallee) = (c.generated && c.in_loop) ? 0 : c.in_loop ? 1 : c.generated ? 2 : 3

function _suggestion_finding(c::_NonInlinedCallee, md, fn, sg)
    flags = String[]
    c.generated && push!(flags, "@generated")
    c.in_loop && push!(flags, "in a loop")
    flagtxt = isempty(flags) ? "" : " (" * join(flags, ", ") * ")"
    sites = c.count == 1 ? "1 site" : "$(c.count) sites"
    reason = "hot-path callee `$(c.method.name)`$flagtxt not inlined into `$fn` — survives as :invoke ($sites). Consider `@inline`."
    sugg = "add `@inline` to `$(c.method.name)`. INFORMATIONAL (inlining is a heuristic): a tiny " *
        "callee may still be LLVM-inlined despite this Julia-IR :invoke — confirm the regression with a " *
        "benchmark. `@generated` callees are NOT inlined by default; an `@inline @generated` kernel " *
        "called in a loop is the high-value case (PureFFT measured ~0.7× without it)."
    return StrictFinding(md, fn, sg, :inline_suggestion, :info, string(c.method.file), Int(c.method.line), reason, sugg)
end

"""
    inline_suggestions(f, types; include_base = false, only_flagged = false) -> Vector{StrictFinding}
    inline_suggestions(mod::Module; only = nothing, exempt = (), include_base = false, only_flagged = true)

Scan optimized typed IR for callees the compiler did **not** inline, and return one informational
([`StrictFinding`](@ref) with `status = :info`) "consider `@inline`" suggestion per non-inlined callee.
This is the automatic, whole-function/whole-module counterpart of [`@assert_inlined`](@ref): you don't
name the call site, the scan finds them.

The `(f, types)` form walks `f`'s own IR. The `Module` form sweeps every concrete method specialization
the module has compiled (like [`check_compiled`](@ref); warm your kernels first), scoping with
`only` / `exempt` (a collection of names/functions, a `Regex`, or a predicate).

Callees are **flagged** when they are `@generated` and/or appear **inside a loop** in the caller's IR —
those are the ones that actually regress (the PureFFT `avx_colbf_prime` case: a `@generated` codelet in a
column loop ran ~0.7× until marked `@inline`). `only_flagged = true` keeps just those (the module form
defaults to it to stay quiet); the single-function form shows all by default. Base/Core callees are
skipped unless `include_base = true`.

These findings are **never failures** — [`nfailures`](@ref) ignores them, so they never break a gate.
Inlining is a heuristic: a tiny callee LLVM still inlines despite a Julia-IR `:invoke` is a false positive,
so treat a suggestion as a prompt to *benchmark*, not a verdict.

```julia
audit(MyPkg; inline_suggest = true, format = :text)          # whole-package, incl. suggestions
inline_suggestions(my_caller, (Vector{Float64},))            # one function's non-inlined callees
```
"""
function inline_suggestions(
        @nospecialize(f), @nospecialize(types::Tuple);
        include_base::Bool = false, only_flagged::Bool = false,
    )
    md, fn, sg = _mod_sym(f), _func_name(f), _sig_string(types)
    callees = _noninlined_callees(f, types)
    sort!(callees; by = c -> (_callee_priority(c), -c.count))
    out = StrictFinding[]
    for c in callees
        (!include_base && _is_base_core(c.method.module)) && continue
        (only_flagged && !(c.generated || c.in_loop)) && continue
        push!(out, _suggestion_finding(c, md, fn, sg))
    end
    return out
end

function inline_suggestions(
        mod::Module;
        only = nothing, exempt = (), include_base::Bool = false, only_flagged::Bool = true,
    )
    exemptpred = _name_matcher(exempt)
    onlypred = _name_matcher(only)
    out = StrictFinding[]
    for nm in names(mod; all = true)
        isdefined(mod, nm) || continue
        f = getfield(mod, nm)
        (f isa Function && parentmodule(f) === mod) || continue
        (_is_exempt(f) || (exemptpred !== nothing && exemptpred(f))) && continue
        onlypred === nothing || onlypred(f) || continue
        for mth in methods(f)
            for mi in _specializations(mth)
                tt = try
                    Tuple((mi.specTypes::DataType).parameters[2:end])
                catch
                    continue
                end
                all(isconcretetype, tt) || continue
                try
                    append!(out, inline_suggestions(f, tt; include_base, only_flagged))
                catch err
                    err isa StrictViolation && rethrow()
                end
            end
        end
    end
    return out
end
