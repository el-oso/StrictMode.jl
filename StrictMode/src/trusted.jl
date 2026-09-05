# `:trusted` — data from outside the program carries that fact in its type, and only a registered
# boundary may read the payload. This is the Julia form of the Linux kernel's `__user` pointer
# annotation (`include/linux/compiler_types.h`): `Untrusted{T}` is the distinct type that
# `address_space(__user)` creates, the `getproperty` override is `noderef`, `unsafe_trust` is the
# `__force` cast, and the scan below is the checker that reports where the cast appears outside a
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

[`@assert_trusted`](@ref) reports any function outside a boundary that reads the payload.

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
check reports the call site.
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
function _untrusted_deref_sites(@nospecialize(f), @nospecialize(types::Tuple))
    f in _TRUST_BOUNDARIES && return Symbol[]
    cts = try
        Base.code_typed(f, types; optimize = false)
    catch
        return nothing
    end
    isempty(cts) && return nothing
    ci = first(cts)[1]
    sites = Symbol[]
    for st in ci.code
        callee, args = _call_callee_and_args(ci, st)
        (callee in _DEREF_FUNCS && !isempty(args)) || continue
        T = _unopt_arg_type(ci, args[1])
        T isa Type && T <: Untrusted && push!(sites, nameof(callee))
    end
    return sites
end

_trusted_reason(sites::Vector{Symbol}) =
    "reads an `Untrusted` payload outside a trust boundary " *
    "($(join(sort(unique(sites)), ", "))) — $(length(sites)) site(s)"

function _trusted_finding(@nospecialize(f), @nospecialize(types::Tuple), md, fn, sg)
    sites = _untrusted_deref_sites(f, types)
    isnothing(sites) &&
        return _unevaluated(md, fn, sg, :trusted, "no typed IR for this signature")
    m = try
        which(f, types)
    catch
        nothing
    end
    return _mkfinding(
        md, fn, sg, :trusted, !isempty(sites), _trusted_reason(sites),
        isnothing(m) ? "" : string(m.file), isnothing(m) ? 0 : Int(m.line)
    )
end

function _assert_trusted(target, @nospecialize(f), @nospecialize(types::Tuple))
    sites = _untrusted_deref_sites(f, types)
    if isnothing(sites)
        _fail(:trusted, target, "no typed IR for this signature, so the guarantee is unchecked")
    elseif !isempty(sites)
        _fail(
            :trusted, target, _trusted_reason(sites) * ": move the read into a validating " *
                "function that returns a plain value, and register it with `trust_boundary!`."
        )
    end
    return nothing
end

"""
    @assert_trusted f(args...)

Fail if `f`'s own body reads the payload of an [`Untrusted`](@ref) value and `f` is not registered
as a trust boundary. Passing a wrapped value along is always fine; only reading it is restricted.

The read is any call to `getfield`, `getproperty`, or [`unsafe_trust`](@ref) on an argument
inference types as `<:Untrusted`. Registering `f` with [`trust_boundary!`](@ref) permits all of
them in that one method.

This is a structural lint in the same family as [`@assert_noboxing`](@ref) — it reads unoptimized
typed IR, with no execution, backend, or timing — and it **gates**, because it observes a call on a
type inference has already fixed rather than guessing at a cost. Its limits are all missed
violations, never false alarms: a payload that infers as `Any` is invisible, only compiled
specializations are swept, and nothing verifies that a registered boundary really validates or
copies what it returns.

Each argument is evaluated once; the macro evaluates to the call's value; disabled builds expand to
the bare call.

```julia
@assert_trusted parse_header(u)         # ok: registered with trust_boundary!
@assert_trusted peek_length(u)          # throws: reads the payload without validating it
```
"""
macro assert_trusted(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_trusted needs a call expression"))
    call = pos[1]
    checked = _guarantee_expr(call, _assert_trusted; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
end
