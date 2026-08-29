# Mark-once registry + the shared item builders. `@strict_function`/`@strict module` register
# `(f, types)` here; `audit` renders findings for them, `StrictModeTest`'s `test_*` drivers gate on
# the same lists, and `_auto_check_module` is the automatic-at-load hook.

const STRICT_REGISTRY = Dict{Any, @NamedTuple{guarantees::Any}}()

"""
    register_strict!(f, types; guarantees = (:typestable, :noalloc))

Record that `f` with concrete signature `types` should satisfy `guarantees`, so the automatic
drivers (`audit`, `@strict module`, the Revise loop, and `StrictModeTest.test_registered`) re-check
it. Non-concrete signatures are dropped with a warning (nothing to analyze).
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

# A per-item analysis error is not fatal to a sweep — one unanalyzable method must not sink it.
# But it must not VANISH either: silently dropping the item means a sweep reports success for a
# method it never checked, which is the same "could not check" == "is fine" conflation that made a
# crashed backend report `:pass`. Emit a failing finding naming the method and the error instead.
function _errored_findings(@nospecialize(f), @nospecialize(types::Tuple), gs, err)
    fn, sg, md = _func_name(f), _sig_string(types), _mod_sym(f)
    why = "analysis errored for this signature: " * sprint(showerror, err)
    return StrictFinding[_unevaluated(md, fn, sg, g, why) for g in gs]
end

# Run `analyze(f, types, guarantees)` over `items`, collecting every result. Shared by StrictMode's
# reporting drivers and `StrictModeTest`'s gating ones, so both keep the same shape: no item is
# dropped, and one method that cannot be analyzed leaves the other 299 evaluated.
function _map_findings(analyze, items)
    out = StrictFinding[]
    for (f, types, gs) in items
        try
            append!(out, analyze(f, types, gs))
        catch err
            err isa StrictViolation && rethrow()
            append!(out, _errored_findings(f, types, gs, err))
        end
    end
    return out
end

function _run_and_report(fs::Vector{StrictFinding}, kind::Symbol, target, fail::Symbol)
    failed = filter(_failed, fs)
    if !isempty(failed) && fail !== :none
        msg = sprint(io -> format_findings(io, failed; format = :text))
        fail === :error ? throw(StrictViolation(kind, target, msg)) : @warn msg
    end
    return fs
end

# The registry as `(f, types, guarantees)` items, with exempted functions dropped. `guarantees`
# overrides each entry's own setting when given. `StrictModeTest.test_registered` re-runs exactly
# this list against the proofs, so both tiers agree on what "registered" means.
function _registry_items(guarantees = nothing)
    return Any[
        (f, types, isnothing(guarantees) ? meta.guarantees : guarantees)
            for ((f, types), meta) in STRICT_REGISTRY if !_is_exempt(f)
    ]
end

# An empty registry renders exactly like a clean one: zero findings, nothing to report. That is the
# failure mode this package exists to remove, and it is REACHABLE BY DEFAULT in a consumer, not
# just when nothing was declared: `@strict_function` registers through a `register_strict!` Dict
# insert executed at the ANNOTATED MODULE'S OWN PRECOMPILE, and that cross-package mutation is
# discarded when the module is loaded from its cached pkgimage. So a consumer's test process sees
# an empty registry no matter how many declarations its `src/` carries. The signature-list and
# module-sweep paths are unaffected — they enumerate directly instead of reading this Dict.
function _warn_empty_registry(driver::AbstractString, alternative::AbstractString)
    @warn "$driver: the registry is EMPTY (0 checks) — this result proves nothing. " *
        "`@strict_function` registers at its own module's precompile, and that registration " *
        "does not survive a cached pkgimage load, so a consumer's test process sees no entries " *
        "even when its `src/` is fully annotated. Use $alternative, which enumerate directly. " *
        "(An empty registry is also legitimate when nothing is declared, or everything is exempt.)"
    return nothing
end

# Findings for every registered signature. Reporting only — `audit` renders these.
function _findings_all(; guarantees = nothing)
    items = _registry_items(guarantees)
    isempty(items) && _warn_empty_registry("audit(:registered)", "`audit(MyPkg; sweep = true)`")
    return _map_findings((f, types, gs) -> findings(f, types; guarantees = gs), items)
end

# Findings for the *registered* (declared-guarantee) functions belonging to `mod` — the "check
# what I promised" scope, as opposed to the whole-module sweep.
function _registered_findings_in(mod::Module; guarantees = nothing)
    items = Any[
        (f, types, isnothing(guarantees) ? meta.guarantees : guarantees)
            for ((f, types), meta) in STRICT_REGISTRY
            if _mod_sym(f) === nameof(mod) && !_is_exempt(f)   # cold / @strict_exempt → skip
    ]
    # Through `_map_findings`, so a signature whose analysis throws becomes a failing finding
    # naming the error rather than vanishing. This feeds `_auto_check_module` — the `@strict module`
    # load gate — where a dropped signature is a method that loads clean without being checked.
    return _map_findings((f, types, gs) -> findings(f, types; guarantees = gs), items)
end

# Whole-module strict check at load. Uses the value-free engine, which is what makes opting a
# module into strict mode affordable on every load; the proofs run from the test environment, where
# `StrictModeTest` is loadable and this module's own precompile is not happening.
function _auto_check_module(mod::Module)
    CHECKS_ENABLED || return nothing
    _run_and_report(_registered_findings_in(mod), :strict_module, string(nameof(mod)), :error)
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
# has actually compiled — across its own functions matching `only`/`exempt`. The compiled sweep,
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

# Every `(f, tt, guarantees)` item for the usage-driven sweep of `mod`: the concrete method
# instances its functions have ACTUALLY COMPILED. Coverage is therefore whatever executed, and a
# module that mixes hot and cold helpers is noisy unless scoped with `only`/`exempt`.
# `StrictModeTest.test_compiled` builds the same list, so both tiers sweep the same set.
function _compiled_items(mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = ())
    items = Any[]
    _module_specializations(mod; only, exempt) do f, tt
        push!(items, (f, tt, guarantees))
    end
    isempty(items) && @warn "StrictMode: no compiled method specializations matched in " *
        "`$(nameof(mod))` (0 checks). Warm the kernels first — call them once so a concrete " *
        "specialization exists — and note `only`/`exempt` and generically-typed signatures can " *
        "also exclude everything."
    return items
end

function _findings_compiled(mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = ())
    items = _compiled_items(mod; guarantees, only, exempt)
    return _map_findings((f, types, gs) -> findings(f, types; guarantees = gs), items)
end

# Coverage gate (`audit(mod; require = :public)`): one :fail finding per exported/public
# function of `mod` that is neither registered (`register_strict!` / `@strict_function`) nor
# exempted. Turns "every kernel declares its guarantees" from a convention into a red test.
# Not a checkable guarantee — findings are built directly, never routed through the engines.
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
                    "in the test setup (then `audit` reports it and `StrictModeTest.test_registered` gates on " *
                    "it), or opt it out explicitly " *
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
