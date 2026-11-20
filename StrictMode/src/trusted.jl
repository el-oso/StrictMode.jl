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
instead of quietly succeeding, and `u.x` throws. The one deliberate way out is
[`unsafe_trust`](@ref).

Generic methods that accept any value still reach the payload: `reinterpret(UInt32, u)` copies the
bytes of an `isbits` payload out, and `show`/`string` print it. Those reads happen inside Base, so
neither dispatch nor [`@assert_trusted`](@ref) refuses them.

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
    _is_trust_boundary(f) && return (Symbol[], Symbol[])
    cts = try
        _code_typed(f, types; optimize = false)
    catch
        return nothing
    end
    isempty(cts) && return nothing
    ci = first(cts)[1]
    certain = Symbol[]
    erased = Symbol[]
    # A value the body also reads ANOTHER field of is not an `Untrusted`, which has one. That is
    # what a `for` loop does with what `iterate` returned: element at 1, state at 2. Without it a
    # loop over a loosely typed collection reads as a possible payload read.
    other = _other_field_reads(ci)
    overridden = _untrusted_getproperty_overridden()
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
            continue
        end
        # The escape hatch handed to another call — `map(unsafe_trust, us)`, `unsafe_trust.(us)`,
        # `u |> unsafe_trust` — reads a payload wherever it is applied: its one method takes an
        # `Untrusted`. Comparing a value with it applies it to nothing.
        if !(callee in (===, !==, ==, !=, isequal)) && any(a -> _unopt_callee(ci, a) === unsafe_trust, args)
            push!(certain, nameof(unsafe_trust))
        end
        (callee in _DEREF_FUNCS && !isempty(args)) || continue
        T = _unopt_arg_type(ci, args[1])
        T isa Type || continue
        if T <: Untrusted
            push!(certain, nameof(callee))
            # StrictMode's two-argument `getproperty` raises on an `Untrusted` whatever the name, so on
            # a value whose type is not known `p.x` reads no payload: it is a field of something else,
            # or an error. That holds only while that method is the one an `Untrusted` reaches. The
            # three-argument form, `getproperty(p, :x, order)`, is Base's, and reads the field.
        elseif typeintersect(T, Untrusted) !== Union{} && _reads_untrusted_field(callee, args) &&
                (callee !== Base.getproperty || length(args) != 2 || overridden) &&
                !_same_value_has_another_field(ci, other, i, args[1]) &&
                !_iteration_result(ci, args[1])
            push!(erased, nameof(callee))
        end
    end
    return (certain, erased)
end

# Whether an operand is what `iterate` or `indexed_iterate` returned: a tuple of an element and
# a state, never an `Untrusted`. Destructuring reads only field 1 of the last one, and inference
# types it `Any` once enough packages have added methods to `indexed_iterate`.
function _iteration_result(ci, @nospecialize(a))
    a isa Core.SSAValue || return false
    callee, _ = _call_callee_and_args(ci, ci.code[a.id])
    return callee === Base.indexed_iterate || callee === Base.iterate
end

# Whether some `Untrusted` reaches a `getproperty` method other than StrictMode's own: a package
# that gave its wrapped type a method returning the payload. Read from the method table as it is
# now, so the answer changes when such a method is defined or deleted.
function _untrusted_getproperty_overridden()
    ms = Base._methods_by_ftype(Tuple{typeof(getproperty), Untrusted, Symbol}, -1, Base.get_world_counter())
    ms isa Vector || return true
    return any(match -> Base.moduleroot(match.method.module) !== @__MODULE__, ms)
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
# `Untrusted` only after the payload read ran, so nothing in between may hand the payload on.
function _same_value_has_another_field(ci, other, i::Int, @nospecialize(operand))
    isempty(other) && return false
    targets = _jump_targets(ci)
    for (j, a) in other
        a == operand || continue
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

function _trusted_finding(@nospecialize(f), @nospecialize(types::Tuple), md, fn, sg; tier::Symbol = :report)
    sites = _untrusted_deref_sites(f, types)
    isnothing(sites) &&
        return _unevaluated(md, fn, sg, :trusted, "no typed IR for this signature"; tier)
    certain, erased = sites
    m = try
        which(f, types)
    catch
        nothing
    end
    return _mkfinding(
        md, fn, sg, :trusted, !isempty(certain) || !isempty(erased),
        _trusted_reason(certain, erased),
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

"""
    @assert_trusted f(args...)

Fail if `f`'s own body reads the payload of an [`Untrusted`](@ref) value and `f` is not registered
as a trust boundary. Passing a wrapped value along is always fine; only reading it is restricted.

The read is any call to `getfield`, `getproperty`, or [`unsafe_trust`](@ref) on an argument
that inference types as `<:Untrusted`, directly or through `invoke`, and `unsafe_trust` handed to
another call as a value (`map(unsafe_trust, us)`, `unsafe_trust.(us)`, `u |> unsafe_trust`). Registering `f` with [`trust_boundary!`](@ref) permits all of
them in that one method. A function with keywords keeps its code in a body function of its own; the
positional and `Core.kwcall` methods are judged by that body, and a registered boundary's body is
the boundary.

This is a structural lint in the same family as [`@assert_noboxing`](@ref) — it reads unoptimized
typed IR, with no execution, backend, or timing — and it **gates**, because it observes a call on a
type inference has already fixed rather than guessing at a cost. A value inference could not type is handled by what the
call can do: `getfield` and `unsafe_trust` on it are reported as reads that cannot be ruled out,
and warn; `p.x` on it is not reported, since `getproperty` on an `Untrusted` raises whatever the
name. `getproperty(p, :x, order)` with a memory order is Base's, which reads the field, so it is
reported like `getfield`. That changes when a package defines its own `getproperty` for an `Untrusted` of its type:
from then on `p.x` on an untyped value is reported like the other two. Its other limits are missed violations: only compiled specializations are swept, a read inside a generic Base method that accepts any value (`reinterpret(UInt32, u)`, `show`) is not seen, and nothing verifies that a registered boundary really validates or
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
