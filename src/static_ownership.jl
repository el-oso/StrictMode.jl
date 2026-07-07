# `:static_ownership` — advisory-only. Flags a runtime type/symbol-keyed registry lookup
# (`d[SomeType]` on a `Dict`/`IdDict`) and suggests GKH ownership instead: give each type a
# `const` owner reached by dispatch (`_ws(::Type{T}) = _WS_T`), so it const-folds — trim-safe,
# 0-alloc, no runtime lookup. See `staticval`/`@unroll` (idioms.jl) for the dispatch-form fix.
#
# Deliberately advisory, never a hard failure — see GitHub issue #7 for the full rationale: unlike
# `:noalloc` (AllocCheck) or `:trimsafe` (juliac --trim), "should this be static ownership" has no
# sound backend, and the pattern's own sanctioned fallback (a Dict for the rare-type tail) would
# trip a hard gate on the very form it prescribes. Findings are status `:info`, exactly like
# `inline_suggestions` — never counted by `nfailures`.
#
# Detection scans **unoptimized** typed IR (`code_typed(...; optimize=false)`), not the optimized
# form the rest of `effects.jl` uses: a `Type{T}`-keyed lookup on a concrete, statically-known `T`
# routinely const-folds away entirely during optimization (verified: `get!(f, _WS, T)` on a
# `T`-static-parameter method lowers to raw `jl_eqtable_get`/`jl_eqtable_put` foreigncalls, no
# `getindex`/`get!` call survives). The advisory is about the *source pattern*, not a provable
# per-specialization runtime cost, so it has to look before the optimizer erases the pattern.

const _REGISTRY_FUNCS = (Base.getindex, Base.get, Base.get!, Base.setindex!, Base.haskey)

_unwrap_lattice(@nospecialize(T)) = T isa Core.Const ? Core.Typeof(T.val) : (T isa Core.PartialStruct ? T.typ : T)
_is_type_or_symbol_key(@nospecialize(T)) = (U = _unwrap_lattice(T); U isa Type && (U <: Type || U <: Symbol))
_is_dict_like(@nospecialize(T)) = (U = _unwrap_lattice(T); U isa Type && U <: AbstractDict)

# Argument type at unoptimized-IR statement granularity: slots (`SlotNumber`) are the pre-SSA
# argument/local representation here, not `Core.Argument` (that's optimized-IR-only) — the reason
# this scan can't reuse `_stmt_arg_type` from effects.jl.
function _unopt_arg_type(ci, @nospecialize(a))
    a isa Core.SSAValue && return _unwrap_lattice(ci.ssavaluetypes[a.id])
    a isa Core.SlotNumber && return ci.slottypes === nothing ? Any : _unwrap_lattice(ci.slottypes[a.id])
    a isa GlobalRef && return isconst(a.mod, a.name) ? Core.Typeof(getglobal(a.mod, a.name)) : Any
    a isa QuoteNode && return Core.Typeof(a.value)
    a isa Expr && return Any
    return Core.Typeof(a)
end

# Resolve a callee value, following one level of SSA indirection (unoptimized IR routinely
# assigns `%1 = GlobalRef(Base, :get!)` as its own statement, then calls `(%1)(args...)`).
function _unopt_callee(ci, @nospecialize(a))
    a isa Core.SSAValue && return _unopt_callee(ci, ci.code[a.id])
    a isa GlobalRef && isconst(a.mod, a.name) && return getglobal(a.mod, a.name)
    a isa QuoteNode && return a.value
    a isa Function && return a
    return nothing
end

function _call_callee_and_args(ci, st)
    Meta.isexpr(st, :call) && return _unopt_callee(ci, st.args[1]), st.args[2:end]
    Meta.isexpr(st, :invoke) && return _unopt_callee(ci, st.args[2]), st.args[3:end]
    return nothing, ()
end

struct _RegistrySite
    line::Int
    callee::Symbol
end

# Walk `f`'s unoptimized typed IR for a `getindex`/`get`/`get!`/`setindex!`/`haskey` call where
# some argument is `<:AbstractDict` and some (other) argument is `<:Type`/`<:Symbol` — the
# "registry keyed by identity" shape. No positional argument assumptions (get!'s function-first
# form, setindex!'s value-before-key order, etc. all vary) — any-dict-arg + any-key-arg is the
# whole rule, which keeps this cheap and shape-agnostic at the cost of being a little liberal
# (acceptable: it's advisory, a wrong hint costs a glance, not a build break).
function _registry_lookup_sites(@nospecialize(f), @nospecialize(types::Tuple))
    cts = try
        Base.code_typed(f, types; optimize = false)
    catch
        return _RegistrySite[]
    end
    isempty(cts) && return _RegistrySite[]
    ci = first(cts)[1]
    sites = _RegistrySite[]
    for (i, st) in enumerate(ci.code)
        (Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke)) || continue
        callee, args = _call_callee_and_args(ci, st)
        callee in _REGISTRY_FUNCS || continue
        ts = (_unopt_arg_type(ci, a) for a in args)
        argtypes = collect(ts)
        (any(_is_dict_like, argtypes) && any(_is_type_or_symbol_key, argtypes)) || continue
        push!(sites, _RegistrySite(i, nameof(callee)))
    end
    return sites
end

# Interprocedural companion to the scan above: `_registry_lookup_sites` only sees `f`'s own body,
# so it misses the common "driver calls a non-inlined workspace accessor" shape (the accessor does
# the lookup, one level down). `@assert_owned`'s `_mi_dict_lookup`/`_alloc_signals(...).dictlookup`
# already walk exactly this callee tree — but their rule flags *any* `AbstractDict` accessor,
# key type unchecked (by design: `@assert_owned` is about any runtime-keyed "owned scratch", not
# specifically type/symbol keys). Reusing it here would flag a value-keyed cache
# (`Dict{String,_}`), which issue #7 explicitly requires *not* flagging. So this narrows
# `_mi_dict_lookup`'s receiver check with an additional key-type check, and re-walks the same
# `:invoke` tree independently (unmemoized: this is a dev-time audit, not on the `:fast` hot loop,
# so the cost of `@assert_owned`'s `_SIGNAL_MEMO` isn't worth sharing across two different rules).
function _mi_typekey_dict_lookup(mi::Core.MethodInstance)
    d = mi.def
    (d isa Method && d.name in _DICT_ACCESSORS) || return false
    st = mi.specTypes
    st isa DataType || return false
    ps = st.parameters
    length(ps) >= 2 || return false
    any(p -> p isa Type && p <: AbstractDict, ps[2:end]) || return false
    return any(_is_type_or_symbol_key, ps[2:end])
end

function _typekey_lookup_by_sig(@nospecialize(sig), depth::Int, seen::Base.IdSet{Any})
    sig in seen && return false
    push!(seen, sig)
    cts = try
        Base.code_typed_by_type(sig; optimize = true)
    catch
        return false
    end
    isempty(cts) && return false
    for st in first(cts)[1].code
        if Meta.isexpr(st, :foreigncall)
            # `IdDict` (unlike hash-based `Dict`) inlines `get`/`get!`/`getindex` straight to a
            # `jl_eqtable_*` ccall — no `:invoke` to a named accessor survives to match against,
            # at ANY recursion depth (verified: a `Type{T}`-static-parameter key folds the whole
            # call away even one level down in a non-inlined callee). The ccall args are already
            # type-erased, so the key type can't be re-checked here the way `_mi_typekey_dict_lookup`
            # does — `IdDict` is disproportionately used for identity-comparable keys (Type/Symbol/
            # Module) in practice, so this trades a little precision for recall on exactly the
            # interprocedural shape the top-level/`:invoke` checks can't see. Known ceiling: an
            # `IdDict` keyed by arbitrary object identity (not Type/Symbol) reached through a
            # non-inlined callee would also fire here; narrow it by resolving the callee's dict
            # binding to its declared key type if this proves noisy in practice.
            occursin("eqtable", lowercase(string(st.args[1]))) && return true
        elseif Meta.isexpr(st, :invoke)
            a1 = st.args[1]
            mi = a1 isa Core.CodeInstance ? a1.def : a1
            mi isa Core.MethodInstance || continue
            _mi_typekey_dict_lookup(mi) && return true
            depth > 0 && _typekey_lookup_by_sig(mi.specTypes, depth - 1, seen) && return true
        end
    end
    return false
end

function _interprocedural_typekey_lookup(@nospecialize(f), @nospecialize(types::Tuple))
    sig = Base.signature_type(f, Tuple{types...})
    return _typekey_lookup_by_sig(sig, _FAST_ALLOC_DEPTH[], Base.IdSet{Any}())
end

function _static_ownership_finding(@nospecialize(f), @nospecialize(types::Tuple), md, fn, sg)
    sites = _registry_lookup_sites(f, types)
    interprocedural = isempty(sites) && _interprocedural_typekey_lookup(f, types)
    (isempty(sites) && !interprocedural) && return StrictFinding(md, fn, sg, :static_ownership, :pass, "", 0, "", "")
    m = try
        which(f, types)
    catch
        nothing
    end
    file = m === nothing ? "" : string(m.file)
    line = m === nothing ? 0 : Int(m.line)
    reason = if !isempty(sites)
        callees = join(sort(unique(s.callee for s in sites)), ", ")
        "runtime type/symbol-keyed registry lookup ($(callees)) — $(length(sites)) site(s)"
    else
        "runtime type/symbol-keyed registry lookup reached via a non-inlined callee (interprocedural scan)"
    end
    suggestion = "give each type a `const` owner reached by dispatch (`_ws(::Type{T})=_WS_T`), so " *
        "it const-folds (trim-safe, 0-alloc, no runtime lookup). Keep a Dict only as an explicit " *
        "rare-type fallback, off the hot path. See `staticval`/`@unroll` for the idiom."
    return StrictFinding(md, fn, sg, :static_ownership, :info, file, line, reason, suggestion)
end

"""
    static_ownership_suggestions(f, types) -> Vector{StrictFinding}
    static_ownership_suggestions(mod::Module; only = nothing, exempt = ()) -> Vector{StrictFinding}

Scan for runtime type/symbol-keyed registry lookups (`d[SomeType]` on a `Dict`/`IdDict`) and
suggest **GKH ownership** instead: give each type a `const` owner reached by dispatch, so the
lookup const-folds — trim-safe, 0-alloc, no runtime hash/eq-table hit.

Advisory only — findings are `status = :info` and [`nfailures`](@ref) never counts them, so this
can't break a gate. It's a judgment call (unlike `:noalloc`/`:trimsafe`, which have a sound
backend): a legitimately dynamic dict (a config table, a value-keyed memo cache, the pattern's own
sanctioned rare-type fallback) will pass through unflagged by design elsewhere in this scan, but a
false positive here costs a glance, not a broken build.

No backend required (Base inference only), so this runs in `:fast` mode too — unlike
`:noalloc`/`:typestable`, it isn't mode-sensitive.

```julia
static_ownership_suggestions(my_accessor, (Type{Float64},))
audit(MyPkg; static_ownership_suggest = true)
```
"""
function static_ownership_suggestions(@nospecialize(f), @nospecialize(types::Tuple))
    md, fn, sg = _mod_sym(f), _func_name(f), _sig_string(types)
    finding = _static_ownership_finding(f, types, md, fn, sg)
    finding.status === :info ? StrictFinding[finding] : StrictFinding[]
end

function static_ownership_suggestions(mod::Module; only = nothing, exempt = ())
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
                Base.isdispatchtuple(Tuple{tt...}) || continue
                try
                    append!(out, static_ownership_suggestions(f, tt))
                catch err
                    err isa StrictViolation && rethrow()
                end
            end
        end
    end
    return out
end
