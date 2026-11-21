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

The wrapped value is meant to be passed along or given to a **trust boundary**: a function that
validates it and returns a plain value, registered with [`trust_boundary!`](@ref). Methods written
for `T` do not match `Untrusted{T}`, so an accidental use of that kind raises a `MethodError`
instead of quietly succeeding, and `u.x` and `reinterpret(T, u)` throw. So do the calls that copy
the bits of an array or a `Ref` of them: `reinterpret(T, [u])`, `reinterpret(reshape, T, [u])`,
`write(io, [u])`, `write(io, Ref(u))` and `unsafe_write(io, Ref(u), n)`; [`@assert_trusted`](@ref)
reports them as well. `Serialization.serialize` copies the payload too and does not throw. The one
deliberate way out is [`unsafe_trust`](@ref).

`show`, `print`, `string`, `repr` and `dump` print the type and `<redacted>` in place of the
payload, so a log line cannot leak it. `==`, `isequal` and `hash` raise, as `u.x` does, since
comparing or hashing reads the payload; so do the same calls on a container holding an `Untrusted`
(`[u] == [v]`), and an `Untrusted` cannot be a `Dict` or `Set` key. `===` is a builtin and cannot be
overridden: it, `objectid` and `IdDict` compare or hash the bits, so for an `isbits` payload
`Untrusted(1) === Untrusted(1)` is `true`.

Wrapping is free: `Untrusted{T}` has the same layout as `T` and allocates nothing. Wrapping twice
returns the same value, so an edge that wraps defensively costs nothing.

[`@assert_trusted`](@ref) fails on any function outside a boundary that reads the payload itself.

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

_untrusted_read_error(tried::String) = error(
    "`Untrusted` data has no readable fields (tried `$tried`). Validate it in a function " *
        "registered with `trust_boundary!`, which reads the payload with `unsafe_trust`."
)

Base.getproperty(::Untrusted, name::Symbol) = _untrusted_read_error(".$name")

# Base's generic `reinterpret(T, x)` copies the bits of any `isbits` value, so without this method it
# would hand out an `isbits` payload. Base's other `reinterpret` methods take an array or a float.
Base.reinterpret(::Type, ::Untrusted) = _untrusted_read_error("reinterpret")

# An array or a `Ref` of `Untrusted` values holds the payloads' bits inline, and these calls copy
# those bits out, so they raise as well. `Serialization.serialize` copies them too and is not
# covered: it is one generic method among many that walk a value's fields.
Base.reinterpret(::Type, ::AbstractArray{<:Untrusted}) = _untrusted_read_error("reinterpret")
Base.reinterpret(::typeof(reshape), ::Type, ::AbstractArray{<:Untrusted}) =
    _untrusted_read_error("reinterpret")
# Base's `write(::IO, ::StridedArray)` is more specific than an `AbstractArray` method, so the
# strided form needs its own.
Base.write(::IO, ::Union{Ref{<:Untrusted}, AbstractArray{<:Untrusted}}) = _untrusted_read_error("write")
Base.write(::IO, ::StridedArray{<:Untrusted}) = _untrusted_read_error("write")
Base.unsafe_write(::IO, ::Ref{<:Untrusted}, ::Integer) = _untrusted_read_error("unsafe_write")

# Comparing and hashing read the payload — `hash` of an `isbits` payload depends on its value — so
# they raise as a field read does. A container compares and hashes its elements with these, so
# `[u] == [v]` and `Dict(u => 1)` raise too. `===` is a builtin and still compares the bits.
Base.:(==)(::Untrusted, ::Untrusted) = _untrusted_read_error("==")
Base.isequal(::Untrusted, ::Untrusted) = _untrusted_read_error("isequal")
Base.hash(::Untrusted, ::UInt) = _untrusted_read_error("hash")

# Printing is how a payload reaches a log, so the type is shown and the payload is not. `dump`
# recurses through this four-argument method, so a payload nested in another value is hidden too.
Base.show(io::IO, u::Untrusted) = print(io, typeof(u), "(<redacted>)")
Base.dump(io::IOContext, u::Untrusted, ::Int, _) = show(io, u)

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
const _LOCAL_TRUST = :__strict_trust_boundaries__

# Every boundary in scope: this session's, and each loaded package's own. A boundary that takes
# keywords keeps its code in a body function of its own, `#f#N`, which is the boundary too.
function _is_trust_boundary(@nospecialize(f))
    f in _TRUST_BOUNDARIES && return true
    bs = _registrations(_TRUST_BOUNDARIES, _LOCAL_TRUST)
    any(g -> g === f, bs) && return true
    (f isa Function && startswith(String(nameof(f)), "#")) || return false
    return any(g -> any(m -> _keyword_body(m) === f, methods(g)), bs)
end

# The body function a keyword method forwards to, or `nothing` for a method without keywords.
# `Base.bodyfunction` returns the last function a method calls whatever it is, so its answer counts
# only when it carries the keyword-body name, `#f#N`, of this method's function.
function _keyword_body(m::Method)
    b = try
        Base.bodyfunction(m)
    catch
        nothing
    end
    b isa Function || return nothing
    mt = match(r"^#(.+)#\d+$", String(nameof(b)))
    return (!isnothing(mt) && mt.captures[1] == String(m.name)) ? b : nothing
end

"""
    trust_boundary!(f) -> f

Register `f` as a validating crossing: the one place [`@assert_trusted`](@ref) permits a read of an
[`Untrusted`](@ref) payload.

`f` is expected to validate what it reads, and to **copy** anything it hands back — the caller
still holds the original buffer and can write to it afterwards, which is why the kernel's
`copy_from_user` copies rather than aliasing. Neither property is checked; registering `f` asserts
both. When `f` takes keywords, the body function its keyword methods forward to (`#f#N`) is
the boundary too.

A registration made at a package's top level, while the package precompiles, is written into that
package's cache, so it is in force again in every process that loads it. Only the package being
precompiled is written, and `mod` names it. It defaults to the module that owns `f`, so
registering a function another package owns needs `mod = @__MODULE__` and raises without it:
the registration would hold for that precompile and be gone afterwards. A raise registers
nothing, in that precompile either. A call made from an
`__init__` runs again at every load, so it registers for the session and stores nothing. So does a
call made by the owning package's own code while another package precompiles, such as a
registration on first use that a dependent's precompile workload triggers. In a
session the registration lasts for the session.

Clears the findings cache, since a registration changes `:trusted` results.
"""
function trust_boundary!(@nospecialize(f); mod::Module = _owner_module(f))
    # Stored first: a registration that cannot be kept raises, and must leave the session unchanged.
    _keep_registration!(f, mod, _LOCAL_TRUST, "trust_boundary!($(_func_name(f)))")
    push!(_TRUST_BOUNDARIES, f)
    # A `:trusted` verdict depends on this set, and the findings cache does not key on it.
    clear_cache!()
    return f
end

# The calls that read the payload. `Base.getfield === Core.getfield`, so one entry covers both
# spellings. `getproperty` is here even though the override above already throws on it: reporting
# it at check time is more use than a runtime error in whatever session first hits that branch.
const _DEREF_FUNCS = (Core.getfield, Base.getproperty, unsafe_trust)

# The calls that copy out the bits of an `isbits` value they are given, inside an array or a `Ref`
# as well as bare.
const _BYTE_COPIERS = (reinterpret, write, unsafe_write)

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
# not be obtained, which a caller must not read as "none". `held` names, as "write of T", each call
# that copies out the bits of a value whose type T can hold an `Untrusted`.
function _untrusted_deref_sites(@nospecialize(f), @nospecialize(types::Tuple))
    _is_trust_boundary(f) && return (Symbol[], Symbol[], String[])
    cts = try
        _code_typed(f, types; optimize = false)
    catch
        return nothing
    end
    isempty(cts) && return nothing
    ci = first(cts)[1]
    certain = Symbol[]
    erased = Symbol[]
    held = String[]
    # A value the body also reads ANOTHER field of is not an `Untrusted`, which has one. That is
    # what a `for` loop does with what `iterate` returned: element at 1, state at 2. Without it a
    # loop over a loosely typed collection reads as a possible payload read.
    other = _other_field_reads(ci)
    overridden = (_untrusted_getproperty_overridden(2), _untrusted_getproperty_overridden(3))
    # A keyword function's positional and `Core.kwcall` methods only forward to its body function,
    # where the code the caller wrote is; that body is read as part of `f`'s own.
    m = ci.parent isa Core.MethodInstance ? ci.parent.def : nothing
    body = m isa Method ? _keyword_body(m) : nothing
    for (i, st) in pairs(ci.code)
        callee, args = _call_callee_and_args(ci, st)
        # `invoke(f, T, args...)` calls `f` on `args`, whichever method `T` selects.
        if callee === Core.invoke && length(args) >= 2
            callee, args = _unopt_callee(ci, args[1]), args[3:end]
        end
        if !isnothing(body) && callee === body
            sub = _untrusted_deref_sites(body, Tuple(_unopt_arg_type(ci, a) for a in args))
            isnothing(sub) && return nothing
            append!(certain, sub[1])
            append!(erased, sub[2])
            append!(held, sub[3])
            continue
        end
        # Comparing a value with a payload-reading function, or testing membership in a collection
        # of them, applies it to nothing.
        if !(callee in (===, !==, ==, !=, isequal, in, ∉))
            _handed_on_reads!(certain, erased, ci, st, callee, args, overridden)
        end
        # A call that copies out the bits of what it is given reads a payload it can reach:
        # `reinterpret(T, u)` (which raises at run time, like `u.x`), `reinterpret(T, [u])`,
        # `write(io, Ref(u))`, `write(io, [u])`. The first operand is the target type or the stream.
        if callee in _BYTE_COPIERS && length(args) >= 2
            Ts = [_unopt_arg_type(ci, a) for a in args[2:end]]
            rs = map(_untrusted_reach, Ts)
            if :certain in rs
                push!(certain, nameof(callee))
            elseif :maybe in rs
                push!(held, "$(nameof(callee)) of $(Ts[findfirst(==(:maybe), rs)])")
            end
            continue
        end
        (callee in _DEREF_FUNCS && !isempty(args)) || continue
        T = _unopt_arg_type(ci, args[1])
        T isa Type || continue
        if T <: Untrusted
            push!(certain, nameof(callee))
            # StrictMode's two-argument `getproperty` raises on an `Untrusted` whatever the name, so on
            # a value whose type is not known `p.x` reads no payload: it is a field of something else,
            # or an error. The three-argument form, `getproperty(p, :x, order)`, is Base's, and reads
            # the field it names. A method a package adds for an `Untrusted` returns what it chooses
            # whatever the name, so once one exists every erased read of that arity may be a payload read.
        elseif typeintersect(T, Untrusted) !== Union{} &&
                _erased_read(callee, args, overridden) &&
                !_same_value_has_another_field(ci, other, i, args[1]) &&
                !_iteration_result(ci, args[1])
            push!(erased, nameof(callee))
        end
    end
    return (certain, erased, held)
end

# A payload-reading function handed to a call as a value, bare or held by a callable such as
# `Base.Fix2(getfield, :x)`, in any operand including the callee: `getfield.([u], :x)`,
# `getfield((u, :x)...)`, `map(getfield, us, names)`, `Base.Fix2(getfield, :x)(u)`. The escape
# hatch reads a payload wherever it is applied, since its one method takes an `Untrusted`. The
# other two read one only when an `Untrusted` reaches them, so they count by what the call's
# operands can hold: a site when one holds an `Untrusted`, an erased site when a type cannot rule
# one out, and nothing when every type rules it out. When the function itself is an operand and the
# field it is applied with is a constant (`getfield.(xs, :a)`, `getproperty.(xs, :x)`), an erased
# site is judged by the field rules a direct call is judged by.
function _handed_on_reads!(
        certain, erased, ci, @nospecialize(st), @nospecialize(callee), args,
        overridden::Tuple{Bool, Bool}
    )
    op = _call_operand(st)
    isnothing(op) && return nothing
    # A direct call of a payload-reading function is judged as a call, where this is called.
    ops = callee in _DEREF_FUNCS ? collect(Any, args) : Any[op; collect(Any, args)]
    Ts = Any[_unopt_arg_type(ci, a) for a in ops]
    carried = [F for F in _DEREF_FUNCS if any(T -> _carries_function(T, F), Ts)]
    isempty(carried) && return nothing
    if unsafe_trust in carried
        push!(certain, nameof(unsafe_trust))
        return nothing
    end
    nm = nameof(first(carried))
    # A callable this body built from the function itself, such as the `Broadcasted` that
    # `getfield.(xs, :a)` makes and then materializes, was judged with the operands it was built
    # from; only the operands it meets here are new.
    reach = :none
    for (a, T) in zip(ops, Ts)
        _built_from(ci, a, carried) || (reach = _max_reach(reach, _untrusted_reach(T)))
    end
    reach === :certain && push!(certain, nm)
    reach === :maybe && !_handed_on_cleared(ci, ops, first(carried), overridden) && push!(erased, nm)
    return nothing
end

# Whether `a` is the value of a call in this body that had one of the functions `Fs` itself as an
# operand.
function _built_from(ci, @nospecialize(a), Fs)
    a isa Core.SSAValue || return false
    _, args = _call_callee_and_args(ci, ci.code[a.id])
    return any(b -> any(F -> _unopt_arg_type(ci, b) === typeof(F), Fs), args)
end

# Whether `F`, an operand among `ops`, is applied to the operands after it with a constant field
# in a way that cannot read the payload. A callable holding `F`, such as `Base.Fix2(getfield, :x)`,
# carries the field where the operands do not show it, and is never cleared.
function _handed_on_cleared(ci, ops, @nospecialize(F), overridden::Tuple{Bool, Bool})
    k = findfirst(a -> _unopt_arg_type(ci, a) === typeof(F), ops)
    isnothing(k) && return false
    applied = ops[(k + 1):end]
    length(applied) >= 2 || return false
    fld = applied[2]
    (fld isa QuoteNode || fld isa Symbol || fld isa Int) || return false
    return !_erased_read(F, applied, overridden)
end

# The callee operand of a call statement as written, or `nothing` for a statement that is no call.
function _call_operand(@nospecialize(st))
    Meta.isexpr(st, :(=)) && (st = st.args[2])
    Meta.isexpr(st, :call) && return st.args[1]
    (Meta.isexpr(st, :invoke) || Meta.isexpr(st, :invoke_modify)) && return st.args[2]
    return nothing
end

# Whether a value of type `T` is the function `F`, or a callable holding it in a type parameter.
function _carries_function(@nospecialize(T), @nospecialize(F), depth::Int = 0)
    T isa DataType || return false
    T === typeof(F) && return true
    depth < 4 || return false
    return any(p -> _carries_function(p, F, depth + 1), T.parameters)
end

# What a value of type `T` can hold of an `Untrusted`, where a call applying a function to it can
# reach: `:certain` when it is one, or a tuple, array or `Ref` whose elements are; `:maybe` when its
# type does not rule one out (an `Any`, an abstract type) or a field of it can hold one;
# `:none` when it cannot. A field holding an `Untrusted` is `:maybe`, not `:certain`, since a
# function applied to the value itself reads that field and not the payload. A type value
# (`Type{…}`) holds none.
function _untrusted_reach(@nospecialize(T), depth::Int = 0)
    T isa Type || return :maybe
    T === Union{} && return :none
    T isa Union && return _max_reach(_untrusted_reach(T.a, depth), _untrusted_reach(T.b, depth))
    T <: Type && return :none
    T <: Untrusted && return :certain
    typeintersect(T, Untrusted) === Union{} || return :maybe
    (isconcretetype(T) && fieldcount(T) == 0) && return :none
    # A field of a field, eight deep, is not followed further, and is not ruled out.
    depth < 8 || return :maybe
    if T isa DataType && T <: Tuple
        r = :none
        for p in T.parameters
            r = _max_reach(r, _untrusted_reach(Base.unwrapva(p), depth + 1))
        end
        return r
    end
    (T <: AbstractArray || T <: Ref) && return _untrusted_reach(eltype(T), depth + 1)
    # An abstract type that is no container holds an `Untrusted` only where a type parameter
    # names one: `Real`, `AbstractString` and `IO` hold none, `AbstractDict{K, Untrusted{V}}` may.
    if T isa DataType && isabstracttype(T) && !(T <: Tuple)
        for p in T.parameters
            p isa Type && _untrusted_reach(p, depth + 1) === :none && continue
            p isa Type || p isa TypeVar || continue
            return :maybe
        end
        return :none
    end
    (T isa DataType && isconcretetype(T)) || return :maybe
    for F in fieldtypes(T)
        _untrusted_reach(F, depth + 1) === :none || return :maybe
    end
    return :none
end

_max_reach(a::Symbol, b::Symbol) = (a === :certain || b === :certain) ? :certain :
    (a === :maybe || b === :maybe) ? :maybe : :none

# Whether an erased call to a payload-reading function reads the `Untrusted` field. `overridden`
# holds `_untrusted_getproperty_overridden` for two and three arguments.
function _erased_read(@nospecialize(callee), args, overridden::Tuple{Bool, Bool})
    if callee === Base.getproperty && length(args) in (2, 3)
        overridden[length(args) - 1] && return true
        length(args) == 2 && return false
    end
    return _reads_untrusted_field(callee, args)
end

# Whether an operand is what `iterate` or `indexed_iterate` returned: a tuple of an element and
# a state, never an `Untrusted`. Destructuring reads only field 1 of the last one, and inference
# types it `Any` once enough packages have added methods to `indexed_iterate`.
function _iteration_result(ci, @nospecialize(a))
    a isa Core.SSAValue || return false
    callee, _ = _call_callee_and_args(ci, ci.code[a.id])
    return callee === Base.indexed_iterate || callee === Base.iterate
end

# Whether some `Untrusted` reaches a `getproperty` method of `nargs` arguments (2, or 3 with a
# memory order) other than StrictMode's own and Base's generic one: a package that gave its wrapped
# type a method returning the payload. Read from the method table as it is now, so the answer
# changes when such a method is defined or deleted.
function _untrusted_getproperty_overridden(nargs::Int = 2)
    sig = nargs == 2 ? Tuple{typeof(getproperty), Untrusted, Symbol} :
        Tuple{typeof(getproperty), Untrusted, Symbol, Symbol}
    ms = Base._methods_by_ftype(sig, -1, Base.get_world_counter())
    ms isa Vector || return true
    return any(match -> !(Base.moduleroot(match.method.module) in (@__MODULE__, Base)), ms)
end

# Each `getfield` of a field `Untrusted` does not have, as statement index => operand.
function _other_field_reads(ci)
    out = Pair{Int, Any}[]
    for (i, st) in pairs(ci.code)
        callee, args = _call_callee_and_args(ci, st)
        (callee === Core.getfield && length(args) >= 2) || continue
        fld = args[2]
        fld isa QuoteNode && (fld = fld.value)
        ((fld isa Int && fld != 1) || (fld isa Symbol && fld !== _UNTRUSTED_FIELD)) && push!(out, i => args[1])
    end
    return out
end

# Whether the operand read at statement `i` is the same VALUE as one a `getfield` reads another
# field of. The same operand is the same value only along one path: with a branch between the two
# statements they can sit on different arms of a type test, where the operand is an `Untrusted`
# on one arm and something else on the other, and a variable assigned between them holds a
# different value at each. A jump INTO the span is a path that skipped the first read, so the
# span must hold no jump target either. When the other field is read SECOND, it raises on an
# `Untrusted` only after the payload read ran, so nothing in between may hand the payload on, and
# the payload read must not sit in a `try` whose catch can finish without raising: that catch
# swallows the raise, and a local the payload was stored in is still read after it.
function _same_value_has_another_field(ci, other, i::Int, @nospecialize(operand))
    isempty(other) && return false
    targets = _jump_targets(ci)
    for (j, a) in other
        a == operand || continue
        i < j && _in_try(ci, i) && continue
        lo, hi = minmax(i, j)
        straight = !any(t -> lo < t <= hi, targets)
        for k in lo:(hi - 1)
            straight || break
            st = ci.code[k]
            if st isa Core.GotoNode || st isa Core.GotoIfNot || st isa Core.ReturnNode ||
                    st isa Core.EnterNode || (st isa Expr && st.head === :(=) && st.args[1] == operand) ||
                    (k > i && _may_hand_on(ci, st))
                straight = false
            end
        end
        straight && return true
    end
    return false
end

# Whether a statement can pass a value somewhere: a call other than `getfield`, which only reads,
# a foreign call, or a store to a global.
function _may_hand_on(ci, @nospecialize(st))
    st isa Expr || return false
    if st.head === :(=)
        st.args[1] isa GlobalRef && return true
        st = st.args[2]
        st isa Expr || return false
    end
    st.head === :foreigncall && return true
    st.head in (:call, :invoke, :invoke_modify) || return false
    callee, _ = _call_callee_and_args(ci, st)
    return callee !== Core.getfield
end

# Whether statement `i` lies between an `enter` and the catch block it jumps to, and that block can
# finish without raising. Lowering places a `try` body after its `enter` and before its catch; an
# `enter` with no catch (`catch_dest == 0`, the scope-only form) catches nothing. A `finally`
# lowers to a catch block that ends in `rethrow()`, so it swallows nothing.
_in_try(ci, i::Int) = any(1:(i - 1)) do k
    st = ci.code[k]
    st isa Core.EnterNode && st.catch_dest > 0 && k < i < st.catch_dest && _may_return(ci, st.catch_dest)
end

# Whether some path from statement `s` reaches a `return` rather than a `throw` or `rethrow`. A
# `try` inside the path may catch what it raises, so it counts as a return.
function _may_return(ci, s::Int)
    seen = falses(length(ci.code))
    todo = [s]
    while !isempty(todo)
        k = pop!(todo)
        (1 <= k <= length(ci.code) && !seen[k]) || continue
        seen[k] = true
        st = ci.code[k]
        if st isa Core.ReturnNode
            isdefined(st, :val) && return true
        elseif st isa Core.EnterNode
            return true
        elseif st isa Core.GotoNode
            push!(todo, st.label)
        elseif st isa Core.GotoIfNot
            push!(todo, k + 1, st.dest)
        elseif !(_call_callee_and_args(ci, st)[1] in (rethrow, throw))
            push!(todo, k + 1)
        end
    end
    return false
end

# The statements a jump can land on.
function _jump_targets(ci)
    out = Int[]
    for st in ci.code
        st isa Core.GotoNode && push!(out, st.label)
        st isa Core.GotoIfNot && push!(out, st.dest)
        st isa Core.EnterNode && push!(out, st.catch_dest)
    end
    return out
end

function _trusted_reason(certain::Vector{Symbol}, erased::Vector{Symbol}, held::Vector{String})
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
    isempty(held) || push!(
        parts,
        "may read an `Untrusted` payload — $(length(held)) call(s) copy out the bits of a value " *
            "whose type can hold one ($(join(sort(unique(held)), ", "))), so the read cannot be " *
            "ruled out: give the value a type that holds no `Untrusted`, or move the call into a " *
            "boundary registered with `trust_boundary!`"
    )
    return join(parts, "; ")
end

function _trusted_finding(@nospecialize(f), @nospecialize(types::Tuple), md, fn, sg; tier::Symbol = :report)
    sites = _untrusted_deref_sites(f, types)
    isnothing(sites) &&
        return _unevaluated(md, fn, sg, :trusted, "no typed IR for this signature"; tier)
    certain, erased, held = sites
    m = try
        _which(f, types)
    catch
        nothing
    end
    return _mkfinding(
        md, fn, sg, :trusted, !isempty(certain) || !isempty(erased) || !isempty(held),
        _trusted_reason(certain, erased, held),
        isnothing(m) ? "" : string(m.file), isnothing(m) ? 0 : Int(m.line);
        tier
    )
end

function _assert_trusted(target, @nospecialize(f), @nospecialize(types::Tuple))
    sites = _untrusted_deref_sites(f, types)
    if isnothing(sites)
        _fail(:trusted, target, "no typed IR for this signature, so the guarantee is unchecked")
        return nothing
    end
    certain, erased, held = sites
    if !isempty(certain)
        _fail(
            :trusted, target, _trusted_reason(certain, erased, held) * ": move the read into a " *
                "validating function that returns a plain value, and register it with " *
                "`trust_boundary!`."
        )
    elseif !isempty(erased) || !isempty(held)
        # An erased object type is inference failing to answer, not the scan observing a read, so
        # this reports where a certain site throws — the same split `_guarantee_gates` draws between
        # a check that OBSERVES and one that cannot. A `getfield` on an `Any` is ordinary code, and
        # aborting a build over one would make the guarantee unusable.
        _fail(:trusted, target, _trusted_reason(certain, erased, held) * "."; gates = false)
    end
    return nothing
end

"""
    @assert_trusted f(args...)

Fail if `f`'s own body reads the payload of an [`Untrusted`](@ref) value and `f` is not registered
as a trust boundary. Passing a wrapped value along is always fine; only reading it is restricted.

The read is any call to `getfield`, `getproperty` or [`unsafe_trust`](@ref) on an argument that
inference types as `<:Untrusted`, directly or through `invoke`, and any call to `reinterpret`,
`write` or `unsafe_write` handed an `Untrusted` or a tuple, array or `Ref` of them past its first
operand: `reinterpret(T, u)`, `reinterpret(T, [u])`, `write(io, Ref(u))`, `write(io, [u])` copy
out the bits of an `isbits` payload. Handed an operand whose type cannot rule one out (`Any`,
`Vector{Any}`), those three are reads that cannot be ruled out, and the reason names that type. An
abstract type that is no tuple, array or `Ref` and has no type parameter that can hold an
`Untrusted` (`Real`, `Integer`, `AbstractString`, `IO`) rules one out, so a struct subtype of one
of those with an `Untrusted` field, passed under the abstract type, is not seen. It is also any of
`getfield`, `getproperty` and `unsafe_trust` handed to another call as a value, bare or held by a
callable: `map(unsafe_trust, us)`, `unsafe_trust.(us)`, `u |> unsafe_trust`, `getfield.([u], :x)`,
`getfield((u, :x)...)`, `map(getfield, us, names)`, `Base.Fix2(getfield, :x)(u)`. `unsafe_trust`
handed on is a read wherever it goes, since its one method takes an `Untrusted`. `getfield` and
`getproperty` handed on are a read when an operand of that call is an `Untrusted` or a tuple,
array or `Ref` of them, and a read that cannot be ruled out when an operand's type does not rule
one out (an `Any`, an abstract type, a struct with such a field). Handed on with a constant field,
as in `getfield.(xs, :a)`, they are judged by the same field rules as a direct call, so
`getfield.(xs, :a)` and `getproperty.(xs, :x)` on untyped values are not reported while
`getfield.(xs, :x)` and `getfield.(xs, 1)` are; a callable holding the field, such as
`Base.Fix2(getproperty, :a)`, is still a read that cannot be ruled out. Registering `f` with
[`trust_boundary!`](@ref) permits all of them in that one method. A function with keywords keeps its code in a body function of its own; the
positional and `Core.kwcall` methods are judged by that body, and a registered boundary's body is
the boundary.

This is a structural lint in the same family as [`@assert_noboxing`](@ref) — it reads unoptimized
typed IR, with no execution, backend, or timing — and it **gates**, because it observes a call on a
type inference has already fixed rather than guessing at a cost. A value inference could not type is handled by what the
call can do: `getfield` and `unsafe_trust` on it are reported as reads that cannot be ruled out,
and warn; `p.x` on it is not reported, since `getproperty` on an `Untrusted` raises whatever the
name. `getproperty(p, :x, order)` with a memory order is Base's, which reads the field, so it is
reported like `getfield`. That changes when a package defines its own `getproperty` for an `Untrusted` of its type:
from then on `p.x`, `p.v` or a property of any name read from an untyped value is reported like
the other two, since that method returns what it chooses whatever the name. A method for the form
with a memory order does the same to `getproperty(p, name, order)` of any name. Its other limits are missed violations: only compiled specializations are swept, a read inside any other generic method that copies what it is given, such as
`Serialization.serialize`, is not seen, and nothing verifies that a registered boundary really validates or
copies what it returns.

Each argument is evaluated once; the macro evaluates to the call's value; disabled builds expand to
the bare call.

```julia
@assert_trusted parse_header(u)         # ok: registered with trust_boundary!
@assert_trusted peek_length(u)          # throws: reads the payload without validating it
```
"""
macro assert_trusted(args...)
    pos, opts = _macro_call("@assert_trusted", args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_trusted needs a call expression"))
    call = pos[1]
    checked = _guarantee_expr(call, _assert_trusted; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
end
