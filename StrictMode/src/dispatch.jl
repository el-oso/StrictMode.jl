# Why a call is dynamic, and how close a static one is to becoming dynamic.
#
# Inference resolves a call statically while at most `max_methods` methods match it (3 by default).
# The fourth matching method turns the call dynamic, and the effect is NON-LOCAL: the method can be
# added anywhere, and an untouched caller becomes dynamic with it. Measured on a 1000-element loop
# (docs/src/dynamic_dispatch.md): 0.58 µs and 0 B with a concrete or `Union` element type, 24.02 µs
# and 32 kB with an abstract one.
#
# Two products here:
#   - `_instability_cause`, which turns "this body is unstable" into the declaration to edit, and
#     feeds the `:typestable` finding's reason and suggestion.
#   - `dispatch_report`, which lists a module's dynamic call sites and the static ones sitting at the
#     method limit.
#
# A *declaration* never causes instability on its own: `f(x::Op)` called with a concrete `O1` is
# specialized and static, because Julia specializes on the argument's actual type. Uncertainty comes
# from a value whose type the caller does not know — an abstract container element, an abstract
# field, or a non-`const` global.

const _REFLECTION_NAMES = (:return_types, :invokelatest, :which, :methods, :code_typed, :infer_effects)

# A container whose payload type is abstract, whatever the container is. `_abstract_container`
# (effects.jl) covers arrays and `Memory` only, because widening it would change the allocation
# verdicts; blame for an instability is a separate question, and a `Dict{String,Any}` or a `Ref{Any}`
# is the same mistake as a `Vector{Any}`.
function _abstract_payload(@nospecialize T)
    T isa Type || return false
    _abstract_container(T) && return true
    isconcretetype(T) || return false
    payloads = if T <: AbstractDict
        Any[keytype(T), valtype(T)]
    elseif T <: Base.RefValue || T <: Base.AbstractSet
        Any[eltype(T)]
    elseif T <: Tuple
        Any[p for p in T.parameters]
    else
        return false
    end
    return any(p -> p isa Type && _boxy(p), payloads)
end

_max_methods() = Base.Compiler.InferenceParams().max_methods

# The limit that applies to a call, which is NOT the global one when the callee's module or the
# function itself raises it (`Base.Experimental.@max_methods`). The module value is -1 when unset and
# the per-function value 0, so both fall through to the global default.
function _max_methods(@nospecialize(fn))
    perfunc = try
        Int(typeof(fn).name.max_methods)
    catch
        0
    end
    perfunc > 0 && return perfunc
    mod = try
        parentmodule(fn)
    catch
        return _max_methods()
    end
    permod = try
        Int(ccall(:jl_get_module_max_methods, Cint, (Any,), mod))
    catch
        -1
    end
    return permod > 0 ? permod : _max_methods()
end

# The methods a call signature matches, or `nothing` when the query cannot be answered.
#
# Memoized on the signature and the world age: a module sweep asks the same question thousands of
# times (one per specialization × call site), and the uncached query measured 53.6 s of a 219.5 s
# `audit(PureBLAS; sweep = true)`. Keyed by world so a new method definition invalidates, like the
# other memos here; cleared by `clear_cache!`.
const _MATCH_MEMO = Dict{Tuple{Any, UInt64}, Union{Nothing, Int}}()

function _match_count(@nospecialize(sig))
    key = (sig, Base.get_world_counter())
    hit = @lock _SIGNAL_MEMO_LOCK get(_MATCH_MEMO, key, missing)
    hit === missing || return hit
    ms = try
        Base._methods_by_ftype(sig, -1, Base.get_world_counter())
    catch
        nothing
    end
    n = (isnothing(ms) || ms === false) ? nothing : length(ms)
    @lock _SIGNAL_MEMO_LOCK _MATCH_MEMO[key] = n
    return n
end

# The statement's callee as a value, plus the inferred argument types, for a dynamic `:call`.
function _dyn_call_sig(ci, @nospecialize(sig), st::Expr)
    fn = _static_callee(ci, st.args[1])
    isnothing(fn) && return nothing
    ats = Any[]
    for a in st.args[2:end]
        T = _unwrap_lattice(_stmt_arg_type(ci, sig, a))
        T isa Type || return nothing
        push!(ats, T)
    end
    return Tuple{Core.Typeof(fn), ats...}
end

# The reflection function this statement calls, or `nothing`. Covers `:invoke` too: a reflection call
# with concrete arguments resolves, so it is not always left as a dynamic `:call`.
function _reflection_callee(ci, st::Expr)
    if Meta.isexpr(st, :invoke)
        mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
        mi isa Core.MethodInstance || return nothing
        d = mi.def
        d isa Method || return nothing
        # A keyword-accepting reflection call resolves to its body method, named `#return_types#213`;
        # `_demangle` recovers the spelling a reader would recognize.
        name = _demangle(d.name)
        return name in _REFLECTION_NAMES ? string(d.module, ".", name) : nothing
    end
    fn = _static_callee(ci, st.args[1])
    (!isnothing(fn) && nameof(fn) in _REFLECTION_NAMES) || return nothing
    return string(fn)
end

# A `getfield` whose owner is concrete but whose field is not: the struct declaration is the cause.
function _abstract_field_read(ci, @nospecialize(sig), st::Expr)
    _static_callee(ci, st.args[1]) === Core.getfield || return nothing
    length(st.args) >= 3 || return nothing
    owner = _stmt_arg_type(ci, sig, st.args[2])
    (owner isa DataType && isconcretetype(owner)) || return nothing
    fld = st.args[3]
    fld = fld isa QuoteNode ? fld.value : fld
    name = if fld isa Symbol
        fld
    elseif fld isa Integer && fld <= fieldcount(owner)
        fieldname(owner, fld)
    else
        return nothing
    end
    ft = try
        fieldtype(owner, name)
    catch
        return nothing
    end
    # A small isbits union rides unboxed and `_is_typestable_return` accepts it, so it is not a cause.
    (isconcretetype(ft) || _splittable_union(ft)) && return nothing
    return string(nameof(owner), ".", name, "::", ft)
end

"""
    StrictMode._instability_cause(f, types) -> Union{Nothing, Tuple{Symbol, String}}

The declaration behind a type instability, as `(cause, subject)`, or `nothing` when none of the
recognized causes fits. `cause` is one of `:nonconst_global`, `:abstract_field`, `:abstract_eltype`,
`:reflection`, `:method_count`.
"""
function _instability_cause(@nospecialize(f), @nospecialize(types::Tuple))
    # Only a body that is actually unstable has a cause. Without this gate an `Any`-typed statement on
    # a dead throw path is enough to blame a perfectly stable function's argument declaration.
    rts = Base.return_types(f, Tuple{types...})
    if length(rts) == 1 && _is_typestable_return(only(rts))
        sig0 = try
            _alloc_signals(f, types; depth = 0)
        catch
            nothing
        end
        isnothing(sig0) && return nothing
        (sig0.boxing || sig0.unionphi) || return nothing
    end
    cis = try
        Base.code_typed(f, types; optimize = true)
    catch
        return nothing
    end
    isempty(cis) && return nothing
    ci = first(cis)[1]
    ci isa Core.CodeInfo || return nothing
    sig = Base.signature_type(f, Tuple{types...})
    # Declarations first, method counts second. A widened global or field makes every downstream call
    # match a huge method set, so reporting the count would name a symptom of the declaration.
    # A captured variable beats everything else: `Core.Box` makes every read of that local `Any`, so
    # every later cause is downstream of it.
    for T in ci.ssavaluetypes
        _unwrap_lattice(T) === Core.Box && return (:captured_variable, "a local captured by a closure")
    end
    for st in ci.code
        # A non-const global read is its OWN statement, a bare `GlobalRef` typed `Any` — not an
        # argument of the call that consumes it.
        gr = st isa GlobalRef ? st : nothing
        if isnothing(gr) && st isa Expr
            for a in st.args
                a isa GlobalRef && (gr = a; break)
            end
        end
        if !isnothing(gr) && _untyped_nonconst_global(gr)
            return (:nonconst_global, string(gr.mod, ".", gr.name))
        end
        st isa Expr || continue
        if Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke)
            rf = _reflection_callee(ci, st)
            isnothing(rf) || return (:reflection, rf)
        end
        if Meta.isexpr(st, :call)
            af = _abstract_field_read(ci, sig, st)
            isnothing(af) || return (:abstract_field, af)
        end
        if Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke)
            tp = _runtime_type_parameter(ci, sig, st)
            isnothing(tp) || return (:runtime_type_parameter, tp)
        end
    end
    # An element that actually flows into the body, read from a container whose payload type is
    # abstract. The DECLARATION alone is not a cause — `length(v::Vector{Real})` is perfectly stable.
    for T in ci.ssavaluetypes
        _boxy(_unwrap_lattice(T)) || continue
        for A in types
            _abstract_payload(A) && return (:abstract_eltype, string(A))
        end
    end
    # Last, and only with concrete arguments: with an `Any` argument the method count is a symptom of
    # whatever widened it, so naming the count would blame the wrong declaration.
    for st in ci.code
        Meta.isexpr(st, :call) || continue
        csig = _dyn_call_sig(ci, sig, st)
        isnothing(csig) && continue
        # An `Any` argument means something upstream widened it, and the method count is that
        # widening's symptom. An abstract but DECLARED argument type (`::Shape`) is the real thing:
        # the count is exactly why inference gave up on it.
        ps = csig.parameters[2:end]
        any(T -> T === Any, ps) && continue
        n = _match_count(csig)
        fn = _static_callee(ci, st.args[1])
        limit = _max_methods(fn)
        if !isnothing(n) && n > limit
            return (:method_count, "$(n) methods match `$(nameof(fn))`, limit $(limit)")
        end
    end
    return nothing
end

# A `global x::Int` declares a concrete type, so reading it is stable even though the binding is not
# `const`. Only an untyped (or abstractly typed) non-const binding is a cause.
function _untyped_nonconst_global(gr::GlobalRef)
    isconst(gr.mod, gr.name) && return false
    T = try
        Core.get_binding_type(gr.mod, gr.name)
    catch
        Any
    end
    return !(T isa Type) || !isconcretetype(T)
end

# `Val(n)`, `ntuple(f, n)`, `SVector{n}` built from a runtime value: the type parameter is not known
# at compile time, so the result type is not either.
function _runtime_type_parameter(ci, @nospecialize(sig), st::Expr)
    # `ntuple(f, n)` inlines to an `:invoke` of `Base._ntuple` once the length is not a constant, so
    # the resolved form is the one that survives in a body worth blaming.
    if Meta.isexpr(st, :invoke)
        mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
        (mi isa Core.MethodInstance && mi.def isa Method) || return nothing
        return _demangle(mi.def.name) in (:_ntuple, :ntuple) ?
            "a tuple whose length is a value known only at run time" : nothing
    end
    fn = _static_callee(ci, st.args[1])
    isnothing(fn) && return nothing
    (fn === Core.apply_type || nameof(fn) === :Val || nameof(fn) === :ntuple) || return nothing
    for a in st.args[2:end]
        T = _stmt_arg_type(ci, sig, a)
        T isa Core.Const && continue
        a isa GlobalRef && isconst(a.mod, a.name) && continue
        a isa QuoteNode && continue
        a isa Type && continue
        return "`$(nameof(fn))` built from a value known only at run time"
    end
    return nothing
end

# The reason text a `:typestable` finding carries when a cause is recognized.
_cause_reason(cause::Symbol, subject::AbstractString) =
    cause === :captured_variable ? "boxes $subject (Core.Box): every read of it infers as Any" :
    cause === :runtime_type_parameter ? "builds a type from a runtime value: $subject" :
    cause === :nonconst_global ? "reads the non-const global `$subject` (inferred Any)" :
    cause === :abstract_field ? "reads an abstractly typed field `$subject`" :
    cause === :abstract_eltype ? "an element of `$subject` flows into this body" :
    cause === :reflection ? "calls `$subject` (reflection cannot be resolved statically)" :
    "dynamic dispatch: $subject"

# --- dispatch_report ------------------------------------------------------------------------------

struct DispatchSite
    func::String
    signature::String
    callee::String
    detail::String
    file::String
    line::Int
end

"""
    DispatchReport

What [`dispatch_report`](@ref) found in one module: `dynamic` call sites, `cliff` sites (exactly
`limit` methods match, so one more method anywhere makes them dynamic), the count of `nclear`
specializations with neither, and the `limit` itself (`max_methods`). Each site carries the calling
function, its signature, the callee, a detail string and the source location.
"""
struct DispatchReport
    mod::Symbol
    dynamic::Vector{DispatchSite}
    cliff::Vector{DispatchSite}
    nclear::Int
    limit::Int
end

function _site(@nospecialize(f), @nospecialize(types), callee, detail)
    m = try
        which(f, types)
    catch
        nothing
    end
    return DispatchSite(
        _func_name(f), _sig_string(types), callee, detail,
        isnothing(m) ? "" : string(m.file), isnothing(m) ? 0 : Int(m.line)
    )
end

# A method-enumerated (union-split) call: inference matched every method itself and emitted an `isa`
# chain whose fallthrough is `Core.throw_methoderror(callee, arg)`. That marker is how a split site is
# recognizable at all — the split leaves no call behind, only inlined branches. Returns
# `(callee name, matching methods)`.
function _split_site(ci, @nospecialize(sig), st::Expr)
    callee = if Meta.isexpr(st, :invoke)
        mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
        (mi isa Core.MethodInstance && mi.def isa Method && mi.def.name === :throw_methoderror) ?
            st.args[3] : nothing
    elseif Meta.isexpr(st, :call) && _static_callee(ci, st.args[1]) === Core.throw_methoderror
        st.args[2]
    else
        nothing
    end
    isnothing(callee) && return nothing
    fn = _static_callee(ci, callee)
    isnothing(fn) && return nothing
    # `throw_methoderror(f, args...)` carries EVERY argument of the failed call; counting with only
    # the first gives the wrong method set for any callee of more than one argument.
    argidx = Meta.isexpr(st, :invoke) ? 4 : 3
    length(st.args) >= argidx || return nothing
    ats = Any[]
    for a in st.args[argidx:end]
        T = _unwrap_lattice(_stmt_arg_type(ci, sig, a))
        T isa Type || return nothing
        push!(ats, T)
    end
    n = _match_count(Tuple{Core.Typeof(fn), ats...})
    return isnothing(n) ? nothing : (string(nameof(fn)), n, _max_methods(fn))
end

# Every dynamic `:call` in one specialization, plus every method-enumerated call at the limit.
function _dispatch_sites(@nospecialize(f), @nospecialize(types::Tuple), limit::Int)
    dynamic = Tuple{String, String}[]
    cliff = Tuple{String, String}[]
    cis = try
        Base.code_typed(f, types; optimize = true)
    catch
        return (dynamic, cliff)
    end
    isempty(cis) && return (dynamic, cliff)
    ci = first(cis)[1]
    sig = Base.signature_type(f, Tuple{types...})
    for st in ci.code
        st isa Expr || continue
        split = _split_site(ci, sig, st)
        if !isnothing(split)
            name, n, lim = split
            n == lim && push!(cliff, (name, "$n methods match, limit $lim — one more flips it"))
            continue
        end
        Meta.isexpr(st, :call) || continue
        fn = _static_callee(ci, st.args[1])
        if isnothing(fn)
            # A callee held in a variable or an abstractly typed field: dispatched at run time, and
            # the method set cannot even be counted. Silence here would report it as clear.
            T = _unwrap_lattice(_stmt_arg_type(ci, sig, st.args[1]))
            push!(dynamic, (string(T), "callee not statically known"))
            continue
        end
        (fn isa Core.Builtin || fn isa Core.IntrinsicFunction) && continue
        csig = _dyn_call_sig(ci, sig, st)
        isnothing(csig) && continue
        n = _match_count(csig)
        isnothing(n) && continue
        lim = _max_methods(fn)
        n > lim && push!(dynamic, (string(nameof(fn)), "$n methods match, limit $lim"))
    end
    return (unique(dynamic), unique(cliff))
end

"""
    dispatch_report(mod::Module; only = nothing, exempt = ()) -> DispatchReport

Where `mod` dispatches at runtime, and where it is one method away from doing so.

Sweeps every concrete specialization `mod`'s functions have compiled (the same usage-driven coverage
as [`audit`](@ref)`(mod; sweep = true)`) and sorts each call site into three groups:

- **dynamic** — the call matches more methods than inference enumerates (`max_methods`, 3 by
  default), so it dispatches at runtime;
- **at the limit** — the call matches exactly `max_methods` methods. It is static *today*; one more
  method on that function, added anywhere, makes it dynamic with no change to this code;
- **clear** — counted only.

No execution and no backend: it reads typed IR and the method table.

```julia
julia> dispatch_report(MyPkg)
MyPkg — dispatch (max_methods = 3)

DYNAMIC (1)
  render(Shape)          draw.jl:31      area — 4 methods match, limit 3

AT THE LIMIT (1)
  measure(Shape)         shapes.jl:12    area — 3 methods match, limit 3 — one more flips it

CLEAR: 14 specialization(s) with no dynamic or at-the-limit call
```

A dynamic call is not automatically wrong: it buys flexibility and costs static resolution. That
trade is usually fine outside a hot loop and rarely fine inside one — per element over 1000 elements,
an abstract element type measured 24.02 µs / 32 kB against 0.58 µs / 0 B for a concrete or `Union`
one. See the [dynamic dispatch](@ref dynamic-dispatch) guide for the fixes and their measured effect.
"""
function dispatch_report(mod::Module; only = nothing, exempt = ())
    limit = _max_methods()
    dynamic = DispatchSite[]
    cliff = DispatchSite[]
    nclear = 0
    _module_specializations(mod; only, exempt) do f, tt
        dyn, cl = _dispatch_sites(f, tt, limit)
        if isempty(dyn) && isempty(cl)
            nclear += 1
            return nothing
        end
        for (callee, detail) in dyn
            push!(dynamic, _site(f, tt, callee, detail))
        end
        for (callee, detail) in cl
            push!(cliff, _site(f, tt, callee, detail))
        end
        return nothing
    end
    return DispatchReport(nameof(mod), dynamic, cliff, nclear, limit)
end

"""
    dispatch_suggestions(f, types) -> Vector{StrictFinding}
    dispatch_suggestions(mod::Module; only = nothing, exempt = ()) -> Vector{StrictFinding}

The same sites [`dispatch_report`](@ref) prints, as informational findings (`guarantee = :dispatch`,
`status = :info`, never a failure) so [`audit`](@ref) can carry them. Pass
`dispatch_suggest = true` to `audit`.

A dynamic site says the call dispatches at run time. An at-the-limit site says it does not yet: it
matches exactly `max_methods` methods, and one more method on that function — defined anywhere, by
anyone — makes it dynamic without touching this code.
"""
function dispatch_suggestions(@nospecialize(f), @nospecialize(types::Tuple))
    out = StrictFinding[]
    dyn, cl = _dispatch_sites(f, types, _max_methods())
    # Nothing to report is the common case on clean code (0 findings over 10,974 PureBLAS
    # specializations), so the naming and the `which` lookup wait until there is a finding to carry
    # them rather than being paid per specialization.
    (isempty(dyn) && isempty(cl)) && return out
    md, fn, sg = _mod_sym(f), _func_name(f), _sig_string(types)
    m = try
        which(f, types)
    catch
        nothing
    end
    file = isnothing(m) ? "" : string(m.file)
    line = isnothing(m) ? 0 : Int(m.line)
    for (callee, detail) in dyn
        push!(
            out, StrictFinding(
                md, fn, sg, :dispatch, :info, file, line,
                "dispatches at run time: `$callee` — $detail",
                _cause_suggestion(:method_count)
            )
        )
    end
    for (callee, detail) in cl
        push!(
            out, StrictFinding(
                md, fn, sg, :dispatch, :info, file, line,
                "one method from dynamic: `$callee` — $detail",
                "nothing is wrong today. If this call must stay static, keep the method set closed " *
                    "(a `Union` of concrete types, or a sealed set of methods), or raise the limit " *
                    "where the callee lives with `Base.Experimental.@max_methods N`."
            )
        )
    end
    return out
end

function dispatch_suggestions(mod::Module; only = nothing, exempt = ())
    out = StrictFinding[]
    _module_specializations(mod; only, exempt) do f, tt
        append!(out, dispatch_suggestions(f, tt))
        return nothing
    end
    return out
end

function Base.show(io::IO, r::DispatchReport)
    println(io, r.mod, " — dispatch (max_methods = ", r.limit, " by default; each line names the limit that applies)")
    for (title, sites) in (("DYNAMIC", r.dynamic), ("AT THE LIMIT", r.cliff))
        isempty(sites) && continue
        println(io, "\n", title, " (", length(sites), ")")
        for s in sites
            loc = isempty(s.file) ? "" : string(basename(s.file), ":", s.line)
            println(io, "  ", rpad(s.func * s.signature, 38), rpad(loc, 22), s.callee, " — ", s.detail)
        end
    end
    print(io, "\nCLEAR: ", r.nclear, " specialization(s) with no dynamic or at-the-limit call")
    return nothing
end
