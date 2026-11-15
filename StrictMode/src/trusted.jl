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

# Two kinds of foreign value. An ADDRESS is the foreign pointer, or something holding it: an integer
# made from it, a `Ref`, a struct. MEMORY is an array wrapped around it (`unsafe_wrap`). A read of the
# foreign memory is what the check reports, and the rule is the safe one: a call is cleared only when it
# is known not to read. A package method, and a Base method not on the lists below, is read like any
# body down to the primitive loads (`pointerref`, `memoryrefget`), so a read hidden in a closure handed
# to `sum`, an iterator, a broadcast or a task is found. A body that cannot be read — no single method,
# a dynamic call, past the depth or the body budget — is reported as uncertain, never cleared.
const _FK_PTR = Int8(1)
# Memory the scan only ASSUMES is foreign — the result of a call it could not read. A read through it is
# reported as uncertain, since the assumption, not the code, made it foreign.
const _FK_AMEM = Int8(2)
const _FK_MEM = Int8(3)

# Base functions that only carry an address on: the result is an address too.
const _FOREIGN_ADDR_OPS = (
    +, -, *, %, rem, div, ÷, mod, &, |, xor, <<, >>, >>>, ==, !=, <, <=, >, >=, isequal, isless,
    iszero, isone, UInt, Int, UInt64, Int64, UInt32, Int32, UInt8, convert, reinterpret, oftype, identity,
    Base.unsafe_convert, Base.cconvert, Base.bitcast, string, repr, hash, print, println, show,
    Ref, getindex, unsafe_store!, unsafe_read,
)
# Base functions that read the memory behind an address.
const _FOREIGN_ADDR_READS = (
    unsafe_load, unsafe_string, unsafe_pointer_to_objref, Base.unsafe_copyto!, unsafe_write,
    Base.unsafe_swap!, Base.unsafe_modify!, Base.unsafe_replace!, Base.memcmp,
)
const _FOREIGN_READ_INTRINSICS = (:pointerref, :atomic_pointerref, :atomic_pointerswap,
    :atomic_pointermodify, :atomic_pointerreplace, :memoryrefget, :arrayref, :memoryrefswap!,
    :memoryrefmodify!, :memoryrefreplace!)
# Base functions that ask a foreign array about its shape, or write to it, without reading it.
const _FOREIGN_MEM_META = (
    length, size, axes, eachindex, firstindex, lastindex, isempty, ndims, eltype, sizeof, strides, stride,
    LinearIndices, CartesianIndices, keys, checkbounds, similar, setindex!, fill!,
)
# Base functions that give another handle on the same foreign memory, or its address.
const _FOREIGN_MEM_VIEWS = (view, reshape, vec, reinterpret)
const _FOREIGN_MEM_ADDR = (pointer, Base.unsafe_convert, Base.cconvert)
# Builtins that only read or rearrange their arguments: the result has their kind.
const _FOREIGN_PURE_BUILTINS = (:getfield, :tuple, :typeassert, :ifelse, :svec, :memoryrefnew, :memoryref,
    :fieldtype, :apply_type, :compilerbarrier, :donotdelete, :getglobal, :nfields, :sizeof, :typeof)
const _FOREIGN_STORE_BUILTINS = (:setfield!, :memoryrefset!, :swapfield!, :modifyfield!, :replacefield!,
    :setfieldonce!, :memoryrefsetonce!, :arrayset)

const _FOREIGN_DEPTH = 32
const _FOREIGN_BUDGET = 1000
_note!(v::Vector{String}, s::String) = (s in v) ? false : (push!(v, s); true)

# The most foreign value a body that was not read can return: an address for a number or a pointer,
# which can still hold one, and memory for anything else.
function _assumed_kind(@nospecialize(sig))
    rt = try
        last(only(_code_typed_by_type(sig; optimize = false)))
    catch
        Any
    end
    return (rt isa Type && isbitstype(rt) && (rt <: Number || rt <: Ptr)) ? _FK_PTR : _FK_AMEM
end

# The method a call resolves to, or `nothing` when it is not exactly one.
function _foreign_method(@nospecialize(sig))
    ms = try
        Base._methods_by_ftype(sig, -1, Base.get_world_counter())
    catch
        nothing
    end
    (ms isa Vector && length(ms) == 1) || return nothing
    return ms[1].method
end

# The function a signature calls, when its type has a single instance.
_sig_function(@nospecialize(sig)) = (fT = sig.parameters[1]; fT isa DataType && isdefined(fT, :instance) ? fT.instance : nothing)

# `(certain, uncertain, returned_kind, stores)` for the body `sig` names, with `kinds` the foreign kind
# of each argument position (0 is the callable itself). `stores` maps an argument position to the kind of
# foreign value the body stored into it, so a caller's container is marked by a write in a callee.
function _foreign_reads(@nospecialize(sig), kinds::Tuple, chain::Vector{String}, depth::Int, st::Dict{Symbol, Any})
    memo = st[:memo]
    key = (sig, kinds)
    hit = get(memo, key, nothing)
    if hit === :pending
        # A recursive call to a body still being read: assume it returns the most foreign value its
        # return type can hold (an address for a number or a pointer, memory otherwise) and stores
        # nothing new. Its own reading covers the same body, so a read there is still found; a result
        # resting on this is not saved until it is settled.
        push!(st[:assumed], key)
        return (String[], String[], _assumed_kind(sig), Dict{Int, Int8}())
    end
    isnothing(hit) || return hit
    st[:budget] -= 1
    st[:budget] < 0 && return (String[], [join([chain; "past the body budget ($_FOREIGN_BUDGET bodies)"], " → ")], _assumed_kind(sig), Dict{Int, Int8}())
    outer = st[:assumed]
    st[:assumed] = Set{Any}()
    memo[key] = :pending
    r = _foreign_body(sig, kinds, chain, depth, st)
    used = delete!(st[:assumed], key)
    (isempty(used) || !isempty(r[1])) ? (memo[key] = r) : delete!(memo, key)
    st[:assumed] = union(outer, used)
    return r
end

function _foreign_body(@nospecialize(sig), kinds::Tuple, chain::Vector{String}, depth::Int, st::Dict{Symbol, Any})
    certain = String[]
    uncertain = String[]
    stores = Dict{Int, Int8}()
    here(what) = join([chain; what], " → ")
    cts = try
        _code_typed_by_type(sig; optimize = false)
    catch
        Any[]
    end
    if length(cts) != 1
        push!(uncertain, here("no single typed body for $(sig)"))
        return (certain, uncertain, _FK_AMEM, stores)
    end
    ci = first(cts[1])
    code = ci.code
    nslots = length(ci.slotnames)
    m = _foreign_method(sig)
    nargs = isnothing(m) ? nslots : Int(m.nargs)
    isva = !isnothing(m) && m.isva
    argslot(k) = (s = k + 1; isva && s > nargs ? nargs : s)
    slotk = Dict{Int, Int8}()
    for (k, kd) in kinds
        s = argslot(k)
        1 <= s <= nslots && (slotk[s] = max(get(slotk, s, Int8(0)), kd))
    end
    ssak = Dict{Int, Int8}()
    kind(@nospecialize(a)) = a isa Core.SSAValue ? get(ssak, a.id, Int8(0)) :
        (a isa Core.SlotNumber || a isa Core.Argument) ? get(slotk, a isa Core.SlotNumber ? a.id : a.n, Int8(0)) : Int8(0)
    changed = true
    # A container a foreign value was stored into becomes foreign itself. Walking back from a field or
    # element reference reaches the object written; an argument slot is reported to the caller.
    # The object a C argument was converted from.
    function croot(@nospecialize(a))
        for _ in 1:8
            a isa Core.SSAValue || return a
            s = code[a.id]
            Meta.isexpr(s, :(=)) && (s = s.args[2])
            if s isa Core.SSAValue || s isa Core.SlotNumber
                a = s
                continue
            end
            callee, args = _call_callee_and_args(ci, s)
            ((callee === Base.cconvert || callee === Base.unsafe_convert) && length(args) >= 2) || return a
            a = args[2]
        end
        return a
    end
    # A container a foreign value was stored into becomes foreign, and so does everything that may be the
    # same object: a variable assigned from it, the object a field or element reference was taken from,
    # each value a phi merges, and the arguments of a call whose result may alias them. An argument slot
    # is reported to the caller.
    function mark!(@nospecialize(c), kd::Int8, seen::Set{Any} = Set{Any}())
        c in seen && return
        push!(seen, c)
        if c isa Core.SlotNumber || c isa Core.Argument
            s = c isa Core.SlotNumber ? c.id : c.n
            get(slotk, s, Int8(0)) < kd && (slotk[s] = kd; changed = true)
            2 <= s <= nargs && (get(stores, s - 1, Int8(0)) < kd) && (stores[s - 1] = kd; changed = true)
            for st2 in code
                if Meta.isexpr(st2, :(=)) && st2.args[1] isa Core.SlotNumber && st2.args[1].id == s
                    r = st2.args[2]
                    (r isa Core.SSAValue || r isa Core.SlotNumber || r isa Core.Argument) && mark!(r, kd, seen)
                end
            end
        elseif c isa Core.SSAValue
            get(ssak, c.id, Int8(0)) < kd && (ssak[c.id] = kd; changed = true)
            s = code[c.id]
            Meta.isexpr(s, :(=)) && (s = s.args[2])
            if s isa Core.SSAValue || s isa Core.SlotNumber || s isa Core.Argument
                mark!(s, kd, seen)
            elseif s isa Core.PiNode
                mark!(s.val, kd, seen)
            elseif s isa Core.PhiNode
                for k in eachindex(s.values)
                    isassigned(s.values, k) && mark!(s.values[k], kd, seen)
                end
            elseif s isa GlobalRef
                _note!(uncertain, here("foreign data stored into the global `$(s.name)`")) && (changed = true)
            else
                callee, args = _call_callee_and_args(ci, s)
                if (callee === Base.cconvert || callee === Base.unsafe_convert) && length(args) >= 2
                    mark!(args[2], kd, seen)
                elseif callee === Core.memoryrefnew || callee === Core.getfield || callee === Base.getproperty
                    isempty(args) || mark!(args[1], kd, seen)
                else
                    for a in args
                        (a isa Core.SSAValue || a isa Core.SlotNumber || a isa Core.Argument) || continue
                        isbitstype(Core.Compiler.widenconst(_unopt_arg_type(ci, a))) && continue
                        mark!(a, kd, seen)
                    end
                end
            end
        elseif c isa GlobalRef
            _note!(uncertain, here("foreign data stored into the global `$(c.name)`")) && (changed = true)
        end
        return
    end

    returns = Int8(0)
    while changed
        changed = false
        for (i, st0) in enumerate(code)
            s, lhs = Meta.isexpr(st0, :(=)) ? (st0.args[2], st0.args[1]) : (st0, nothing)
            out = Int8(0)
            if s isa Core.ReturnNode
                isdefined(s, :val) && (returns = max(returns, kind(s.val)))
                continue
            elseif s isa Core.SSAValue || s isa Core.SlotNumber || s isa Core.Argument
                out = kind(s)
            elseif s isa Core.PiNode
                out = isdefined(s, :val) ? kind(s.val) : Int8(0)
            elseif s isa Core.PhiNode
                out = maximum(k -> isassigned(s.values, k) ? kind(s.values[k]) : Int8(0), eachindex(s.values); init = Int8(0))
            elseif Meta.isexpr(s, :new) || Meta.isexpr(s, :splatnew)
                out = maximum(kind, @view(s.args[2:end]); init = Int8(0))
            elseif Meta.isexpr(s, :foreigncall)
                # Handed back to C is not a read, except to Julia's own runtime, which reads it. What C
                # returns from foreign data is foreign, and so is any buffer it was handed beside it,
                # since C may copy the foreign data into it (`memcpy`).
                fn = string(_fcall_name(s))
                fk = maximum(kind, s.args; init = Int8(0))
                if fk > 0
                    # Julia's own runtime functions that build a string from a pointer read it. Any other
                    # runtime function handed foreign data might, so it is uncertain.
                    if fn in ("jl_pchar_to_string", "jl_cstr_to_string")
                        changed |= _note!(certain, here("`$fn` (Julia runtime) reads foreign memory"))
                    elseif startswith(fn, "jl_")
                        changed |= _note!(uncertain, here("`$fn` (Julia runtime) is handed foreign data"))
                    end
                    # A buffer handed to C beside it may receive foreign data (`memcpy`): assumed foreign
                    # memory. Only a buffer — an object that holds memory — not an address or an integer.
                    for a in s.args
                        r = croot(a)
                        (r isa Core.SSAValue || r isa Core.SlotNumber) && kind(r) == 0 &&
                            !isbitstype(Core.Compiler.widenconst(_unopt_arg_type(ci, r))) && mark!(r, _FK_AMEM)
                    end
                    out = _FK_PTR
                end
            elseif Meta.isexpr(s, :call) || Meta.isexpr(s, :invoke)
                out, c, u, sto = _foreign_call(ci, s, kind, here, chain, depth, st)
                for x in c; changed |= _note!(certain, x); end
                for x in u; changed |= _note!(uncertain, x); end
                for (a, kd) in sto
                    mark!(a, kd)
                end
            end
            if out > 0
                if lhs isa Core.SlotNumber
                    get(slotk, lhs.id, Int8(0)) < out && (slotk[lhs.id] = out; changed = true)
                end
                get(ssak, i, Int8(0)) < out && (ssak[i] = out; changed = true)
            end
        end
    end
    return (certain, uncertain, returns, stores)
end

# One call statement: `(result_kind, certain, uncertain, stores)`, `stores` naming each argument
# expression the call stored a foreign value into, with its kind.
function _foreign_call(ci, s::Expr, kind, here, chain, depth::Int, st::Dict{Symbol, Any})
    none = Pair{Any, Int8}[]
    isinv = s.head === :invoke
    fx = isinv ? s.args[2] : s.args[1]
    args = Vector{Any}(isinv ? s.args[3:end] : s.args[2:end])
    callee = _unopt_callee(ci, fx)
    selfk = kind(fx)
    ks = Int8[kind(a) for a in args]
    (selfk == 0 && all(iszero, ks)) && return (Int8(0), String[], String[], none)
    mk = max(selfk, maximum(ks; init = Int8(0)))
    if callee isa Core.Builtin || callee isa Core.IntrinsicFunction
        nm = nameof(callee)
        if nm in _FOREIGN_READ_INTRINSICS
            mk == _FK_AMEM && return (Int8(0), String[], [here("`$nm` may read foreign memory (assumed foreign)")], none)
            return (Int8(0), [here("`$nm` reads foreign memory")], String[], none)
        end
        if nm in _FOREIGN_STORE_BUILTINS
            # The value stored is every argument after the container; the container takes its kind.
            vk = length(ks) >= 2 ? maximum(@view ks[2:end]) : Int8(0)
            return (Int8(0), String[], String[], vk > 0 ? Pair{Any, Int8}[args[1] => vk] : none)
        end
        # Comparing, testing a type, or throwing (an error message that names the address) is not a read.
        (nm === :(===) || nm === :isa || nm === :isdefined || nm === :throw) && return (Int8(0), String[], String[], none)
        (callee isa Core.IntrinsicFunction || nm in _FOREIGN_PURE_BUILTINS) && return (mk, String[], String[], none)
        return (_FK_AMEM, String[], [here("the builtin `$nm` is handed foreign data")], none)
    end
    callee in _TRUST_BOUNDARIES && return (Int8(0), String[], String[], none)
    argT = Any[_unopt_arg_type(ci, a) for a in args]
    csig = Tuple{isnothing(callee) ? _unopt_arg_type(ci, fx) : Core.Typeof(callee), argT...}
    fobj = isnothing(callee) ? _sig_function(csig) : callee
    nm = string(_callable_name(isnothing(fobj) ? csig.parameters[1] : fobj))
    m = _foreign_method(csig)
    isnothing(m) && return (_FK_AMEM, String[], [here("$nm (no single method for its argument types) is handed foreign data")], none)
    # A keyword call into a listed Base function is judged as that function.
    lf = fobj
    if fobj === Core.kwcall && length(args) >= 2
        lf = _unopt_callee(ci, args[2])
        kind(args[1]) == 0 || (lf = nothing)              # a foreign value passed by keyword: read the body
    end
    lks = fobj === Core.kwcall ? ks[3:end] : ks
    largs = fobj === Core.kwcall ? args[3:end] : args
    memk = max(selfk, maximum(lks; init = Int8(0)))
    lmem = memk >= _FK_AMEM
    # The lists hold for Base's own methods on Base's own values. An argument of a package type (or an
    # abstract one) can route a listed function into package code — `string` into a `show` overload — so
    # then the body is read instead.
    plain = !_carries_user_type(Tuple{(fobj === Core.kwcall ? argT[3:end] : argT)...})
    if _sw_is_base(m.module) && !isnothing(lf)
        if lf === Base.unsafe_copyto! || lf === copyto! || lf === Base.Broadcast.materialize!
            # A copy reads its source and writes its destination: foreign data only in the destination
            # is a write into foreign memory, which is not a read.
            all(iszero, @view lks[2:end]) && return (Int8(0), String[], String[], none)
        end
        if any(f -> f === lf, _FOREIGN_ADDR_READS)
            # A read through an address made from an assumed value is itself assumed.
            all(k -> k == 0 || k == _FK_AMEM, lks) && selfk in (0, _FK_AMEM) &&
                return (Int8(0), String[], [here("`$nm` may read foreign memory (assumed foreign)")], none)
            return (Int8(0), [here("`$nm` reads foreign memory")], String[], none)
        end
        lf === unsafe_wrap && return (_FK_MEM, String[], String[], none)
        # A `Ref` or a tuple holding the foreign array, and an element taken back out of a tuple, carry
        # it without reading it.
        lf === Ref && return (memk, String[], String[], none)
        (lf === getindex && !isempty(argT) && argT[1] isa Type && argT[1] <: Tuple) && return (memk, String[], String[], none)
        if (lf === setindex! || lf === fill!) && !isempty(lks)
            # A write INTO foreign memory is not a read. Foreign data written into another container —
            # a copy out of foreign memory, or the foreign array itself stored there — makes that
            # container foreign.
            vk = length(lks) >= 2 ? maximum(@view lks[2:end]) : Int8(0)
            vk == 0 && return (Int8(0), String[], String[], none)
            vk >= _FK_AMEM && return (Int8(0), String[], String[], Pair{Any, Int8}[largs[1] => vk])
        end
        if lmem && plain
            any(f -> f === lf, _FOREIGN_MEM_ADDR) && return (memk == _FK_MEM ? _FK_PTR : _FK_AMEM, String[], String[], none)
            any(f -> f === lf, _FOREIGN_MEM_VIEWS) && return (memk, String[], String[], none)
            any(f -> f === lf, _FOREIGN_MEM_META) && return (Int8(0), String[], String[], none)
            # Any other Base function handed the foreign array itself reads its elements.
            memk == _FK_AMEM && return (_FK_AMEM, String[], [here("`$nm` may read foreign memory (assumed foreign)")], none)
            return (Int8(0), [here("`$nm` reads foreign memory")], String[], none)
        elseif !lmem && plain
            any(f -> f === lf, _FOREIGN_ADDR_OPS) && return (_FK_PTR, String[], String[], none)
            lf isa Type && lf <: Ptr && return (_FK_PTR, String[], String[], none)
        end
    end
    # Anything else is read: its own body decides.
    depth >= _FOREIGN_DEPTH && return (_FK_AMEM, String[], [here("`$nm` (deeper than $_FOREIGN_DEPTH calls, not read)")], none)
    kinds = Tuple(p for p in sort!([(0 => selfk); [k => ks[k] for k in eachindex(ks)]]; by = first) if last(p) > 0)
    c, u, r, sto = _foreign_reads(csig, kinds, [chain; nm], depth + 1, st)
    stored = Pair{Any, Int8}[(k == 0 ? fx : args[k]) => kd for (k, kd) in sto if (k == 0 || k <= length(args))]
    return (r, c, u, stored)
end

# The foreign-pointer half of `:trusted` for one signature: `(certain, uncertain)`, both empty when
# no position is declared.
function _foreign_sites(@nospecialize(f), @nospecialize(types::Tuple), positions)
    isempty(positions) && return (String[], String[])
    for k in positions
        k <= length(types) || throw(ArgumentError(
            "`foreign` names argument $k, but the call has $(length(types)) argument(s)"
        ))
    end
    # A declared position holding an array is foreign memory already; anything else is an address.
    kinds = Tuple(sort!([k => (types[k] <: AbstractArray ? _FK_MEM : _FK_PTR) for k in positions]; by = first))
    st = Dict{Symbol, Any}(:memo => Dict{Any, Any}(), :assumed => Set{Any}(), :budget => _FOREIGN_BUDGET)
    c, u, _, _ = _foreign_reads(Tuple{Core.Typeof(f), types...}, kinds, String[string(_callable_name(f))], 0, st)
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
