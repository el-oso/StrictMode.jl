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
    if !all(isconcretetype, tt)
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

function _run_and_report(fs::Vector{StrictFinding}, kind::Symbol, target, fail::Symbol)
    failed = filter(_failed, fs)
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
"""
function check_all(; guarantees = nothing, fail::Symbol = :none)
    out = StrictFinding[]
    for ((f, types), meta) in STRICT_REGISTRY
        gs = guarantees === nothing ? meta.guarantees : guarantees
        try
            append!(out, findings(f, types; guarantees = gs))
        catch err
            err isa StrictViolation && rethrow()
        end
    end
    return _run_and_report(out, :check_all, "registry", fail)
end

# Automatic-at-load hook emitted by `@strict module`. Gated on CHECKS_ENABLED so production pays
# nothing; honors fail_mode.
# Findings for the *registered* (declared-guarantee) functions belonging to `mod` — the "check
# what I promised" scope, as opposed to the whole-module sweep.
function _registered_findings_in(mod::Module; guarantees = nothing)
    out = StrictFinding[]
    for ((f, types), meta) in STRICT_REGISTRY
        _mod_sym(f) === nameof(mod) || continue
        gs = guarantees === nothing ? meta.guarantees : guarantees
        try
            append!(out, findings(f, types; guarantees = gs))
        catch err
            err isa StrictViolation && rethrow()
        end
    end
    return out
end

function _auto_check_module(mod::Module)
    CHECKS_ENABLED || return nothing
    _run_and_report(_registered_findings_in(mod), :strict_module, string(nameof(mod)), FAIL_MODE)
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

function _strict_module(modexpr::Expr)
    body = modexpr.args[3]::Expr
    newstmts = Any[]
    for stmt in body.args
        push!(newstmts, stmt)
        reg = _maybe_register_stmt(stmt)
        reg === nothing || push!(newstmts, reg)
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

"""
    check_compiled(mod::Module; guarantees = (:typestable, :noalloc), fail = :none,
                   only = nothing, exempt = ()) -> Vector{StrictFinding}

Usage-driven sweep: check the concrete method instances `mod`'s functions have **actually
compiled** (during your tests / a run / the precompile workload). No annotation needed, but
coverage is whatever executed, and a module that mixes hot and cold (plan-time) helpers will be
noisy — cold helpers that legitimately allocate show up too. Scope it with:

- `only` — a collection of functions or name `Symbol`s to *include* (skip everything else).
- `exempt` — a collection of functions or name `Symbol`s to *exclude* (e.g. plan-time helpers).

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
    )
    exemptset = Set{Symbol}(_asname(x) for x in exempt)
    onlyset = only === nothing ? nothing : Set{Symbol}(_asname(x) for x in only)
    out = StrictFinding[]
    for nm in names(mod; all = true)
        isdefined(mod, nm) || continue
        f = getfield(mod, nm)
        (f isa Function && parentmodule(f) === mod) || continue
        nameof(f) in exemptset && continue
        onlyset === nothing || nameof(f) in onlyset || continue
        for mth in methods(f)
            for mi in _specializations(mth)
                tt = try
                    Tuple((mi.specTypes::DataType).parameters[2:end])
                catch
                    continue
                end
                all(isconcretetype, tt) || continue
                try
                    append!(out, findings(f, tt; guarantees))
                catch err
                    err isa StrictViolation && rethrow()
                end
            end
        end
    end
    return _run_and_report(out, :check_compiled, string(nameof(mod)), fail)
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
