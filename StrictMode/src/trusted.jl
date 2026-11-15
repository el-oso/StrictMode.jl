# `:trusted` — data from outside the program carries that fact in its type, and only a registered
# boundary may read the payload. This is the Julia form of the Linux kernel's `__user` pointer
# annotation (`include/linux/compiler_types.h`): `Untrusted{T}` is the distinct type that
# `address_space(__user)` creates, the `getproperty` override is `noderef`, `unsafe_trust` is the
# `__force` cast, and the scan below is the checker that finds the cast used outside a
# boundary.
#
# Dispatch does most of the work with no checker at all: `Untrusted{Vector{UInt8}}` matches no
# method written for `Vector{UInt8}`, so an ordinary use of the payload is a `MethodError` — in a
# shipped build too, since the type is never gated away. What the scan adds is the part the
# language cannot enforce: `getfield` is a builtin and `unsafe_trust` is callable from anywhere,
# exactly as a `__force` cast compiles fine wherever it appears.
#
# Detection reads **unoptimized** typed IR. A small trust boundary inlines under optimization and
# its `getfield` then surfaces in the caller's IR, which would report the caller as the violator.

"""
    Untrusted(x)

Mark `x` as data from outside the program — read from a socket or a file, taken from `ARGS`, or
handed over by a device.

Nothing can be done with the wrapped value except pass it along or give it to a **trust boundary**:
a function that validates it and returns a plain value, registered with [`trust_boundary!`](@ref).
Ordinary methods do not match `Untrusted{T}`, so an accidental use raises a `MethodError` instead
of quietly succeeding, and `u.x` throws. The one deliberate way out is [`unsafe_trust`](@ref).

Wrapping is free: `Untrusted{T}` has the same layout as `T` and allocates nothing. Wrapping twice
returns the same value, so an edge that wraps defensively costs nothing.

[`@assert_trusted`](@ref) fails on any function outside a boundary that reads the payload.

```julia
function parse_header(u::Untrusted{Vector{UInt8}})
    b = unsafe_trust(u)
    length(b) >= 4 || throw(ArgumentError("short header"))
    return Header(copy(b))          # copy: the caller still owns the buffer
end
trust_boundary!(parse_header)
```
"""
struct Untrusted{T}
    x::T
end

Untrusted(u::Untrusted) = u

Base.getproperty(::Untrusted, name::Symbol) = error(
    "`Untrusted` data has no readable fields (tried `.$name`). Validate it in a function " *
        "registered with `trust_boundary!`, which reads the payload with `unsafe_trust`."
)

"""
    unsafe_trust(u::Untrusted)

Return the wrapped payload, unvalidated.

This is the one deliberate way out of [`Untrusted`](@ref), and it is `unsafe_` for the usual
reason: nothing has checked the value. Call it inside a function registered with
[`trust_boundary!`](@ref) — that is where [`@assert_trusted`](@ref) permits it. Anywhere else, the
check fails on the call site.
"""
@noinline unsafe_trust(u::Untrusted) = getfield(u, :x)

const _TRUST_BOUNDARIES = Base.IdSet{Any}()

"""
    trust_boundary!(f) -> f

Register `f` as a validating crossing: the one place [`@assert_trusted`](@ref) permits a read of an
[`Untrusted`](@ref) payload.

`f` is expected to validate what it reads, and to **copy** anything it hands back — the caller
still holds the original buffer and can write to it afterwards, which is why the kernel's
`copy_from_user` copies rather than aliasing. Neither property is checked; registering `f` asserts
both.
"""
trust_boundary!(@nospecialize(f)) = (push!(_TRUST_BOUNDARIES, f); f)

# The calls that read the payload. `Base.getfield === Core.getfield`, so one entry covers both
# spellings. `getproperty` is here even though the override above already throws on it: reporting
# it at check time is more use than a runtime error in whatever session first hits that branch.
const _DEREF_FUNCS = (Core.getfield, Base.getproperty, unsafe_trust)

# Callee names of the payload reads in `f`'s OWN body — empty when there are none, and `nothing`
# when the typed IR could not be obtained, which a caller must not read as "no sites".
# `Untrusted` carries one field, so a read of it is `unsafe_trust`, the field's name, or the index
# 1. When the object's type is erased this is the only evidence left, and it is what keeps the
# erased case from firing on every `getfield` on an `Any`: a read of some OTHER field cannot be a
# read of this one. Measured over StrictMode itself, which holds no `Untrusted` at all — 130 erased
# derefs, of which 2 touch this field.
const _UNTRUSTED_FIELD = first(fieldnames(Untrusted))

function _reads_untrusted_field(@nospecialize(callee), args)
    callee === unsafe_trust && return true
    length(args) >= 2 || return false
    fld = args[2]
    fld isa QuoteNode && (fld = fld.value)
    return fld === _UNTRUSTED_FIELD || fld === 1
end

# The payload reads in `f`'s OWN body, split by whether inference pinned the object's type down:
# `certain` are reads of a value typed `<:Untrusted`, `erased` are reads of a value whose type
# merely FAILS TO RULE OUT `Untrusted` — an `Any` carries no `Untrusted` for dispatch to match on,
# and a type the scan cannot narrow is not a type it has cleared. `nothing` when the typed IR could
# not be obtained, which a caller must not read as "none".
function _untrusted_deref_sites(@nospecialize(f), @nospecialize(types::Tuple))
    f in _TRUST_BOUNDARIES && return (Symbol[], Symbol[])
    cts = try
        _code_typed(f, types; optimize = false)
    catch
        return nothing
    end
    isempty(cts) && return nothing
    ci = first(cts)[1]
    certain = Symbol[]
    erased = Symbol[]
    for st in ci.code
        callee, args = _call_callee_and_args(ci, st)
        (callee in _DEREF_FUNCS && !isempty(args)) || continue
        T = _unopt_arg_type(ci, args[1])
        T isa Type || continue
        if T <: Untrusted
            push!(certain, nameof(callee))
        elseif typeintersect(T, Untrusted) !== Union{} && _reads_untrusted_field(callee, args)
            push!(erased, nameof(callee))
        end
    end
    return (certain, erased)
end

function _trusted_reason(certain::Vector{Symbol}, erased::Vector{Symbol})
    parts = String[]
    isempty(certain) || push!(
        parts,
        "reads an `Untrusted` payload outside a trust boundary " *
            "($(join(sort(unique(certain)), ", "))) — $(length(certain)) site(s)"
    )
    isempty(erased) || push!(
        parts,
        "may read an `Untrusted` payload — inference lost the object's type at " *
            "$(length(erased)) site(s) ($(join(sort(unique(erased)), ", "))), so the read cannot " *
            "be ruled out. An `Any`-typed value carries no `Untrusted` for dispatch to refuse, " *
            "which is the one hole in this guarantee: annotate the value, or move the read into a " *
            "boundary registered with `trust_boundary!`"
    )
    return join(parts, "; ")
end

function _foreign_reason(c::Vector{String}, u::Vector{String})
    parts = String[]
    isempty(c) || push!(parts, "reads foreign memory outside a trust boundary ($(length(c)) site(s)): " * join(c, "; "))
    isempty(u) || push!(parts, "cannot rule out a read of foreign memory ($(length(u)) site(s)): " * join(u, "; "))
    return join(parts, "; ")
end

function _trusted_finding(@nospecialize(f), @nospecialize(types::Tuple), md, fn, sg; tier::Symbol = :report)
    sites = _untrusted_deref_sites(f, types)
    isnothing(sites) &&
        return _unevaluated(md, fn, sg, :trusted, "no typed IR for this signature"; tier)
    certain, erased = sites
    fc, fu = _foreign_sites(f, types, _foreign_positions(f))
    m = try
        which(f, types)
    catch
        nothing
    end
    reason = join(filter(!isempty, [_trusted_reason(certain, erased), _foreign_reason(fc, fu)]), "; ")
    return _mkfinding(
        md, fn, sg, :trusted, !isempty(certain) || !isempty(erased) || !isempty(fc) || !isempty(fu),
        reason,
        isnothing(m) ? "" : string(m.file), isnothing(m) ? 0 : Int(m.line);
        tier
    )
end

function _assert_trusted(target, @nospecialize(f), @nospecialize(types::Tuple); foreign = _foreign_positions(f))
    fc, fu = _foreign_sites(f, types, foreign)
    if !isempty(fc)
        _fail(
            :trusted, target, _foreign_reason(fc, fu) * ": validate and copy the data in a function " *
                "registered with `trust_boundary!`, and read only what it returns."
        )
    elseif !isempty(fu)
        _fail(:trusted, target, _foreign_reason(fc, fu) * "."; gates = false)
    end
    sites = _untrusted_deref_sites(f, types)
    if isnothing(sites)
        _fail(:trusted, target, "no typed IR for this signature, so the guarantee is unchecked")
        return nothing
    end
    certain, erased = sites
    if !isempty(certain)
        _fail(
            :trusted, target, _trusted_reason(certain, erased) * ": move the read into a " *
                "validating function that returns a plain value, and register it with " *
                "`trust_boundary!`."
        )
    elseif !isempty(erased)
        # An erased object type is inference failing to answer, not the scan observing a read, so
        # this reports where a certain site throws — the same split `_guarantee_gates` draws between
        # a check that OBSERVES and one that cannot. A `getfield` on an `Any` is ordinary code, and
        # aborting a build over one would make the guarantee unusable.
        _fail(:trusted, target, _trusted_reason(certain, erased) * "."; gates = false)
    end
    return nothing
end

# ── foreign raw pointers ───────────────────────────────────────────────────────────────────────────
#
# A C entry point takes `Ptr`, not `Untrusted`, because its signature is the C ABI. Its foreign
# arguments are named by position instead, and followed as data: a value derived from one (pointer
# arithmetic, a conversion, an array `unsafe_wrap`ped around it, a struct holding it) is foreign too,
# and a READ of foreign memory outside a registered trust boundary is the violation. Handing a foreign
# pointer to C is not a read.

const _FOREIGN_ENTRIES = IdDict{Any, Tuple{Vararg{Int}}}()
const _FOREIGN_LOCK = ReentrantLock()

"""
    trust_foreign!(f, positions) -> f

Declare which arguments of `f` are raw pointers from foreign code, for [`@assert_trusted`](@ref)
and every sweep of `:trusted`: argument `k` for each `k` in `positions`. Use it on a C entry point
(`Base.@ccallable`), whose signature must stay `Ptr`.
"""
function trust_foreign!(@nospecialize(f), positions)
    ps = Tuple(Int(k) for k in positions)
    all(>=(1), ps) || throw(ArgumentError("trust_foreign!: positions are argument numbers, from 1; got $positions"))
    @lock _FOREIGN_LOCK (_FOREIGN_ENTRIES[f] = ps)
    clear_cache!()
    return f
end

_foreign_positions(@nospecialize(f)) = @lock _FOREIGN_LOCK get(_FOREIGN_ENTRIES, f, ())

# Calls that carry foreign data on without reading it: the result is foreign too.
const _FOREIGN_CARRY = (
    +, -, Core.bitcast, reinterpret, convert, Base.unsafe_convert, Base.cconvert, unsafe_wrap,
    pointer, view, reshape, oftype, Core.typeassert, getfield, getproperty, Core.tuple, UInt, Int,
    UInt64, Int64, identity,
)
# Calls that look at foreign data without reading the memory behind it.
const _FOREIGN_INERT = (
    ==, !=, ===, !==, <, <=, >, >=, isequal, length, size, axes, eachindex, firstindex, lastindex,
    typeof, isa, isnothing, Base.isdone, string,
)

# The reads of foreign memory in one body: `(certain, uncertain, returns_foreign)`. `certain` names
# each read and the chain of package calls that reached it; `uncertain` names a dynamic call or a
# callee too deep to read that was handed a foreign value.
function _foreign_reads(@nospecialize(sig), positions, chain::Vector{String}, depth::Int, memo::Dict{Any, Any})
    key = (sig, positions)
    haskey(memo, key) && return something(memo[key], (String[], String[], false))
    memo[key] = nothing                                   # in progress: a recursive call reads nothing new
    certain = String[]
    uncertain = String[]
    cts = try
        _code_typed_by_type(sig; optimize = false)
    catch
        Any[]
    end
    if length(cts) != 1
        push!(uncertain, join([chain; "no single typed body for $(sig)"], " → "))
        r = (certain, uncertain, true)
        memo[key] = r
        return r
    end
    ci = first(cts[1])
    code = ci.code
    slots = BitSet(k + 1 for k in positions)              # slot 1 is the function itself
    tset = BitSet()
    tainted(@nospecialize(a)) = (a isa Core.SSAValue && a.id in tset) || (a isa Core.SlotNumber && a.id in slots) ||
        (a isa Core.Argument && a.n in slots)
    here(what) = join([chain; what], " → ")
    returns = false
    changed = true
    while changed
        changed = false
        for (i, st0) in enumerate(code)
            st, lhs = Meta.isexpr(st0, :(=)) ? (st0.args[2], st0.args[1]) : (st0, nothing)
            out = false
            if st isa Core.ReturnNode
                isdefined(st, :val) && tainted(st.val) && (returns = true)
                continue
            elseif st isa Core.SSAValue || st isa Core.SlotNumber || st isa Core.Argument
                out = tainted(st)
            elseif st isa Core.PiNode
                out = isdefined(st, :val) && tainted(st.val)
            elseif st isa Core.PhiNode
                out = any(k -> isassigned(st.values, k) && tainted(st.values[k]), eachindex(st.values))
            elseif Meta.isexpr(st, :new)
                out = any(tainted, @view st.args[2:end])
            elseif Meta.isexpr(st, :foreigncall)
                out = false                               # handed to C, which is where it came from
            elseif Meta.isexpr(st, :call) || Meta.isexpr(st, :invoke)
                callee, args = _call_callee_and_args(ci, st)
                hit = Int[k for k in eachindex(args) if tainted(args[k])]
                if !isempty(hit)
                    if isnothing(callee)
                        changed |= _note!(uncertain, here("a dynamic call handed foreign data"))
                        out = true
                    elseif callee in _TRUST_BOUNDARIES
                        out = false
                    elseif callee isa Type || any(c -> c === callee, _FOREIGN_CARRY)
                        out = true
                    elseif any(c -> c === callee, _FOREIGN_INERT)
                        out = false
                    elseif callee isa Function && !_sw_is_base(parentmodule(callee)) &&
                            Base.moduleroot(parentmodule(callee)) !== StrictMode
                        if depth >= _FOREIGN_DEPTH
                            changed |= _note!(uncertain, here("`$(nameof(callee))` (deeper than $_FOREIGN_DEPTH calls, not read)"))
                            out = true
                        else
                            csig = Tuple{Core.Typeof(callee), Any[_unopt_arg_type(ci, a) for a in args]...}
                            c, u, r = _foreign_reads(csig, Tuple(hit), [chain; string(nameof(callee))], depth + 1, memo)
                            for s in c; changed |= _note!(certain, s); end
                            for s in u; changed |= _note!(uncertain, s); end
                            out = r
                        end
                    else
                        changed |= _note!(certain, here("`$(nameof(callee))` reads foreign memory"))
                        out = false
                    end
                end
            end
            if out
                if !isnothing(lhs) && lhs isa Core.SlotNumber
                    lhs.id in slots || (push!(slots, lhs.id); changed = true)
                end
                i in tset || (push!(tset, i); changed = true)
            end
        end
    end
    r = (certain, uncertain, returns)
    memo[key] = r
    return r
end

const _FOREIGN_DEPTH = 8
_note!(v::Vector{String}, s::String) = (s in v) ? false : (push!(v, s); true)

# The foreign-pointer half of `:trusted` for one signature: `(certain, uncertain)`, both empty when
# no position is declared.
function _foreign_sites(@nospecialize(f), @nospecialize(types::Tuple), positions)
    isempty(positions) && return (String[], String[])
    for k in positions
        k <= length(types) || throw(ArgumentError(
            "`foreign` names argument $k, but the call has $(length(types)) argument(s)"
        ))
    end
    c, u, _ = _foreign_reads(Tuple{Core.Typeof(f), types...}, Tuple(positions), String[string(_callable_name(f))], 0, Dict{Any, Any}())
    return (c, u)
end

_assert_trusted_foreign(target, @nospecialize(f), @nospecialize(types::Tuple), foreign) =
    _assert_trusted(target, f, types; foreign = Tuple(Int(k) for k in foreign))

"""
    @assert_trusted f(args...)

Fail if `f`'s own body reads the payload of an [`Untrusted`](@ref) value and `f` is not registered
as a trust boundary. Passing a wrapped value along is always fine; only reading it is restricted.

The read is any call to `getfield`, `getproperty`, or [`unsafe_trust`](@ref) on an argument
that inference types as `<:Untrusted`. Registering `f` with [`trust_boundary!`](@ref) permits all of
them in that one method.

This is a structural lint in the same family as [`@assert_noboxing`](@ref) — it reads unoptimized
typed IR, with no execution, backend, or timing — and it **gates**, because it observes a call on a
type inference has already fixed rather than guessing at a cost. Its limits are all missed
violations, never false alarms: a payload that infers as `Any` is invisible, only compiled
specializations are swept, and nothing verifies that a registered boundary really validates or
copies what it returns.

Each argument is evaluated once; the macro evaluates to the call's value; disabled builds expand to
the bare call.

A C entry point keeps `Ptr` in its signature, so its foreign arguments are named by position with
`foreign = (k, …)`, or once for every check and sweep with [`trust_foreign!`](@ref). A value derived
from one — pointer arithmetic, a conversion, an `unsafe_wrap`ped array, a struct holding it — is
foreign too, and is followed into the package's own callees. Reading foreign memory (`unsafe_load`,
`unsafe_string`, indexing a wrapped array, any Base function given it) outside a registered trust
boundary throws. Handing it to C, comparing it, or asking a wrapped array's length is not a read. A
dynamic call or a callee too deep to read warns rather than throws.

```julia
@assert_trusted parse_header(u)         # ok: registered with trust_boundary!
@assert_trusted peek_length(u)          # throws: reads the payload without validating it
```
```julia
Base.@ccallable c_sum(p::Ptr{Float64}, n::Cint)::Float64 = …
@assert_trusted c_sum(p, n) foreign = (1,)
```
"""
macro assert_trusted(args...)
    pos, opts = _macro_call(args, (:types, :foreign))
    isempty(pos) && throw(ArgumentError("@assert_trusted needs a call expression"))
    call = pos[1]
    checked = if haskey(opts, :foreign)
        _guarantee_expr(call, _assert_trusted_foreign, esc(opts[:foreign]); types = get(opts, :types, nothing))
    else
        _guarantee_expr(call, _assert_trusted; types = get(opts, :types, nothing))
    end
    return _gate(checked, esc(call))
end
