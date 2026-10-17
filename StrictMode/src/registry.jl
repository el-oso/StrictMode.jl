# Mark-once registry + the shared item builders. `@strict_function`/`@strict module` register
# `(f, types)` here; `audit` renders findings for them, `StrictModeTest`'s `test_*` drivers gate on
# the same lists, and `_auto_check_module` is the automatic-at-load hook.

const STRICT_REGISTRY = Dict{Any, @NamedTuple{guarantees::Any, source::String}}()

# A declaration written during a package's own precompile cannot live in this Dict: StrictMode is
# already loaded from its own pkgimage then, and a cross-package mutation of it is discarded when
# the declaring package is next loaded from cache. A consumer's test process would therefore see no
# declarations however many its `src/` carries, and a default-deny gate would call its whole
# package undeclared.
#
# So a declaring module keeps its own store, in a `const` binding of its package's root module. That
# binding is part of the package, so it is serialized into the pkgimage and read back intact.
# `declarations()` is the single unioned view every driver reads.
const _LOCAL_DECLS = :__strict_declarations__
const _LOCAL_EXEMPT = :__strict_exempt__

# The store for `mod`, created on first write. It is placed in the package's ROOT module so that
# finding it later means walking the loaded packages rather than every submodule of each.
function _local_store!(mod::Module, name::Symbol, empty)
    root = Base.moduleroot(mod)
    if isdefined(root, name)
        store = getfield(root, name)
        # A store built by an older StrictMode holds a different type, and pushing into it would
        # fail somewhere far from the cause. Say so here instead.
        store isa typeof(empty) || throw(
            ArgumentError(
                "$(nameof(root)).$name holds a $(typeof(store)), not a $(typeof(empty)). It was " *
                    "written by a different version of StrictMode: recompile that package, or " *
                    "restart this session."
            )
        )
        return store
    end
    store = empty
    Core.eval(root, :(const $name = $store))
    return store
end

# Every module that may hold a store: the loaded packages, plus `Main` for a REPL session, which is
# not one of them.
function _store_modules()
    mods = Module[Main]
    for (_, m) in Base.loaded_modules
        m === Main || push!(mods, m)
    end
    return mods
end

"""
    StrictMode.declarations() -> Dict

Every declaration in scope: `(f, types) => (; guarantees)`. The union of what this session
registered directly and what each loaded package declared in its own `src/`.

A package's declarations live in a `const` of the package itself, because a declaration made during
its precompile cannot be stored in StrictMode — StrictMode is loaded from its own cache by then, and
the mutation does not survive the declaring package's next cached load.
"""
function declarations()
    out = Dict{Any, @NamedTuple{guarantees::Any, source::String}}()
    for m in _store_modules()
        isdefined(m, _LOCAL_DECLS) || continue
        d = getfield(m, _LOCAL_DECLS)
        d isa AbstractDict && merge!(out, d)
    end
    merge!(out, STRICT_REGISTRY)      # a direct call wins: it is this session's explicit say
    return out
end

"""
    StrictMode.exemptions() -> Vector{Exemption}

Every opt-out in scope, from this session and from each loaded package's own `src/`.
"""
function exemptions()
    out = Exemption[]
    for m in _store_modules()
        isdefined(m, _LOCAL_EXEMPT) || continue
        s = getfield(m, _LOCAL_EXEMPT)
        s isa AbstractVector && append!(out, s)
    end
    return append!(out, STRICT_EXEMPT)
end

"""
    StrictMode.clear_declarations!()

Drop every declaration and exemption in scope: this session's, and each loaded module's own.

For tests, which need a known-empty starting point — `empty!(registered_strict())` clears only the
half this session registered directly. On a loaded package this discards declarations its `src/`
made, which do not come back without reloading it.
"""
function clear_declarations!()
    empty!(STRICT_REGISTRY)
    empty!(STRICT_EXEMPT)
    for m in _store_modules()
        isdefined(m, _LOCAL_DECLS) && empty!(getfield(m, _LOCAL_DECLS))
        isdefined(m, _LOCAL_EXEMPT) && empty!(getfield(m, _LOCAL_EXEMPT))
    end
    return nothing
end

"""
    register_strict!(f, types; guarantees = (:typestable, :noalloc), mod = nothing)

Record that `f` with concrete signature `types` should satisfy `guarantees`, so the automatic
drivers (`audit`, `@strict module`, the Revise loop, and `StrictModeTest.test_registered`) re-check
it. Non-concrete signatures are dropped with a warning (nothing to analyze).

`mod` names the module the declaration belongs to, and the macros pass their own. The declaration is
then stored in that package rather than here, which is what makes it survive the package's next
cached load — see [`StrictMode.declarations`](@ref).
"""
function register_strict!(
        @nospecialize(f), @nospecialize(types);
        guarantees = (:typestable, :noalloc), mod::Union{Nothing, Module} = nothing,
        source::AbstractString = ""
    )
    gs = _check_guarantees(guarantees)
    tt = Tuple(types)
    # `isdispatchtuple`, not `all(isconcretetype, tt)`: a `::Type{T}` argument is a valid,
    # fully-specified dispatch signature (there's exactly one value of `Type{Float64}`), but
    # `isconcretetype(Type{Float64})` is `false` — a real Julia quirk that would otherwise skip
    # every `::Type{T}`-argument function, silently, including the dispatch idiom this
    # package's own `:static_ownership` guarantee recommends.
    if !Base.isdispatchtuple(Tuple{tt...})
        @warn "register_strict!: skipping $(_func_name(f))$(_sig_string(tt)) — non-concrete argument types."
        return nothing
    end
    store = isnothing(mod) ? STRICT_REGISTRY :
        _local_store!(mod, _LOCAL_DECLS, Dict{Any, @NamedTuple{guarantees::Any, source::String}}())
    store[(f, tt)] = (; guarantees = gs, source = String(source))
    return nothing
end

"""
    StrictMode.guarantee_names() -> Tuple{Symbol, …}

Every guarantee a declaration may name.
"""
guarantee_names() = _GUARANTEES

# Flatten a guarantee spec and reject an unknown name AT DECLARATION TIME. A misspelled guarantee
# that is accepted here fails nothing and checks nothing: the driver that would have evaluated it
# never sees the name, so a suite stays green while the guarantee the author asked for was never
# applied. Nesting is allowed so a shared policy can be a `const` collection somewhere else and be
# spliced into each module that follows it.
function _check_guarantees(spec)
    gs = Symbol[]
    _flatten_guarantees!(gs, spec, 0)
    return Tuple(gs)
end

function _flatten_guarantees!(out::Vector{Symbol}, spec, depth::Int)
    depth > 8 && throw(ArgumentError("guarantees: nested too deeply ($depth levels)"))
    if spec isa Symbol
        # A named set expands here, so a name composes with anything else a caller wrote:
        # `(:default, :vectorized)` adds one guarantee to the set rather than replacing it.
        haskey(_POLICY_SETS, spec) &&
            return _flatten_guarantees!(out, _POLICY_SETS[spec], depth + 1)
        spec in _GUARANTEES || throw(
            ArgumentError(
                "unknown guarantee :$spec; expected one of $(_GUARANTEES), or a named set " *
                    "$(Tuple(sort(collect(keys(_POLICY_SETS))))). A guarantee that is not one of " *
                    "these is never checked, so it is rejected here rather than silently doing " *
                    "nothing."
            )
        )
        spec in out || push!(out, spec)
        return out
    end
    applicable(iterate, spec) || throw(
        ArgumentError("guarantees must be `Symbol`s or collections of them, got $(typeof(spec))")
    )
    for s in spec
        _flatten_guarantees!(out, s, depth + 1)
    end
    return out
end

"""
    registered_strict() -> Dict

The declarations made in **this session**, by a direct [`register_strict!`](@ref) call:
`(f, types) => (; guarantees)`. Mutable, so a test can `empty!` it.

A package's own declarations are not here — they live in the package, which is what makes them
survive its cached load. [`StrictMode.declarations`](@ref) is the union every driver reads.
"""
registered_strict() = STRICT_REGISTRY

"""
    Exemption

One opt-out recorded by [`@strict_exempt`](@ref): code that is meant to allocate or stay
type-flexible, and is not held to a guarantee.

- `func` — the demangled function name.
- `types` — the signature it covers, or `nothing` for every signature of that name.
- `guarantees` — the guarantees it covers, or `nothing` for all of them.
- `reason` — why, for whoever reads the report. Empty when none was given.
- `file` / `line` — where the exemption is written, so a report can send a reader to it.

It is a record rather than a bare name so that an exemption has something to point AT: a narrow
one can be checked against a verdict ("this is still needed"), and a name alone cannot.
"""
struct Exemption
    func::Symbol
    types::Union{Nothing, Tuple}
    guarantees::Union{Nothing, Tuple{Vararg{Symbol}}}
    reason::String
    file::String
    line::Int
end

function Base.show(io::IO, e::Exemption)
    print(io, "@strict_exempt ", e.func)
    isnothing(e.types) || print(io, _sig_string(e.types))
    isnothing(e.guarantees) || print(io, " guarantees = ", e.guarantees)
    e.file == "" || print(io, " @ ", e.file, ":", e.line)
    e.reason == "" || print(io, " — ", e.reason)
    return nothing
end

# Opt-outs recorded in THIS session. Rust-like: in a strict module everything is hot by default and
# you opt the rare cold helper out, rather than opting the hot code in.
const STRICT_EXEMPT = Exemption[]

# Whether `e` covers this function, signature and guarantee. A field left `nothing` matches
# anything, so the common whole-function form keeps its meaning while a narrow one binds tightly.
function _covers(e::Exemption, name::Symbol, @nospecialize(types), g::Union{Nothing, Symbol})
    e.func === name || return false
    isnothing(e.guarantees) || isnothing(g) || g in e.guarantees || return false
    isnothing(e.types) || isnothing(types) || Tuple(types) == e.types || return false
    return true
end

# The coarse question the module sweeps ask: is this function opted out of everything? A narrow
# exemption must NOT answer yes here — it would silence guarantees it never claimed.
function _is_exempt(@nospecialize(f))
    name = _demangle(nameof(f))
    for e in exemptions()
        e.func === name && isnothing(e.types) && isnothing(e.guarantees) && return true
    end
    return false
end

# The precise question a verdict asks: is THIS signature opted out of THIS guarantee?
function _is_exempt(@nospecialize(f), @nospecialize(types), g::Union{Nothing, Symbol})
    name = _demangle(nameof(f))
    for e in exemptions()
        _covers(e, name, types, g) && return true
    end
    return false
end

function _exempt!(
        name::Symbol, mod::Union{Nothing, Module} = nothing;
        types = nothing, guarantees = nothing, reason::AbstractString = "",
        file::AbstractString = "", line::Integer = 0
    )
    gs = isnothing(guarantees) ? nothing : _check_guarantees(guarantees)
    e = Exemption(name, isnothing(types) ? nothing : Tuple(types), gs, String(reason), String(file), Int(line))
    store = isnothing(mod) ? STRICT_EXEMPT : _local_store!(mod, _LOCAL_EXEMPT, Exemption[])
    e in store || push!(store, e)
    return nothing
end

"""
    exempt_strict() -> Vector{Exemption}

The opt-outs recorded in **this session**. Mutable, so a test can `empty!` it.
[`StrictMode.exemptions`](@ref) adds each loaded package's own.
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
    # Read once rather than per item: the union walks every loaded package's store, and a module
    # sweep runs this for hundreds of signatures.
    decls = declarations()
    for (f, types, gs) in items
        # A narrowed exemption is honored HERE, at the one funnel both tiers run through, so the
        # scan and the proofs answer alike — the same arrangement `ignore_throw` has. An exempted
        # guarantee is reported as `:info` rather than dropped: an opt-out nobody can see in the
        # output is indistinguishable from a check that was never asked for.
        live, exempt = _split_exempt(f, types, gs)
        append!(out, _with_policy(exempt, decls, f, types))
        isempty(live) && continue
        fs = try
            analyze(f, types, live)
        catch err
            err isa StrictViolation && rethrow()
            _errored_findings(f, types, live, err)
        end
        append!(out, _with_policy(fs, decls, f, types))
    end
    return out
end

# Stamp each finding with the source of the declaration that asked for the guarantee, so a reader
# can go to the line that made it a requirement instead of searching for it. Only a macro can know
# that line — a `register_strict!` call is a function and cannot see its caller — so a declaration
# made directly carries no source and the field stays empty.
_restamp(x::StrictFinding, source::AbstractString) = StrictFinding(
    x.mod, x.func, x.signature, x.guarantee, x.status, x.file, x.line, x.reason, x.suggestion,
    x.tier, x.code, String(source)
)

function _with_policy(fs, decls, @nospecialize(f), @nospecialize(types))
    isempty(fs) && return fs
    meta = get(decls, (f, Tuple(types)), nothing)
    (isnothing(meta) || meta.source == "") && return fs
    return [
        StrictFinding(
            x.mod, x.func, x.signature, x.guarantee, x.status, x.file, x.line, x.reason,
            x.suggestion, x.tier, x.code, meta.source
        ) for x in fs
    ]
end

# `(guarantees still to check, :info findings for the exempted ones)`.
function _split_exempt(@nospecialize(f), @nospecialize(types), gs)
    live = Symbol[]
    notes = StrictFinding[]
    md, fn, sg = _mod_sym(f), _func_name(f), _sig_string(Tuple(types))
    for g in gs
        e = _matching_exemption(f, types, g)
        if isnothing(e)
            push!(live, g)
            continue
        end
        push!(
            notes, StrictFinding(
                md, fn, sg, g, :info, e.file, e.line,
                "exempt" * (e.reason == "" ? "" : ": " * e.reason),
                "`@strict_exempt` covers this" *
                    (isnothing(e.guarantees) ? " function" : " guarantee") *
                    ". Remove the exemption to hold it to this guarantee again."
            )
        )
    end
    return (live, notes)
end

function _matching_exemption(@nospecialize(f), @nospecialize(types), g::Symbol)
    name = _demangle(nameof(f))
    for e in exemptions()
        _covers(e, name, types, g) && return e
    end
    return nothing
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
#
# `modules` scopes the sweep by the defining module of each registered function. The registry is
# process-global and keyed on `(f, types)` with no module of its own, so a dependency loaded from
# source in the same session — a Revise/`dev` setup — contributes its own declarations to it. Left
# unscoped, one package's gate then judges another package's kernels. `_registry_breakdown` makes
# that visible even when nobody scopes.
function _registry_items(guarantees = nothing; modules = nothing)
    names = isnothing(modules) ? nothing : Set{Symbol}(m isa Module ? nameof(m) : Symbol(m) for m in modules)
    return Any[
        (f, types, isnothing(guarantees) ? meta.guarantees : guarantees)
            for ((f, types), meta) in declarations()
            if !_is_exempt(f) && (isnothing(names) || _mod_sym(f) in names)
    ]
end

# `module => count` over the registry, for a driver to report what it is about to sweep.
function _registry_breakdown(items)
    counts = Dict{Symbol, Int}()
    for (f, _, _) in items
        counts[_mod_sym(f)] = get(counts, _mod_sym(f), 0) + 1
    end
    return sort!(collect(counts); by = first)
end

# An empty registry renders exactly like a clean one: zero findings, nothing to report. That is the
# failure mode this package exists to remove, so reaching it says so loudly rather than returning a
# green that checked nothing.
function _warn_empty_registry(driver::AbstractString, alternative::AbstractString)
    @warn "$driver: no declarations are in scope (0 checks) — this result proves nothing. " *
        "A package declares with `@strict_function` in its own `src/`, or a test setup calls " *
        "`register_strict!`; `StrictMode.declarations()` is what this reads. Use $alternative to " *
        "enumerate signatures directly instead. (No declarations is also legitimate when nothing " *
        "is declared, or everything is exempt.)"
    return nothing
end

# The value-free engine as an `analyze(f, types, guarantees)` callable — the default every driver
# below takes. `StrictModeTest` passes `_proof_findings` instead, which is the ONLY difference
# between `audit` and `proof_audit`: same scopes, same shapes, same rendering, different engine.
_scan_findings(@nospecialize(f), @nospecialize(types), guarantees) = findings(f, types; guarantees)

# Findings for every registered signature. Reporting only — `audit` renders these.
function _findings_all(analyze = _scan_findings; guarantees = nothing)
    items = _registry_items(guarantees)
    isempty(items) && _warn_empty_registry("audit(:registered)", "`audit(MyPkg; sweep = true)`")
    return _map_findings(analyze, items)
end

# Findings for the *registered* (declared-guarantee) functions belonging to `mod` — the "check
# what I promised" scope, as opposed to the whole-module sweep.
function _registered_findings_in(analyze, mod::Module; guarantees = nothing)
    items = Any[
        (f, types, isnothing(guarantees) ? meta.guarantees : guarantees)
            for ((f, types), meta) in declarations()
            if _mod_sym(f) === nameof(mod) && !_is_exempt(f)   # cold / @strict_exempt → skip
    ]
    # Through `_map_findings`, so a signature whose analysis throws becomes a failing finding
    # naming the error rather than vanishing. This feeds `_auto_check_module` — the `@strict module`
    # load gate — where a dropped signature is a method that loads clean without being checked.
    return _map_findings(analyze, items)
end

# Whole-module strict check at load. Uses the value-free engine, which is what makes opting a
# module into strict mode affordable on every load; the proofs run from the test environment, where
# `StrictModeTest` is loadable and this module's own precompile is not happening.
const _LOCAL_POLICY = :__strict_policy__
# Named policy sets, so a module says one word instead of restating a list. A set is spelled with
# the name it means: `:default` IS what a module gets with no policy at all, because a name that
# does not match the behavior is worse than no name.
#
# `:default` reports rather than gates throughout (`_guarantee_gates` in report.jl), which is what
# makes it safe to be the default: a structural guess must not break a consumer's build.
const _POLICY_SETS = Dict{Symbol, Tuple{Vararg{Symbol}}}(
    :default => (:typestable, :noalloc, :noboxing),
    :hot => (:typestable, :noalloc, :noboxing, :vectorized, :no_scalar_loops, :no_spill),
    :all => _GUARANTEES,
)

const _DEFAULT_POLICY = _POLICY_SETS[:default]

"""
    StrictMode.policy_sets() -> Dict{Symbol, Tuple}

The named guarantee sets [`@strict_policy`](@ref) accepts, such as `:default`, `:hot` and `:all`.

A name may be mixed with individual guarantees and with other names — the spec is flattened — so
`(:default, :vectorized)` and `:hot` are both spellable.
"""
policy_sets() = _POLICY_SETS

# The policy binding is created in `mod` itself, not in its root: a package and a submodule of it
# may hold different policies, and `module_policy` resolves inheritance by walking up from the
# module asked about.
function _set_module_policy!(mod::Module, gs)
    isdefined(mod, _LOCAL_POLICY) ?
        Core.eval(mod, :($(_LOCAL_POLICY) = $gs)) :
        Core.eval(mod, :(const $(_LOCAL_POLICY) = $gs))
    return gs
end

"""
    StrictMode.module_policy(mod::Module) -> Tuple{Symbol, …}

The guarantees a strict-marked module applies to its own definitions, as set by
[`@strict_policy`](@ref). A module without one inherits its parent's, and the default is
`$(_DEFAULT_POLICY)`.

Inheritance is resolved by walking up from `mod` at the moment it is asked, so a submodule never
holds a stale copy of a policy its parent changed.
"""
function module_policy(mod::Module)
    cur = mod
    for _ in 1:32          # a module nests far less deeply; the bound ends the walk
        isdefined(cur, _LOCAL_POLICY) && return getfield(cur, _LOCAL_POLICY)
        p = parentmodule(cur)
        p === cur && break
        cur = p
    end
    return _DEFAULT_POLICY
end

# Every checkable signature the module itself defines, read from its METHODS rather than from the
# statements a macro rewrote: a definition in an `include`d file is a method of this module like any
# other, and a rewrite of the module body cannot see through `include`.
#
# Only a method whose own signature is a dispatch tuple can be checked here — nothing has been
# called yet at load, so there are no specializations to read, and a generic declaration infers to
# `Any`. Those are reported by the coverage gate from the test environment instead.
function _module_load_items(mod::Module, policy)
    declared = Dict{Any, Any}()
    for ((f, tt), meta) in declarations()
        _mod_sym(f) === nameof(mod) && (declared[(f, tt)] = meta.guarantees)
    end
    items = Any[]
    ms, _ = module_methods(mod)
    for m in ms
        base = Base.unwrap_unionall(m.sig)
        base isa DataType && Base.isdispatchtuple(base) || continue
        ft = _method_function(m)
        f = try
            ft.instance
        catch
            continue
        end
        tt = Tuple(base.parameters[2:end])
        push!(items, (f, tt, get(declared, (f, tt), policy)))
    end
    return items
end

#   `policy` is passed in by `@strict_policy`, which has just created the policy binding: reading it
# back in the same world that defined it is what Julia 1.12's binding semantics warn about and a
# later version errors on. Callers with no policy of their own resolve it here, a world later.
function _auto_check_module(mod::Module, policy = module_policy(mod), source::AbstractString = "")
    CHECKS_ENABLED || return nothing
    fs = _map_findings(_scan_findings, _module_load_items(mod, policy))
    # The policy is the requirement here, so its line is what a reader needs; a signature with its
    # own declaration keeps that one, which `_map_findings` has already stamped.
    source == "" || (fs = [f.policy == "" ? _restamp(f, source) : f for f in fs])
    # Split on `_guarantee_gates` exactly as `@strict_function` does. This runs at the CONSUMER'S
    # own precompile, where `StrictModeTest` is not loadable, so the allocation verdict here is the
    # value-free scan — measured 8.1% false over a 120-specialization corpus (issue #17). Aborting a
    # module load on that is issue #18, the thing that made checks-on unusable in PureBLAS; it was
    # fixed for `@strict_function` and left in place here, where the blast radius is every
    # definition in the module rather than one.
    gating = filter(f -> _guarantee_gates(f.guarantee), fs)
    reporting = filter(f -> !_guarantee_gates(f.guarantee), fs)
    _run_and_report(reporting, :strict_module, string(nameof(mod)), :warn)
    _run_and_report(gating, :strict_module, string(nameof(mod)), :error)
    return nothing
end

# --- `@strict module … end` rewriting (called from the @strict macro in macros.jl) ------------

# Whether a definition carries a `where` clause. The same test `@strict_function` applies
# (`strict_function.jl`), so both paths treat a parametric declaration alike.
_is_parametric_def(def) =
    Meta.isexpr(def, (:function, :(=))) && Meta.isexpr(def.args[1], :where)

# The name a definition defines, or `nothing` when the statement is not a plain named definition.
function _defname(def)
    sig = try
        _strictdef_sig(def)
    catch
        return nothing
    end
    Meta.isexpr(sig, :call) || return nothing
    fname = sig.args[1]
    return fname isa Symbol ? fname : nothing
end

# Parametric definitions a `@strict module` left unchecked, named once for the whole module. One
# line per definition would bury the module's real findings: a generic package is mostly parametric.
function _warn_parametric_module(mod, names)
    @warn "@strict module $mod: $(length(names)) parametric definition(s) name no concrete " *
        "argument types, so their guarantees are not checked at load — " *
        join(("`$n`" for n in names), ", ") * ". Declare the instantiations with " *
        "`@strict_function … signatures = [(T1, …), …]`, or use `@strict_stable` to check every " *
        "specialization as it compiles."
    return nothing
end

function _maybe_register_stmt(stmt, source::AbstractString = "")
    (Meta.isexpr(stmt, :function) || Meta.isexpr(stmt, :(=))) || return nothing
    # A parametric definition is skipped, not registered. `_strictdef_sig` peels the `where`, so its
    # type variables would be spliced into the module body unbound — and the signature could not be
    # a dispatch tuple in any case, which is all the registry can check. Same verdict
    # `@strict_function` gives a parametric declaration.
    _is_parametric_def(stmt) && return nothing
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
    return :($(register_strict!)($fname, $argtypes; mod = @__MODULE__, source = $source))
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
function _rewrite_strict_stmt(stmt, source::AbstractString = "")
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
            fname === nothing || push!(out, :($(_exempt!)($(QuoteNode(fname)), @__MODULE__)))
            return out
        end
        name = inner isa QuoteNode ? inner.value : inner
        return name isa Symbol ? Any[:($(_exempt!)($(QuoteNode(name)), @__MODULE__))] : Any[stmt]
    end
    reg = _maybe_register_stmt(stmt, source)
    return reg === nothing ? Any[stmt] : Any[stmt, reg]
end

function _strict_module(modexpr::Expr, source::AbstractString = "")
    body = modexpr.args[3]::Expr
    newstmts = Any[]
    skipped = Symbol[]
    for stmt in body.args
        if _is_parametric_def(stmt) && !_is_strict_exempt_call(stmt)
            nm = _defname(stmt)
            isnothing(nm) || nm in skipped || push!(skipped, nm)
        end
        append!(newstmts, _rewrite_strict_stmt(stmt, source))
    end
    isempty(skipped) ||
        push!(newstmts, :($(_warn_parametric_module)($(QuoteNode(modexpr.args[2])), $skipped)))
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
    # `#f#NN` is Julia's kwsorter mangling; `#f#inner` is `@strict_stable`'s hidden body.
    m = match(r"^#(.+)#(?:\d+|inner)$", s)
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

# --- the census: every method a module defines ------------------------------------------------

# A package's loaded extensions, alongside the package itself. An extension is a ROOT module —
# `parentmodule` on one returns itself — so walking up from a method defined there never reaches the
# package, and a census that only walked up would skip every method in `ext/` without saying so.
# Measured on StrictMode with Revise loaded: 5 methods in the extension, 0 of them found.
function _scope_modules(mod::Module)
    mods = Module[mod]
    for (_, m) in Base.loaded_modules
        m === mod && continue
        e = try
            Base.get_extension(mod, nameof(m))
        catch
            nothing
        end
        isnothing(e) || e !== m || push!(mods, m)
    end
    return mods
end

# Whether `m` is `mod` or lives beneath it, so a package's submodules count as its own.
function _in_module_tree(m::Module, mod::Module)
    cur = m
    for _ in 1:32          # a module nests far less deeply than this; the bound ends the walk
        cur === mod && return true
        p = parentmodule(cur)
        p === cur && return false
        cur = p
    end
    return false
end

# The function a method dispatches on, or `nothing` when the signature is too odd to read.
function _method_function(m::Method)
    sig = Base.unwrap_unionall(m.sig)
    sig isa DataType && !isempty(sig.parameters) || return nothing
    ft = Base.unwrap_unionall(sig.parameters[1])
    return ft isa DataType ? ft : nothing
end

# Why the census leaves a method out, or `nothing` to keep it. Each reason is a method that cannot
# carry a guarantee of its own, so counting it would make the gate unusable rather than stricter:
# the kwarg wrapper's work happens in the body method the census also sees, a closure has no name a
# declaration could refer to, and a struct's default constructors are generated, not written.
function _census_skip(m::Method)
    ft = _method_function(m)
    isnothing(ft) && return :unreadable
    ft === typeof(Core.kwcall) && return :kwcall
    ft <: Type && return :constructor
    occursin(r"^#\d+", string(m.name)) && return :closure
    return nothing
end

"""
    StrictMode.module_methods(mod::Module; only = nothing, exempt = (), include_exempt = false)
        -> (methods::Vector{Method}, skipped::Dict{Symbol, Int})

Every method `mod` (or a module beneath it, or one of its loaded extensions) defines, with the ones
no declaration could name counted in `skipped` by reason rather than dropped silently.

`include_exempt = true` keeps the methods an `@strict_exempt` covers, for the one caller whose
subject *is* the exempt code: `StrictModeTest.test_exemptions`, which asks whether an exemption is
still needed.

It reads the global method table, not the module's bindings, because a method on a **foreign**
function — `Base.getindex`, `Base.size`, `Base.show` — belongs to the module that wrote it while
its name is bound in `Base`. Those are frequently a package's hottest methods. Measured on
StrictMode itself: 574 methods here, of which a walk over `names(mod; all = true)` finds 363.
"""
function module_methods(mod::Module; only = nothing, exempt = (), include_exempt::Bool = false)
    exemptpred = _name_matcher(exempt)
    onlypred = _name_matcher(only)
    scope = _scope_modules(mod)
    out = Method[]
    skipped = Dict{Symbol, Int}()
    bump!(k) = (skipped[k] = get(skipped, k, 0) + 1)
    Base.visit(Core.methodtable) do m
        m isa Method || return nothing
        any(s -> _in_module_tree(m.module, s), scope) || return nothing
        reason = _census_skip(m)
        isnothing(reason) || return bump!(reason)
        f = try
            _method_function(m).instance
        catch
            nothing                     # no singleton instance: filters that need the function
        end                             # cannot speak for it, so it stays in the census
        if !isnothing(f)
            ((!include_exempt && _is_exempt(f)) || (!isnothing(exemptpred) && exemptpred(f))) &&
                return bump!(:exempt)
            isnothing(onlypred) || onlypred(f) || return bump!(:filtered)
        end
        push!(out, m)
        return nothing
    end
    return (out, skipped)
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

function _findings_compiled(analyze, mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = ())
    items = _compiled_items(mod; guarantees, only, exempt)
    return _map_findings(analyze, items)
end

# Whether a declaration in the registry speaks for this method. A declaration names a signature,
# so it covers `m` when that signature is one `m` would be dispatched for — which is also how a
# `signatures = [...]` list covers a generic declaration it instantiates.
function _method_declared(m::Method, keys)
    for (f, types) in keys
        Tuple{typeof(f), types...} <: m.sig && return true
    end
    return false
end

# The concrete signatures this method has actually compiled. A generic method has as many as it has
# been called with argument types for, and only these can carry a verdict: the declaration itself
# infers to `Any`.
function _method_signatures(m::Method)
    out = Vector{Any}[]
    for mi in _specializations(m)
        tt = try
            collect(Any, (mi.specTypes::DataType).parameters[2:end])
        catch
            continue
        end
        Base.isdispatchtuple(Tuple{tt...}) || continue
        tt in out || push!(out, tt)
    end
    return out
end

# Whether a declaration names this exact compiled signature of `m`.
function _signature_declared(m::Method, tt::Vector{Any}, keys)
    want = Tuple{tt...}
    for (f, types) in keys
        Tuple{typeof(f), tt...} <: m.sig || continue
        want <: Tuple{types...} && return true
    end
    return false
end

# One `:coverage` failure, naming the method and the signature it was reached with.
function _coverage_finding(mod::Module, m::Method, sig::AbstractString)
    fname = string(_demangle(m.name))
    return StrictFinding(
        nameof(mod), fname, sig, :coverage, :fail, string(m.file), Int(m.line),
        "`$fname$sig` has no registered StrictMode guarantee",
        "declare this signature: `StrictMode.register_strict!($fname, $sig; guarantees = " *
            "(:typestable, :noalloc))` in the test setup. A generic definition needs each " *
            "instantiation that runs (`signatures = [(T1, …), …]`) — declaring one says nothing " *
            "about the others. Opt it out visibly with `@strict_exempt $fname` if it is cold by " *
            "design."
    )
end

# Coverage gate over the CENSUS (`audit(mod; require = :all)`): one `:fail` per method `mod`
# defines that no declaration speaks for and no exempt covers. Default-deny — a method nobody
# declared reads as undeclared instead of as fine, which is the whole difference between a gate and
# a convention.
#
# What it can claim is narrower than it looks, and the two are reported apart: a declaration can be
# VERIFIED only where the signature is a dispatch tuple, because a generic one infers to `Any`.
# Measured on StrictMode itself, 79 of 476 methods qualify. For the rest this gate reports whether a
# declaration exists, which is a fact, not an inference.
function _coverage_all_findings(mod::Module; only = nothing, exempt = ())
    ms, skipped = module_methods(mod; only, exempt)
    keys_ = collect(keys(declarations()))
    out = StrictFinding[]
    for m in ms
        # Every concrete signature this method has compiled must be declared, not just one of them:
        # a declaration names a signature, and one instantiation says nothing about the others that
        # reach the same body. Declaring `f(Float64)` leaves `f(Int32)` unchecked, and a gate that
        # counted the method as covered would hide exactly that.
        sigs = _method_signatures(m)
        if !isempty(sigs)
            for tt in sigs
                _signature_declared(m, tt, keys_) && continue
                push!(out, _coverage_finding(mod, m, _sig_string(Tuple(tt))))
            end
            continue
        end
        # Nothing has compiled, so there is no signature to name: the only claim available is that
        # some declaration speaks for the method at all.
        _method_declared(m, keys_) && continue
        fname = string(_demangle(m.name))
        # The argument types, rendered as every other finding renders them. A method's `sig` also
        # carries the function's own type as its first parameter, which a reader does not need.
        sig = try
            base = Base.unwrap_unionall(m.sig)
            _sig_string(Tuple(base.parameters[2:end]))
        catch
            ""
        end
        push!(
            out, StrictFinding(
                nameof(mod), fname, sig, :coverage, :fail, string(m.file), Int(m.line),
                "method `$fname` has no registered StrictMode guarantee",
                "declare it: `StrictMode.register_strict!($fname, (T1, …); guarantees = " *
                    "(:typestable, :noalloc))` in the test setup, or `@strict_function` / " *
                    "`@strict_policy` at the definition. A generic definition needs the concrete " *
                    "instantiations (`signatures = [(T1, …), …]`). Opt it out visibly with " *
                    "`@strict_exempt $fname` if it is cold by design."
            )
        )
    end
    # The exclusions are reported, not silent: a gate that quietly drops a third of a module reads
    # as having checked it.
    if !isempty(skipped)
        tally = join(("$v $k" for (k, v) in sort(collect(skipped), by = first)), ", ")
        push!(
            out, StrictFinding(
                nameof(mod), "", "", :coverage, :info, "", 0,
                "$(length(ms)) method(s) in scope; not counted: $tally",
                "A keyword wrapper's work is in the body method this also lists, a closure has no " *
                    "name a declaration could refer to, and default constructors are generated. " *
                    "`exempt` accounts for the rest."
            )
        )
    end
    return out
end

# Coverage gate (`audit(mod; require = :public)`): one :fail finding per exported/public
# function of `mod` that is neither registered (`register_strict!` / `@strict_function`) nor
# exempted. Turns "every kernel declares its guarantees" from a convention into a red test.
# Not a checkable guarantee — findings are built directly, never routed through the engines.
function _coverage_findings(mod::Module; only = nothing, exempt = ())
    exemptpred = _name_matcher(exempt)
    onlypred = _name_matcher(only)
    registered = Set{Any}(k[1] for k in keys(declarations()))
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

# Scan-engine convenience forms. The `analyze`-taking methods above are what `StrictModeTest` calls
# with `_proof_findings`; these keep the common in-package spelling short.
_registered_findings_in(mod::Module; kwargs...) = _registered_findings_in(_scan_findings, mod; kwargs...)
_findings_compiled(mod::Module; kwargs...) = _findings_compiled(_scan_findings, mod; kwargs...)
