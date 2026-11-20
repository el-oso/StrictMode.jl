# Which functions a call reaches, read from OPTIMIZED typed IR.
#
# Two entry points to one operation can each pass every per-function guarantee and still take
# different routes: one calls a shared core with its defaults, the other picks threading first.
# The difference is then a constant propagated into an inlined call, and only the optimizer's
# output shows it — the branch the constant rules out is deleted, and the callees it held go with
# it. Unoptimized IR has neither the propagation nor the callees behind the first hop.
#
# A function is reached in one of two ways:
# - it survives as a call: an `:invoke`, a call left to run-time dispatch that matches few enough
#   methods to enumerate, or the closure of a spawned task;
# - it was inlined, and statements of its body survive. The optimizer drops call statements for
#   inlined callees, so those are read from the inlining edges of the body's debug info, which
#   name a callee only while some statement of it is still there.
#
# Functions are identified by `(module, name)` with the keyword-sorter mangling removed, so a
# keyword method, its body function and its positional method count as one function.
#
# Whatever could not be read is counted: a signature with no typed IR, and a call site whose callee
# is not known. A reach with a positive count is a lower bound, and nothing here presents it as
# the whole graph.

"""
    StrictMode.ReachedFunction

One function a call reaches. `depth` is the number of calls between the entry and the nearest
occurrence; `inlined` says every occurrence was inlined into its caller.
"""
struct ReachedFunction
    mod::Module
    name::Symbol
    depth::Int
    inlined::Bool
end

Base.show(io::IO, f::ReachedFunction) = print(io, f.mod, ".", f.name)

"""
    StrictMode.ReachReport

What [`reach_report`](@ref StrictMode.reach_report) read: the `functions` reached, nearest first,
from `bodies` method bodies. `unread` counts signatures whose typed IR could not be read and
`dynamic` the call sites whose callee is unknown or matches too many methods to enumerate. When
either is positive the list is a lower bound.
"""
struct ReachReport
    target::String
    functions::Vector{ReachedFunction}
    bodies::Int
    unread::Int
    dynamic::Int
end

const _REACH_MAX_BODIES = 4096
# A run-time dispatch is followed when it can land on at most this many methods.
const _REACH_MAX_METHODS = 4

mutable struct _Reach
    found::Dict{Tuple{Module, Symbol}, ReachedFunction}
    bodies::Int
    unread::Int
    dynamic::Int
end

_reach_key(m::Method) = (m.module, _demangle(m.name))
_reach_key(@nospecialize(f)) =
    (parentmodule(f isa Function ? f : Core.Typeof(f)), _demangle(_callable_name(f)))

function _reach_record!(r::_Reach, key::Tuple{Module, Symbol}, depth::Int, inlined::Bool)
    old = get(r.found, key, nothing)
    r.found[key] = isnothing(old) ? ReachedFunction(key[1], key[2], depth, inlined) :
        ReachedFunction(key[1], key[2], min(depth, old.depth), inlined && old.inlined)
    return nothing
end

# Every callee inlined into this body whose statements survive. A hub named in `stop` is recorded
# and not entered, inlined or not: what was inlined into it stays out, as its out-of-line callees do.
function _reach_inlined!(r::_Reach, di, depth::Int, stop)
    di isa Core.DebugInfo || return nothing
    for e in di.edges
        e isa Core.DebugInfo || continue
        m = e.def isa Core.MethodInstance ? e.def.def : e.def
        if m isa Method
            key = _reach_key(m)
            _reach_record!(r, key, depth, true)
            key in stop && continue
        end
        _reach_inlined!(r, e, depth, stop)
    end
    return nothing
end

# Whether statement `pc` of a body came from inlining a hub named in `stop`, read from the inlining
# chain its debug info records: `(line, edge, pc within that edge)` per level.
function _reach_inlined_through(di, pc::Int, stop)
    for _ in 1:64
        di isa Core.DebugInfo || return false
        t = try
            Core.Compiler.getdebugidx(di, pc)
        catch
            return false
        end
        eidx = Int(t[2])
        (1 <= eidx <= length(di.edges)) || return false
        e = di.edges[eidx]
        e isa Core.DebugInfo || return false
        m = e.def isa Core.MethodInstance ? e.def.def : e.def
        m isa Method && _reach_key(m) in stop && return true
        di = e
        pc = Int(t[3])
    end
    return false
end

function _reach_argtype(ci::Core.CodeInfo, @nospecialize(sig), @nospecialize(a))
    T = if a isa Core.SSAValue
        ci.ssavaluetypes isa Vector ? _widen_taint(ci.ssavaluetypes[a.id]) : Any
    elseif a isa Core.Argument
        ps = sig isa DataType ? sig.parameters : ()
        a.n <= length(ps) ? ps[a.n] : Any
    elseif a isa QuoteNode
        Core.Typeof(a.value)
    elseif a isa GlobalRef
        isconst(a.mod, a.name) ? Core.Typeof(getglobal(a.mod, a.name)) : Any
    else
        Core.Typeof(a)
    end
    return T isa Type ? T : Any
end

# A call left to run-time dispatch on a known function. The function is reached whatever method
# runs; the methods are followed only when the argument types narrow them to a few.
function _reach_dispatch!(
        r::_Reach, ci::Core.CodeInfo, @nospecialize(sig), st::Expr, @nospecialize(f),
        depth::Int, stop, queue::Vector{Any}
    )
    key = _reach_key(f)
    _reach_record!(r, key, depth, false)
    key in stop && return nothing
    tt = try
        Tuple{Core.Typeof(f), (_reach_argtype(ci, sig, a) for a in st.args[2:end])...}
    catch
        nothing
    end
    ms = isnothing(tt) ? nothing :
        Base._methods_by_ftype(tt, _REACH_MAX_METHODS, Base.get_world_counter())
    if !(ms isa Vector) || isempty(ms)
        # A Base function called on Base's own types stays in Base, which the walk does not enter
        # either way, so nothing of the route is lost behind it.
        stays_in_base = !isnothing(tt) && _sw_is_base(key[1]) && !_sw_carries_user_function(tt)
        stays_in_base || (r.dynamic += 1)
        return nothing
    end
    for match in ms
        m = match.method
        (!_sw_is_base(m.module) || _sw_carries_user_function(match.spec_types)) &&
            push!(queue, (match.spec_types, depth))
    end
    return nothing
end

function _reach_scan!(
        r::_Reach, ci::Core.CodeInfo, @nospecialize(sig), depth::Int, stop, queue::Vector{Any}
    )
    _reach_inlined!(r, ci.debuginfo, depth, stop)
    for i in eachindex(ci.code)
        st = ci.code[i]
        st isa Expr || continue
        isempty(stop) || !_reach_inlined_through(ci.debuginfo, i, stop) || continue
        if st.head === :invoke
            mi = _invoke_mi(st.args[1])
            if !(mi isa Core.MethodInstance && mi.def isa Method)
                r.dynamic += 1
                continue
            end
            key = _reach_key(mi.def)
            _reach_record!(r, key, depth, false)
            key in stop || !_sw_follows(mi) || push!(queue, (mi.specTypes, depth))
        elseif st.head === :call
            v = _sw_callee_value(st.args[1])
            if v isa Core.IntrinsicFunction || v isa Core.Builtin
                nameof(v) in _SW_DYNAMIC_BUILTINS && (r.dynamic += 1)
            elseif isnothing(v)
                r.dynamic += 1
            else
                _reach_dispatch!(r, ci, sig, st, v, depth, stop, queue)
            end
        elseif st.head === :foreigncall && _fcall_name(st) === :jl_new_task
            T = _sw_task(ci, i, st, sig).T
            isnothing(T) ? (r.unread += 1) : push!(queue, (Tuple{T}, depth))
        end
    end
    return r
end

# Breadth first, so a function's depth is its nearest occurrence.
function _reach(@nospecialize(sig), stop)
    r = _Reach(Dict{Tuple{Module, Symbol}, ReachedFunction}(), 0, 0, 0)
    seen = Set{Any}()
    queue = Any[(sig, 0)]
    while !isempty(queue)
        s, d = popfirst!(queue)
        s in seen && continue
        push!(seen, s)
        if r.bodies >= _REACH_MAX_BODIES
            r.unread += 1
            continue
        end
        cts = try
            _code_typed_by_type(s; optimize = true, debuginfo = :source)
        catch
            Any[]
        end
        read = false
        for pr in cts
            ci = first(pr)
            ci isa Core.CodeInfo || continue
            read = true
            r.bodies += 1
            _reach_scan!(r, ci, s, d + 1, stop, queue)
        end
        read || (r.unread += 1)
    end
    return r
end

_reach_in_module(m::Module, mod::Module) =
    m === mod || (parentmodule(m) !== m && _reach_in_module(parentmodule(m), mod))

_reach_target(@nospecialize(f), @nospecialize(types::Tuple)) =
    string(f isa Function || f isa Type ? f : typeof(f)) * _sig_string(types)

"""
    StrictMode.reach_report(f, types; mod = nothing, stop = ()) -> ReachReport

The functions the call `f(types...)` reaches, read from optimized typed IR: the ones it calls, the
ones inlined into it, and the ones those reach in turn, including through the tasks it spawns.

Because the graph is taken after optimization, a callee behind a branch that constant propagation
rules out is not reached. That is what separates an entry that passes a shared core its defaults
from one that chooses a route first.

- `mod` keeps only the functions defined in that module or its submodules. The walk still crosses
  other packages; this filters what is listed.
- `stop` names functions that are recorded but not entered. A thread pool's dispatcher reaches
  every job the package can submit, so naming it keeps the list about the route.
  An entry the call does not name anywhere it reaches raises an `ArgumentError`: it cut nothing.
  A hub the source calls and the optimizer folded away is named, and does not raise.

A callee in Base is entered only when it was handed a function from outside Base, such as a
closure passed to `foreach`.

`unread` and `dynamic` on the report count what could not be read, and the list is a lower bound
when either is positive. For a keyword call, pass `Core.kwcall` and its signature:
`reach_report(Core.kwcall, (typeof((; k = 1.0)), typeof(f), Matrix{Float64}))`.

```julia
r = StrictMode.reach_report(gemm!, (Matrix{Float64}, Matrix{Float64}, Matrix{Float64}); mod = MyBLAS)
StrictMode.reaches(r, MyBLAS._gemm_threaded!)
```
"""
function reach_report(
        @nospecialize(f), @nospecialize(types::Tuple); mod::Union{Nothing, Module} = nothing,
        stop = ()
    )
    r, unmet = _reach_report(f, types; mod, stop)
    isempty(unmet) || throw(ArgumentError(_stop_unmet("reach_report", r.target, unmet)))
    return r
end

# A `stop` entry the walk never met cuts nothing. The caller named a hub this call does not
# reach, or misspelled one, and the graph is the uncut one either way.
_stop_unmet(caller::String, target, unmet) =
    "$caller: `stop` names " * join(("`$(g)`" for g in unmet), ", ") * ", which $target does not " *
    "reach, so nothing was cut there. Check the name, or drop the entry."

# Which of `keys` some body reachable from `sig` calls by name, read from typed IR BEFORE
# optimization, where every call the source wrote is still a statement. Callees outside Base are
# followed, at the argument types inference gave the call.
const _REACH_NAMED_BODIES = 512
function _reach_named_unoptimized(@nospecialize(sig), keys::Set{Tuple{Module, Symbol}})
    found = Set{Tuple{Module, Symbol}}()
    seen = Set{Any}()
    queue = Any[sig]
    while !isempty(queue) && length(seen) < _REACH_NAMED_BODIES && length(found) < length(keys)
        s = popfirst!(queue)
        s in seen && continue
        push!(seen, s)
        cts = try
            _code_typed_by_type(s; optimize = false)
        catch
            continue
        end
        for (ci, _) in cts
            for st in ci.code
                Meta.isexpr(st, :(=)) && (st = st.args[2])
                callee, args = _call_callee_and_args(ci, st)
                (isnothing(callee) || callee isa Core.Builtin || callee isa Core.IntrinsicFunction) && continue
                key = try
                    _reach_key(callee)
                catch
                    continue
                end
                key in keys && push!(found, key)
                _sw_is_base(key[1]) && continue
                ats = Any[_unopt_arg_type(ci, a) for a in args]
                all(T -> T isa Type, ats) || continue
                push!(queue, Tuple{Core.Typeof(callee), ats...})
            end
        end
    end
    return found
end

# The report, and the `stop` entries the walk never met.
function _reach_report(
        @nospecialize(f), @nospecialize(types::Tuple); mod::Union{Nothing, Module} = nothing,
        stop = ()
    )
    target = _reach_target(f, types)
    cts = try
        _code_typed(f, types; optimize = true)
    catch err
        throw(ArgumentError("reach_report: could not analyze $target: $(sprint(showerror, err))"))
    end
    isempty(cts) && throw(ArgumentError("reach_report: no method matches $target"))
    stopkeys = Set{Tuple{Module, Symbol}}(_reach_key(g) for g in stop)
    r = _reach(Base.signature_type(f, types), stopkeys)
    unmet = Any[g for g in stop if !haskey(r.found, _reach_key(g))]
    # A hub the walk did not meet may still be one the code calls: a call the optimizer folded
    # away leaves no statement and no inlining edge. Whether that happened depends on the
    # compiler, and a `stop` list must not. So an entry is unmet only when no body the call
    # reaches names it before optimization.
    if !isempty(unmet)
        named = _reach_named_unoptimized(Base.signature_type(f, types), Set{Tuple{Module, Symbol}}(_reach_key(g) for g in unmet))
        filter!(g -> !(_reach_key(g) in named), unmet)
    end
    fs = collect(values(r.found))
    isnothing(mod) || filter!(x -> _reach_in_module(x.mod, mod), fs)
    sort!(fs; by = x -> (x.depth, string(x.mod), string(x.name)))
    return ReachReport(target, fs, r.bodies, r.unread, r.dynamic), unmet
end

"""
    StrictMode.reaches(r::ReachReport, g) -> Bool

Whether the function `g` is among the functions `r` reached.
"""
reaches(r::ReachReport, @nospecialize(g)) =
    (k = _reach_key(g); any(x -> (x.mod, x.name) == k, r.functions))

"""
    StrictMode.complete(r::ReachReport) -> Bool

Whether the whole graph was read: no unread signature and no call site with an unknown callee.
"""
complete(r::ReachReport) = iszero(r.unread) && iszero(r.dynamic)

function _reach_gaps(io::IO, r::ReachReport)
    complete(r) && return nothing
    printstyled(io, "  [not read] "; color = :yellow, bold = true)
    print(
        io, r.unread, " signature(s) without typed IR, ", r.dynamic,
        " call site(s) with an unknown callee — the list is a lower bound\n"
    )
    return nothing
end

function Base.show(io::IO, r::ReachReport)
    printstyled(io, "ReachReport"; bold = true)
    print(io, ": ", r.target, " — ", length(r.functions), " function(s) from ", r.bodies, " body(ies)\n")
    for f in r.functions
        print(io, "  ", lpad(f.depth, 2), "  ", f, f.inlined ? "  (inlined)" : "", "\n")
    end
    _reach_gaps(io, r)
    return nothing
end

# --- one target -------------------------------------------------------------------------------

# Finding the target is exact: it is in the compiled graph. Not finding it is exact only when the
# whole graph was read, so that is the case that raises; with part of the graph unread the target
# may sit behind it, and the verdict is reported instead.
function _reaches_reason(r::ReachReport, @nospecialize(g))
    k = _reach_key(g)
    why = "`$(k[1]).$(k[2])` is not among the $(length(r.functions)) function(s) this call reaches"
    complete(r) && return why * ". The graph is taken after optimization, so a callee behind a " *
        "branch that constant propagation rules out — a default argument, a `false` flag — is " *
        "not reached. `StrictMode.reach_report` lists what is."
    return why * " in what could be read: $(r.unread) signature(s) had no typed IR and " *
        "$(r.dynamic) call site(s) have an unknown callee, and the target may sit behind one."
end

function _assert_reaches(target, @nospecialize(f), @nospecialize(types), @nospecialize(g))
    r = reach_report(f, Tuple(types))
    reaches(r, g) && return nothing
    _fail(:reaches, target, _reaches_reason(r, g); gates = complete(r))
    return nothing
end

"""
    @assert_reaches f(args...) g

Check that the function `g` is in the call graph of `f(args...)` after optimization — that this
entry really takes the route through `g`.

It throws when `g` is absent and the whole graph was read, and warns when `g` is absent but part
of the graph could not be read, since the target may sit behind that part. See
[`StrictMode.reach_report`](@ref) for how the graph is read, and
[`StrictMode.route_parity`](@ref) to compare two entries without naming a target.

The macro returns the call's value, and the check runs once per call site and argument signature.

```julia
@assert_reaches gemm!(C, A, B) MyBLAS._gemm_threaded!
```
"""
macro assert_reaches(call, g)
    # The target is an expression for a function, so `key = value` there is an option the macro
    # does not have, not a target.
    (Meta.isexpr(g, :(=)) && g.args[1] isa Symbol) &&
        throw(ArgumentError(_unknown_option("@assert_reaches", g.args[1], ())))
    checked = _guarantee_expr(call, _assert_reaches, esc(g))
    return _gate(checked, esc(call))
end

macro assert_reaches(args...)
    return _reject_options("@assert_reaches", args, "a call and a target function")
end

# --- two entries ------------------------------------------------------------------------------

"""
    StrictMode.RouteParity

What [`route_parity`](@ref StrictMode.route_parity) found: the reach of each entry and the
functions only one of them reaches, nearest to the entry first.
"""
struct RouteParity
    a::ReachReport
    b::ReachReport
    only_a::Vector{ReachedFunction}
    only_b::Vector{ReachedFunction}
end

"""
    StrictMode.status(p::RouteParity) -> Symbol

- `:differ` — some function is reached by one entry only.
- `:agree` — both graphs were read in full, each reaches at least one function, and they reach the
  same ones.
- `:incomplete` — no difference in what was read, but a graph is empty or has unread parts, so the
  routes are not shown to agree.
"""
function status(p::RouteParity)
    (isempty(p.only_a) && isempty(p.only_b)) || return :differ
    complete(p.a) && complete(p.b) && !isempty(p.a.functions) && !isempty(p.b.functions) &&
        return :agree
    return :incomplete
end

# A closure is named after the function that defines it, so the two entries' own closures always
# differ. What a closure reaches is compared; the closure is not.
_reach_is_closure(f::ReachedFunction) = startswith(String(f.name), "#")

"""
    StrictMode.route_parity(f => types, g => types; mod = nothing, stop = ()) -> RouteParity

Compare the functions two calls reach and report the ones only one of them reaches.

For two entry points to one operation — a native method and its C-ABI wrapper, a keyword method
and the positional one behind it — that should take the same route. Each side is read as
[`reach_report`](@ref StrictMode.reach_report) reads it, so a callee that one entry rules out with
a default argument appears on the other side only.

Pass `mod` to compare one module's functions; without it every difference in Base's helpers is
listed too. The entries themselves and their closures are not compared, only what they reach.
Differences are ordered by distance from the entry, so the function where the routes part comes
first and what lies behind it follows; `stop` cuts a hub such as a pool dispatcher short.

[`status`](@ref StrictMode.status) is `:agree` only when both graphs were read in full and are
not empty. An entry whose graph could not be read is `:incomplete`, never agreement.

```julia
T = (Matrix{Float64}, Matrix{Float64}, Matrix{Float64})
p = StrictMode.route_parity(MyBLAS.gemm! => T, MyBLAS.gemm_cabi! => T; mod = MyBLAS)
StrictMode.status(p)
```
"""
function route_parity(a::Pair, b::Pair; mod::Union{Nothing, Module} = nothing, stop = ())
    ra, ua = _reach_report(a.first, Tuple(a.second); mod, stop)
    rb, ub = _reach_report(b.first, Tuple(b.second); mod, stop)
    # A hub one route reaches and the other does not is a difference between them, which is what
    # this reports. One neither reaches cut nothing.
    unmet = Any[g for g in ua if any(h -> h === g, ub)]
    isempty(unmet) ||
        throw(ArgumentError(_stop_unmet("route_parity", "neither " * ra.target * " nor " * rb.target, unmet)))
    entries = Set{Tuple{Module, Symbol}}((_reach_key(a.first), _reach_key(b.first)))
    keys_a = Set((x.mod, x.name) for x in ra.functions)
    keys_b = Set((x.mod, x.name) for x in rb.functions)
    differs(x, other) =
        !((x.mod, x.name) in other) && !((x.mod, x.name) in entries) && !_reach_is_closure(x)
    return RouteParity(
        ra, rb, filter(x -> differs(x, keys_b), ra.functions),
        filter(x -> differs(x, keys_a), rb.functions)
    )
end

function _parity_reason(p::RouteParity)
    s = status(p)
    s === :agree && return ""
    side(r, fs) = isempty(fs) ? "" :
        "only `$(r.target)` reaches " * join(("`$f`" for f in first(fs, 8)), ", ") *
        (length(fs) > 8 ? " and $(length(fs) - 8) more" : "")
    if s === :differ
        return join(filter(!isempty, [side(p.a, p.only_a), side(p.b, p.only_b)]), "; ") *
            ". Nearest to the entry first: the first name is where the routes part."
    end
    gap(r) = "`$(r.target)` reached $(length(r.functions)) function(s) with $(r.unread) " *
        "signature(s) unread and $(r.dynamic) call site(s) of unknown callee"
    return "no difference in what was read, but the graphs are not complete, so the routes are " *
        "not shown to agree: " * gap(p.a) * "; " * gap(p.b) * "."
end

function Base.show(io::IO, p::RouteParity)
    s = status(p)
    printstyled(io, "RouteParity"; bold = true)
    print(io, ": ", p.a.target, " against ", p.b.target, "\n")
    for (r, fs) in ((p.a, p.only_a), (p.b, p.only_b))
        isempty(fs) && continue
        printstyled(io, "  only ", r.target, " reaches\n"; color = :yellow, bold = true)
        for f in first(fs, 12)
            print(io, "    ", lpad(f.depth, 2), "  ", f, f.inlined ? "  (inlined)" : "", "\n")
        end
        length(fs) > 12 && print(io, "    … and ", length(fs) - 12, " more behind those\n")
    end
    _reach_gaps(io, p.a)
    _reach_gaps(io, p.b)
    if s === :agree
        printstyled(io, "  same route"; color = :green)
        print(io, ": both reach the same ", length(p.a.functions), " function(s)\n")
    elseif s === :incomplete
        printstyled(io, "  not shown to agree"; color = :yellow, bold = true)
        print(
            io, ": no difference in what was read (", length(p.a.functions), " and ",
            length(p.b.functions), " function(s))\n"
        )
    end
    return nothing
end
