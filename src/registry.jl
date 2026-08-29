# Mark-once registry + drivers. `@strict_function`/`@strict module` register `(f, types)` here;
# `check_all` re-checks the registry, `check_compiled` does the usage-driven sweep, and
# `_auto_check_module` is the automatic-at-load hook.

const STRICT_REGISTRY = Dict{Any, @NamedTuple{guarantees::Any}}()

"""
    register_strict!(f, types; guarantees = (:typestable, :noalloc))

Record that `f` with concrete signature `types` should satisfy `guarantees`, so the automatic
drivers ([`check_all`](@ref), `@strict module`, the Revise loop) re-check it. Non-concrete
signatures are dropped with a warning (nothing to analyze).
"""
function register_strict!(@nospecialize(f), @nospecialize(types); guarantees = (:typestable, :noalloc))
    tt = Tuple(types)
    # `isdispatchtuple`, not `all(isconcretetype, tt)`: a `::Type{T}` argument is a valid,
    # fully-specified dispatch signature (there's exactly one value of `Type{Float64}`), but
    # `isconcretetype(Type{Float64})` is `false` — a real Julia quirk that would otherwise skip
    # every `::Type{T}`-argument function, silently, including the GKH-dispatch idiom this
    # package's own `:static_ownership` guarantee recommends.
    if !Base.isdispatchtuple(Tuple{tt...})
        @warn "register_strict!: skipping $(_func_name(f))$(_sig_string(tt)) — non-concrete argument types."
        return nothing
    end
    STRICT_REGISTRY[(f, tt)] = (; guarantees)
    return nothing
end

"""
    registered_strict() -> Dict

The mark-once registry: `(f, types) => (; guarantees)` for everything tagged strict.
"""
registered_strict() = STRICT_REGISTRY

# Function names explicitly opted *out* of checking (cold / intentionally-allocating code), via
# `@strict_exempt`. Rust-like: in a `@strict module` everything is hot by default; you opt the
# rare cold helper out, not the hot code in.
const STRICT_EXEMPT = Set{Symbol}()

_is_exempt(@nospecialize(f)) = _demangle(nameof(f)) in STRICT_EXEMPT
_exempt!(name::Symbol) = (push!(STRICT_EXEMPT, name); nothing)

"""
    exempt_strict() -> Set{Symbol}

The set of function names marked cold/exempt by `@strict_exempt`.
"""
exempt_strict() = STRICT_EXEMPT

# ponytail: pinned to `false`. This was `mode === :fast && nthreads() > 1` — serial for `:full`,
# since AllocCheck/JET hold global compiler state. Now that `:fast` is the default it would flip
# threading ON by default, which is a behaviour change riding along on a deletion. `findings` is
# cache-locked and thread-safe, so flip this deliberately as its own change; `parallel=true` still
# opts in per call.
_default_parallel(::Symbol) = false

# A per-item analysis error is swallowed so one unanalyzable method can't sink a whole sweep. But a
# MISSING BACKEND is not a per-item problem — it fails every item identically, and swallowing it
# turns `mode = :full` into a silent, vacuous green: the same sweep that reports 53 findings at
# `:fast` reported 0 findings / 0 failures at `:full` with no backend loaded, exit code 0. That is
# the exact failure mode `assert_enabled` exists to prevent, reached through a different door, and it
# lands in `audit` — the driver the Stop hook and the consumer gate scripts run. Rethrow it.
_is_fatal_sweep_error(err) = err isa StrictViolation || err isa BackendUnavailable
# A per-item analysis error is not fatal to the sweep — one unanalyzable method must not sink it.
# But it must not VANISH either: silently dropping the item means a sweep reports success for a
# method it never checked, which is the same "could not check" == "is fine" conflation that made a
# crashed backend report `:pass`. Emit a `:skip` finding naming the method and the error instead.
function _skips_for(@nospecialize(f), @nospecialize(types::Tuple), gs, err)
    fn, sg, md = _func_name(f), _sig_string(types), _mod_sym(f)
    why = "analysis errored for this signature: " * sprint(showerror, err)
    return StrictFinding[_skipfinding(md, fn, sg, g, why) for g in gs]
end

function _map_findings(items::Vector, parallel::Bool, mode::Symbol)
    if parallel && length(items) > 1
        results = Vector{Vector{StrictFinding}}(undef, length(items))
        fatal = Ref{Any}(nothing)
        Threads.@threads for i in eachindex(items)
            f, types, gs = items[i]
            results[i] = try
                findings(f, types; guarantees = gs, mode)
            catch err
                _is_fatal_sweep_error(err) && (fatal[] = err)
                _skips_for(f, types, gs, err)
            end
        end
        fatal[] === nothing || throw(fatal[])
        return reduce(vcat, results; init = StrictFinding[])
    end
    out = StrictFinding[]
    for (f, types, gs) in items
        try
            append!(out, findings(f, types; guarantees = gs, mode))
        catch err
            _is_fatal_sweep_error(err) && rethrow()
            append!(out, _skips_for(f, types, gs, err))
        end
    end
    return out
end

# `fail_on_suspect` lets a consumer opt OUT of treating the `:fast` engine's structural guesses as
# failures. Default `true`: nothing is disarmed, because a sweep that stops gating allocations reads
# green while sitting on a real regression, and the only signal is a count in a line of text. What
# `:suspect` buys is that it renders distinctly, is separately countable, and cannot abort a build at
# LOAD time. A consumer who wants a non-blocking precompile passes `false` here. The durable
# answer is to add `StrictModeTest`, which re-issues every one of these as a proved `:pass`/`:fail`.
function _run_and_report(
        fs::Vector{StrictFinding}, kind::Symbol, target, fail::Symbol;
        fail_on_suspect::Bool = true
    )
    failed = filter(f -> f.status === :fail || (fail_on_suspect && f.status === :suspect), fs)
    if !isempty(failed) && fail !== :none
        msg = sprint(io -> format_findings(io, failed; format = :text))
        fail === :error ? throw(StrictViolation(kind, target, msg)) : @warn msg
    end
    return fs
end

"""
    check_all(; guarantees = nothing, fail = :none) -> Vector{StrictFinding}

Re-check every entry in the mark-once registry and return all findings. `guarantees = nothing`
uses each entry's own setting; pass a tuple to override. `fail = :error`/`:warn` raises/logs on
any failure, `:none` just returns the findings (the default — it is a reporting driver).

!!! warning "Same-process only"
    The registry is a plain `Dict` populated at *declaration* time. `@strict_function` runs at its
    own module's precompile, and that cross-package mutation is discarded when the module is loaded
    from a cached pkgimage — so **a consumer's test process sees an empty registry however many
    declarations its `src/` carries**, and this driver would then return zero findings and exit 0.
    It warns loudly in that case rather than reporting a silent green. For a consumer, use
    [`check_signatures`](@ref) or `audit(MyPkg; sweep = true)`, which enumerate directly.
"""
function check_all(;
        guarantees = nothing, fail::Symbol = :none,
        mode::Symbol = :fast, parallel::Bool = _default_parallel(mode),
    )
    items = Any[
        (f, types, guarantees === nothing ? meta.guarantees : guarantees)
            for ((f, types), meta) in STRICT_REGISTRY if !_is_exempt(f)
    ]
    if isempty(items)
        # An empty registry renders exactly like a clean one: zero findings, exit 0. That is the
        # whole failure mode this package exists to remove, and it is REACHABLE BY DEFAULT in a
        # consumer, not just when nothing was declared: `@strict_function` registers through a
        # `register_strict!` Dict insert executed at the ANNOTATED MODULE'S OWN PRECOMPILE, and that
        # cross-package mutation is discarded when the module is loaded from its cached pkgimage. So
        # a consumer's test process sees an empty registry no matter how many declarations its
        # `src/` carries. `check_signatures`/`audit(mod; sweep=true)` are unaffected — they
        # enumerate directly instead of reading this Dict.
        @warn "check_all: the registry is EMPTY (0 checks) — this result proves nothing. " *
            "`@strict_function` registers at its own module's precompile, and that registration " *
            "does not survive a cached pkgimage load, so a consumer's test process sees no entries " *
            "even when its `src/` is fully annotated. Use `check_signatures([(f, types), …])` or " *
            "`audit(MyPkg; sweep = true)`, which enumerate directly. (An empty registry is also " *
            "legitimate when nothing is declared, or everything is exempt.)"
    end
    return _run_and_report(_map_findings(items, parallel, mode), :check_all, "registry", fail)
end

"""
    check_signatures(pairs; guarantees = (:typestable, :noalloc), fail = :none, mode = :fast)

Check an explicit list of `(f, types)` pairs — the declarative "check what I promise" path that
needs **no `src` annotations**. A test suite can list a library's guaranteed entry points without
the library itself depending on StrictMode:

```julia
check_signatures([(dot3, (NTuple{3,Float64}, NTuple{3,Float64})), (kernel, (Matrix{Float64},))]; fail = :error)
```
"""
function check_signatures(pairs; guarantees = (:typestable, :noalloc), fail::Symbol = :none, mode::Symbol = :fast)
    items = Any[(f, Tuple(types), guarantees) for (f, types) in pairs]
    return _run_and_report(_map_findings(items, _default_parallel(mode), mode), :check_signatures, "signatures", fail)
end

# Findings for the *registered* (declared-guarantee) functions belonging to `mod` — the "check
# what I promised" scope, as opposed to the whole-module sweep.
function _registered_findings_in(mod::Module; guarantees = nothing, fast::Bool = false, mode::Symbol = :fast)
    out = StrictFinding[]
    for ((f, types), meta) in STRICT_REGISTRY
        _mod_sym(f) === nameof(mod) || continue
        _is_exempt(f) && continue                        # cold / @strict_exempt → skip
        gs = guarantees === nothing ? meta.guarantees : guarantees
        try
            fs = fast ?
                _findings_fast(f, types, gs, _mod_sym(f), _func_name(f), _sig_string(types)) :
                findings(f, types; guarantees = gs, mode)
            append!(out, fs)
        catch err
            err isa StrictViolation && rethrow()
        end
    end
    return out
end

# Whole-module strict check at load. Always uses the cheap `:fast` triage (no AllocCheck/JET
# backend needed), so opting a module into strict mode stays affordable on every load — the
# rigorous `:full` proof is run explicitly via `audit`/`check_all` in CI.
function _auto_check_module(mod::Module)
    CHECKS_ENABLED || return nothing
    _run_and_report(_registered_findings_in(mod; fast = true), :strict_module, string(nameof(mod)), :error)
    return nothing
end

# --- `@strict module … end` rewriting (called from the @strict macro in macros.jl) ------------

function _maybe_register_stmt(stmt)
    (Meta.isexpr(stmt, :function) || Meta.isexpr(stmt, :(=))) || return nothing
    sig = try
        _strictdef_sig(stmt)
    catch
        return nothing
    end
    Meta.isexpr(sig, :call) || return nothing
    fname = sig.args[1]
    fname isa Symbol || return nothing
    argexprs = filter(a -> !Meta.isexpr(a, :parameters), sig.args[2:end])
    argtypes = Expr(:tuple, (_argtype(a) for a in argexprs)...)
    return :($(register_strict!)($fname, $argtypes))
end

# Is `stmt` a `@strict_exempt …` macrocall (bare or qualified)?
function _is_strict_exempt_call(stmt)
    Meta.isexpr(stmt, :macrocall) || return false
    nm = stmt.args[1]
    nm === Symbol("@strict_exempt") && return true
    return nm isa Expr && nm.head === :. && nm.args[end] == QuoteNode(Symbol("@strict_exempt"))
end

# Statements to emit inside a `@strict module` for one body statement: plain defs are kept and
# registered hot; `@strict_exempt …` is inlined (the module doesn't import StrictMode, so we
# splice the exempt logic with interpolated function values instead of leaving the macrocall).
function _rewrite_strict_stmt(stmt)
    if _is_strict_exempt_call(stmt)
        inner = stmt.args[end]
        if Meta.isexpr(inner, (:function, :(=)))
            sig = try
                _strictdef_sig(inner)
            catch
                nothing
            end
            fname = (sig !== nothing && Meta.isexpr(sig, :call) && sig.args[1] isa Symbol) ? sig.args[1] : nothing
            out = Any[inner]
            fname === nothing || push!(out, :($(_exempt!)($(QuoteNode(fname)))))
            return out
        end
        name = inner isa QuoteNode ? inner.value : inner
        return name isa Symbol ? Any[:($(_exempt!)($(QuoteNode(name))))] : Any[stmt]
    end
    reg = _maybe_register_stmt(stmt)
    return reg === nothing ? Any[stmt] : Any[stmt, reg]
end

function _strict_module(modexpr::Expr)
    body = modexpr.args[3]::Expr
    newstmts = Any[]
    for stmt in body.args
        append!(newstmts, _rewrite_strict_stmt(stmt))
    end
    push!(newstmts, :($(_auto_check_module)(@__MODULE__)))
    newmod = Expr(:module, modexpr.args[1], modexpr.args[2], Expr(:block, newstmts...))
    # `esc` so the user's definitions keep their own meaning (no hygiene renaming of the module
    # contents). `@strict module … end` must therefore be used at true top level (script / REPL /
    # package), like any module definition.
    return esc(newmod)
end

# --- usage-driven sweep (the hybrid half) -----------------------------------------------------

# Method specializations are a SimpleVector / a lone MethodInstance / nothing depending on
# version; normalize defensively.
function _specializations(mth::Method)
    s = mth.specializations
    s isa Core.MethodInstance && return Any[s]
    s isa Core.SimpleVector && return Any[x for x in s if x isa Core.MethodInstance]
    return Any[]
end

# Normalize a function or a name Symbol to its name Symbol (for the only/exempt filters).
_asname(x) = x isa Symbol ? x : nameof(x)

# Strip the keyword-sorter mangling (`#funcname#NN`) so `only`/`exempt` match keyword-argument methods by
# their base name — a user who exempts `:foo` means `foo(...; kw...)` too (its kwsorter is `#foo#NN`).
function _demangle(nm::Symbol)
    s = String(nm)
    m = match(r"^#(.+)#\d+$", s)
    return m === nothing ? nm : Symbol(m.captures[1]::AbstractString)
end

# Build a `f -> Bool` predicate from an `only`/`exempt` spec, so a mixed hot/cold library can be
# scoped without a growing hand-listed set: a `Function` is used as-is, a `Regex` matches the
# (demangled) function name, and a collection matches by name / function. `nothing` → no filter.
function _name_matcher(spec)
    spec === nothing && return nothing
    spec isa Function && return spec
    spec isa Regex && return f -> occursin(spec, string(_demangle(nameof(f))))
    set = Set{Symbol}(_asname(x) for x in spec)
    return f -> _demangle(nameof(f)) in set
end

# Shared module-sweep core: every `(f, tt)` pair — a concrete dispatch-tuple specialization `mod`
# has actually compiled — across its own functions matching `only`/`exempt`. `check_compiled`,
# `static_ownership_suggestions(mod)`, and `inline_suggestions(mod)` all walk the exact same set;
# this is the one place that does it, so scoping/filtering bugs get fixed once.
function _module_specializations(f!::Function, mod::Module; only = nothing, exempt = ())
    exemptpred = _name_matcher(exempt)
    onlypred = _name_matcher(only)
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
                Base.isdispatchtuple(Tuple{tt...}) || continue
                f!(f, tt)
            end
        end
    end
    return nothing
end

"""
    check_compiled(mod::Module; guarantees = (:typestable, :noalloc), fail = :none,
                   only = nothing, exempt = ()) -> Vector{StrictFinding}

Usage-driven sweep: check the concrete method instances `mod`'s functions have **actually
compiled** (during your tests / a run / the precompile workload). No annotation needed, but
coverage is whatever executed, and a module that mixes hot and cold (plan-time) helpers will be
noisy — cold helpers that legitimately allocate show up too. Scope it with:

- `only` / `exempt` — each a collection of functions / name `Symbol`s, a **`Regex`** matched
  against the (demangled) name, or a **predicate** `f -> Bool`. `@strict_exempt` names are always
  excluded. So `exempt = r"^_plan"` or `exempt = f -> startswith(string(nameof(f)), "_")` scales
  a mixed hot/cold library without a hand-listed set.

Prefer the *declared-guarantee* path ([`@strict_function`](@ref) / `@strict module` /
[`check_all`](@ref)) for "check what I promised"; this sweep is "check what actually ran".
Best-effort — it walks compiler reflection defensively and skips anything it cannot analyze.
"""
function check_compiled(
        mod::Module;
        guarantees = (:typestable, :noalloc),
        fail::Symbol = :none,
        only = nothing,
        exempt = (),
        mode::Symbol = :fast,
        parallel::Bool = _default_parallel(mode),
    )
    items = Any[]
    _module_specializations(mod; only, exempt) do f, tt
        push!(items, (f, tt, guarantees))
    end
    if isempty(items)
        @warn "check_compiled: no compiled method specializations matched in `$(nameof(mod))` " *
            "(0 checks). Warm the kernels first — call them once so a concrete specialization exists " *
            "— and note `only`/`exempt` and generically-typed signatures can also exclude everything."
    end
    return _run_and_report(_map_findings(items, parallel, mode), :check_compiled, string(nameof(mod)), fail)
end

# Coverage gate (`audit(mod; require = :public)`): one :fail finding per exported/public
# function of `mod` that is neither registered (`register_strict!` / `@strict_function`) nor
# exempted. Turns "every kernel declares its guarantees" from a convention into a red test.
# Not a checkable guarantee — findings are built directly, never routed through _build_finding.
function _coverage_findings(mod::Module; only = nothing, exempt = ())
    exemptpred = _name_matcher(exempt)
    onlypred = _name_matcher(only)
    registered = Set{Any}(k[1] for k in keys(STRICT_REGISTRY))
    out = StrictFinding[]
    for nm in names(mod)   # exported + `public` on 1.12; macros/gensyms filtered below
        s = String(nm)
        (startswith(s, '#') || startswith(s, '@')) && continue
        isdefined(mod, nm) || continue
        f = getfield(mod, nm)
        (f isa Function && parentmodule(f) === mod) || continue
        (_is_exempt(f) || (exemptpred !== nothing && exemptpred(f))) && continue
        onlypred === nothing || onlypred(f) || continue
        f in registered && continue
        m = first(methods(f))
        push!(
            out, StrictFinding(
                nameof(mod), s, "", :coverage, :fail, string(m.file), Int(m.line),
                "public function `$s` has no registered StrictMode guarantee",
                "declare it: `StrictMode.register_strict!($s, (T1, …); guarantees = (:typestable, :noalloc))` " *
                    "in the test setup (then `check_all()` enforces it), or opt it out explicitly " *
                    "with `@strict_exempt $s` / the `exempt` kwarg if it is cold by design."
            )
        )
    end
    return out
end

# --- Revise live loop plumbing (the extension fills these in) ----------------------------------

const _REVISE_WATCH = Ref{Any}(nothing)
const _REVISE_UNWATCH = Ref{Any}(nothing)

"""
    watch()

Start the live re-checking loop: after each Revise edit, re-check the strict registry and print
violations. Requires Revise — `using Revise` (which loads the StrictMode↔Revise extension) before
calling. The human counterpart to [`audit`](@ref) (the agent path).
"""
function watch()
    _REVISE_WATCH[] === nothing && return @info "StrictMode.watch() needs Revise: run `using Revise` first."
    return _REVISE_WATCH[]()
end

"""
    unwatch()

Stop the live re-checking loop started by [`watch`](@ref).
"""
function unwatch()
    _REVISE_UNWATCH[] === nothing && return nothing
    return _REVISE_UNWATCH[]()
end
