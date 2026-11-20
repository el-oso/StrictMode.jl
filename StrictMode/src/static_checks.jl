# `@assert_noalloc` — report if a call allocates. A value-free scan of typed IR by default, or an
# empirical `@allocated` measurement on request. Dynamic dispatch / boxing surface here too, since
# both count as allocation.
#
# Both engines are heuristics, so both REPORT rather than gate (see `_guarantee_gates` in
# report.jl): typed IR still carries an allocation LLVM will later elide, and `@allocated` reads a
# `gc_num` counter that shows a per-call delta on SIMD/`GC.@preserve` code with nothing allocated.
# The proof is `StrictModeTest`'s `@test_noalloc`, which runs AllocCheck.

# Force specialization on the thunk type (`where {F}`): otherwise calling a Function-typed
# argument is a dynamic dispatch that itself allocates, producing a false positive in the
# empirical path.
@inline _allocated(thunk::F) where {F} = @allocated thunk()

# Resolve @assert_noalloc's (and @strict's/@kernel's) check strategy. `static_opt` is the parsed
# `static=` keyword value, or `nothing` if not given. `false` forces the empirical `@allocated`
# path; the default is the value-free `_alloc_signals` scan, which is a signature-level verdict
# rather than a measurement of one call's inputs.
_noalloc_mode(static_opt::Union{Nothing, Bool}) =
    isnothing(static_opt) ? :heuristic : static_opt ? :static : :empirical

# The macro form of `_barrier_note`: a call site whose only cause for `g` lies inside a registered
# allocation barrier says so, once per site and barrier, rather than passing as if it had been checked.
function _barrier_info(g::Symbol, target, barrier::Union{Nothing, Symbol})
    isnothing(barrier) && return nothing
    @info "StrictMode @assert_$g $target: reaches `$barrier`, a registered allocation barrier; its " *
        (g === :owned ? "dictionary lookup" : "boxing") * " is reported there, under " *
        ":$g." _id = Symbol(g, '|', target, '|', barrier) maxlog = 1
    return nothing
end

# A scan that read no body has no verdict to give, and saying nothing would read as a pass. True
# when it reported, so the caller stops there.
function _unread_fail(g::Symbol, target, sig; gates::Bool = _guarantee_gates(g))
    sig.unread || return false
    _fail(
        g, target,
        "no typed body could be read for this signature (no method matches, or its generator raised)";
        gates
    )
    return true
end

# The scan found nothing but did not read the whole call tree, so its silence is not a verdict.
function _truncated_fail(g::Symbol, target, sig; gates::Bool = _guarantee_gates(g))
    sig.truncated || return false
    _fail(
        g, target,
        "not established: the value-free scan found nothing, but did not read the whole call tree " *
            "below this call (a body it could not read, or more than $(_SCAN_BODY_BUDGET[]) bodies)";
        gates
    )
    return true
end

# The scan half on its own, with no thunk: the caller already has the value.
function _assert_noalloc_scan(target, @nospecialize(f), @nospecialize(types::Tuple))
    sig = _alloc_signals(f, types; mode = :alloc)
    _unread_fail(:noalloc, target, sig) && return nothing
    if sig.alloc || sig.boxing || !isnothing(sig.abscontainer)
        _fail(:noalloc, target, _alloc_message(f, types, sig, "allocates / boxes (value-free IR scan)"))
    elseif _truncated_fail(:noalloc, target, sig)
    else
        _barrier_info(:noalloc, target, sig.barrier_box)
    end
    return nothing
end

function _assert_noalloc(target, @nospecialize(f), @nospecialize(types::Tuple), thunk::F; mode::Symbol) where {F}
    mode === :static && throw(
        ArgumentError(
            "@assert_noalloc: `static = true` requested AllocCheck's static proof, which lives in " *
                "the companion `StrictModeTest` package. Add it to this environment and write " *
                "`@test_noalloc $target` — that macro IS the proof, and unlike this one it gates. " *
                "Drop `static = true` here to keep the value-free scan."
        )
    )
    val = thunk()                 # warm up / force compilation, and capture the call's value
    if mode === :heuristic
        sig = _alloc_signals(f, types; mode = :alloc)
        _unread_fail(:noalloc, target, sig) && return val
        if sig.alloc || sig.boxing || !isnothing(sig.abscontainer)
            _fail(:noalloc, target, _alloc_message(f, types, sig, "allocates / boxes (value-free IR scan)"))
        elseif _truncated_fail(:noalloc, target, sig)
        else
            _barrier_info(:noalloc, target, sig.barrier_box)
        end
        return val
    end
    n = _allocated(thunk)         # measure the steady-state call (gc_num delta)
    if n > 0
        _fail(
            :noalloc, target,
            "call allocated $n bytes at runtime (@allocated). NOTE: `@allocated` measures the gc_num " *
                "counter, which can report a per-call artifact with no real allocation on SIMD / " *
                "GC.@preserve-heavy code. If the call references a non-`const` global, the allocation " *
                "may be the binding (global access boxes), not the function — make it `const`/local."
        )
    end
    return val
end

"""
    @assert_noalloc f(args...)
    @assert_noalloc f(args...; kw...)
    @assert_noalloc static=false f(args...)
    @assert_noalloc f(args...) types=(T1, T2, …)

Report if the call `f(args...)` allocates.

**This reports; it does not gate.** Both of its engines are heuristics — typed IR still carries an
allocation LLVM will later elide, and `@allocated` reads a counter that shows a per-call delta on
SIMD code that allocates nothing — so a violation is a `@warn`, not a thrown
[`StrictViolation`](@ref). A check that guesses must not be able to abort a build. For the proof,
add `StrictModeTest` to the test environment and use `@test_noalloc`, which runs AllocCheck's
all-paths static analysis and does gate.

By default this is the same value-free IR scan [`findings`](@ref) uses
(`StrictMode._alloc_signals` — no execution beyond the one warmup call every path needs to produce
the return value). Pass `static = false` to force the empirical `@allocated`-after-warmup path
instead, which is value-dependent but sees what actually ran (useful when the scan can't reason
about a construct, or when a non-`const` global's binding boxing is the actual culprit).

Each argument is evaluated exactly once. With checks disabled this expands to the bare call, with
no overhead left behind.

**Keyword arguments** are supported: `f(x; k=v)` is analyzed at its real specialization (routed
through `Core.kwcall`). **`types = (…)`** pins the analyzed signature explicitly, mirroring
[`@assert_typestable`](@ref) — handy for type-argument functions where `typeof.(args)` would not
name the real call-site specialization.

```julia
@assert_noalloc sum(rand(100))           # ok
@assert_noalloc grows_a_vector(1000)     # warns, naming the allocation
@assert_noalloc fill!(buf, x; offset=0)  # ok: keyword call analyzed as-is
```
"""
macro assert_noalloc(args...)
    pos, opts = _macro_call("@assert_noalloc", args, (:static, :types))
    mode = _noalloc_mode(haskey(opts, :static) ? opts[:static]::Bool : nothing)
    isempty(pos) && throw(ArgumentError("@assert_noalloc needs a call expression"))
    call = pos[1]
    target = string(call)
    p = _call_parts(call; types = get(opts, :types, nothing))

    # The scan reads only the signature, so it runs once per (site, signature) and the call itself
    # supplies the value — `_assert_noalloc` is not used on this path, because it calls the thunk to
    # produce that value and would therefore run the call a second time on the cold branch, breaking
    # the evaluate-once guarantee every one of these macros makes.
    #
    # `static = false` is measurement, not a scan: it asks what THIS call did, so it stays per call
    # and keeps running through `_assert_noalloc`.
    checked = if mode === :heuristic
        quote
            $(p.binds...)
            local _val = $(p.litcall)
            $(_guarded_check(p, :($(_assert_noalloc_scan)($target, $(p.checkfn), $(p.types)))))
            _val
        end
    else
        quote
            $(p.binds...)
            $(_assert_noalloc)($target, $(p.checkfn), $(p.types), $(p.thunk); mode = $(QuoteNode(mode)))
        end
    end
    return _gate(checked, esc(call))
end

# --- @assert_noboxing: the boxing/dispatch subclass of allocations specifically ---

function _assert_noboxing(target, @nospecialize(f), @nospecialize(types::Tuple))
    sig = _alloc_signals(f, types; mode = :boxing)
    _unread_fail(:noboxing, target, sig) && return nothing
    if sig.boxing || !isnothing(sig.abscontainer)
        _fail(:noboxing, target, _box_msg("boxing / dynamic dispatch (value-free IR scan)", sig))
    elseif _truncated_fail(:noboxing, target, sig)
    else
        _barrier_info(:noboxing, target, sig.barrier_box)
    end
    return nothing
end

"""
    @assert_noboxing f(args...)

Report if the call boxes or dynamically dispatches — the *type-uncertainty* subclass of
allocations — while **allowing** legitimate typed heap allocations (a `Vector`, a `Memory`, …).

This is the relaxed sibling of [`@assert_noalloc`](@ref): use it for a hot path that may
allocate a buffer but must never box (the runtime-tuple-index trap, captured-variable `Core.Box`,
an isbits value stored into a slot of abstract type, or accidental dynamic dispatch). Like `@assert_noalloc` it reads typed IR and therefore **reports
rather than gates**; `StrictModeTest`'s `@test_noboxing` classifies AllocCheck's allocation
instances and does gate. Each argument is evaluated once; the macro evaluates to the call's value;
disabled builds expand to the bare call.

```julia
@assert_noboxing fill_buffer!(buf, xs)        # ok: allocates a buffer, but no boxing
@assert_noboxing sum_runtime_index(htuple)    # warns: runtime tuple index (boxing)
```
"""
macro assert_noboxing(args...)
    pos, opts = _macro_call("@assert_noboxing", args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_noboxing needs a call expression"))
    call = pos[1]
    checked = _guarantee_expr(call, _assert_noboxing; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
end

# --- @assert_owned: no runtime AbstractDict lookup on owned scratch (static-ownership lint) ---
# Value-free structural lint (same category as @assert_noboxing): scans optimized typed IR for a
# runtime `AbstractDict` accessor reached on the hot path, following non-inlined callees (the
# lookup usually lives in a workspace accessor, not the top function). No backend, no timing.

function _assert_owned(
        target, @nospecialize(f), @nospecialize(types::Tuple);
        depth::Int = _FAST_ALLOC_DEPTH[], gates::Bool = _guarantee_gates(:owned)
    )
    sig = _alloc_signals(f, types; depth = depth)
    _unread_fail(:owned, target, sig; gates) && return nothing
    # The ordinary walk stopped short: follow the package's own code to the end.
    deep = (!sig.dictlookup && sig.truncated) ? _owned_deep(_sigtype(f, types)) : :clean
    if sig.dictlookup || deep === :lookup
        _fail(
            :owned, target,
            "hot path resolves a runtime AbstractDict lookup (static-ownership violation): give " *
                "the type a const-dispatched accessor (one const owner per concrete type) instead of " *
                "a runtime keyed lookup. Where the buffer must be per task or per thread, a shared " *
                "const owner races and the lookup is the price of that state: exempt the accessor " *
                "with `@strict_exempt` from :owned, say why, and register it as an allocation " *
                "barrier so its callers point here.";
            gates = gates
        )
    elseif deep === :budget
        _fail(
            :owned, target,
            "not established: the package's own call graph below this call is larger than the walk " *
                "reads ($(_OWNED_DEEP_BUDGET) bodies), or holds a body it cannot read. Assert :owned on a smaller part of the call.";
            gates = false
        )
    else
        _barrier_info(:owned, target, sig.barrier_dict)
    end
    return nothing
end

"""
    @assert_owned f(args...)

Fail if the call reaches a **runtime `AbstractDict` lookup** on its hot path — the
*static-ownership* violation: an owned workspace/scratch accessor must resolve to a
const-dispatched, per-concrete-type accessor (a `Ref`/field owned by the type), never a runtime
keyed dictionary probe (`get`/`getindex`/`get!`/`setindex!`/`haskey`/`pop!` on a `<:AbstractDict`).

This is a purely *structural* lint in the same family as [`@assert_noboxing`](@ref): it reads the
optimized typed IR (no execution, no backend, no timing) and follows non-inlined `:invoke` callees,
because the dictionary probe typically lives in a workspace accessor a level or two down, not in the
top function. It catches the latency-shaped bug the value-based checks miss: a keyed lookup is
type-stable, non-allocating on the warm hit, and trim-tolerated, so it passes `@assert_typestable`,
`@assert_noalloc`, and `@assert_noboxing` — only a benchmark (or this lint) exposes it.

Each argument is evaluated once; the macro evaluates to the call's value; disabled builds expand to
the bare call. Pass `depth = n` to control how many non-inlined callee levels are walked; defaults
to `StrictMode._FAST_ALLOC_DEPTH[]` (2), the same session-wide override `@assert_noalloc` and the
batch API honor.

```julia
@assert_owned symm!(C, A, B)            # ok: every type has a const-dispatched scratch accessor
@assert_owned hemm!(C, A, B)            # throws: ComplexF64 falls through to a runtime IdDict get
```
"""
macro assert_owned(args...)
    pos, opts = _macro_call("@assert_owned", args, (:types, :depth))
    isempty(pos) && throw(ArgumentError("@assert_owned needs a call expression"))
    call = pos[1]
    target = string(call)
    # Unescaped (hygienic) reference when no depth= is given, so it resolves to this module's
    # `_FAST_ALLOC_DEPTH` and reads its *current* value at each call — not a value frozen at
    # macro-expansion time, matching `_alloc_signals`'s own `depth::Int = _FAST_ALLOC_DEPTH[]` default.
    depth_expr = haskey(opts, :depth) ? esc(opts[:depth]) : :(_FAST_ALLOC_DEPTH[])
    p = _call_parts(call; types = get(opts, :types, nothing))

    checked = quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_guarded_check(p, :($(_assert_owned)($target, $(p.checkfn), $(p.types); depth = $depth_expr))))
        _val
    end
    return _gate(checked, esc(call))
end

function _assert_noescape(
        target, @nospecialize(f), @nospecialize(types::Tuple);
        gates::Bool = _guarantee_gates(:noescape)
    )
    r = _escaping_scoped(Tuple{typeof(f), types...})
    if !isempty(r.escaped)
        _fail(
            :noescape, target,
            "a scoped value is not provably confined to this frame: " * join(r.escaped, ", ") *
                ". It is returned, stored to a global or a field, captured by a closure, or " *
                "handed to a function this analysis cannot see through — the escape state of an " *
                "unanalyzed callee is assumed, not computed, so these cannot be told apart. " *
                "Return a copy, keep the handle inside the scope that owns it, or inline the " *
                "callee that receives it.";
            gates = gates
        )
    elseif !isempty(r.undetermined)
        _fail(
            :noescape, target,
            "cannot decide whether a scoped value escapes: " * join(r.undetermined, ", ") *
                " arrives from a call that did not inline. The escape state of a call result is " *
                "assumed, not computed, so reporting it either way would be a guess. Mark the " *
                "function that produces the handle `@inline`, or assert this where the handle " *
                "is created.";
            gates = gates
        )
    end
    return nothing
end

"""
    @assert_noescape f(args...)
    @assert_noescape f(args...) types=(T1, T2, …)

Fail unless no value of a type registered with [`register_scoped!`](@ref) escapes the frame of
`f(args...)`.

For a handle whose validity is bounded by a scope — a borrow from an arena, a pointer into a slab,
a token for a held lock — escape is a use-after-free rather than a slow path. The compiler's own
escape analysis answers it; this is the way to ask.

```julia
register_scoped!(ArenaHandle)

@assert_noescape compute!(arena, A, b)     # passes: the handle stays inside
@assert_noescape leak(arena)               # fails: it is returned
```

Catches the value **leaving the frame**: returned, stored to a global or a field, or captured by a
closure. It does **not** catch a handle that stays in the frame and is used after its scope has
ended, which is not an escape — the analysis will correctly call that clean. Rejecting it needs a
syntactic check at macro-expansion time, where the end of the block is visible.

Nothing is registered by default, so this passes trivially until a type is declared scoped. Like
every `@assert_*` macro it expands to the bare call when checks are disabled.

It REPORTS rather than gating, and has no proving counterpart, so treat a failure as a lead to
check by hand. The reason is measured: a handle wrapped in a `view` reads as not-provably-confined
even when the view is never used, because the wrapper is scalar-replaced out of existence while the
handle it came from stays marked unconfined. A bare handle — created in the frame, used there, not
wrapped — is answered soundly in both directions.
"""
macro assert_noescape(args...)
    pos, opts = _macro_call("@assert_noescape", args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_noescape needs a call expression"))
    call = pos[1]
    target = string(call)
    p = _call_parts(call; types = get(opts, :types, nothing))
    checked = quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_guarded_check(p, :($(_assert_noescape)($target, $(p.checkfn), $(p.types)))))
        _val
    end
    return _gate(checked, esc(call))
end

# --- @assert_noalias: a written argument must not share memory with another argument ---

# A trailing `!` says a function mutates at least one argument, and by convention the first
# (`mul!(C, A, B)`, `copyto!(dest, src)`). That is the only default the name can justify, and it
# is not always right: `ldiv!(F, B)` writes its second argument, `axpy!(a, x, y)` its third, and
# `lmul!(a, B)`, `map!(f, dest, src)` and `rand!(rng, A)` write none of their first. So the default
# is checked before it is used: an argument 1 that holds no memory cannot be what is written, and
# the call is rejected until `mutates` names the position. A name without `!` carries no claim at
# all, so the caller must name the written positions: guessing would compare the wrong pair and
# find nothing, which reads identically to "no aliasing here".
#
# Resolved from the SOURCE name at expansion where the callee is written as a plain symbol, so the
# passing path builds nothing. A computed or qualified callee (`ws.kernel!`, `(f())`) is not a name
# at expansion, and falls back to `_runtime_mutated`.
_bang_positions(nargs::Int) = nargs ≥ 1 ? (1,) : ()

function _runtime_mutated(@nospecialize(f), nargs::Int)
    endswith(_func_name(f), "!") || return nothing
    return _bang_positions(nargs)
end

# Validated in place and returned unchanged: building a container here would allocate on every
# call of an asserted site, which is what makes a per-call check unaffordable (issue #29).
function _check_mutates(mutates, nargs::Int)
    applicable(iterate, mutates) || throw(
        ArgumentError("@assert_noalias: mutates must be a collection of argument positions, got $(typeof(mutates))")
    )
    isempty(mutates) && throw(
        ArgumentError(
            "@assert_noalias: mutates names no argument, so the check would compare no pair and " *
                "pass every call. Name the positions the call writes, or drop the assertion."
        )
    )
    for p in mutates
        p isa Integer || throw(
            ArgumentError("@assert_noalias: each mutates entry must be an argument position, got $(repr(p))")
        )
        1 ≤ p ≤ nargs || throw(
            ArgumentError("@assert_noalias: mutates = $p is out of range for a call with $nargs positional argument(s)")
        )
    end
    return mutates
end

const _NOALIAS_NO_BANG = "does not end in `!`, so which arguments it writes is not known. Name " *
    "them — `mutates = (1,)` — or drop the assertion. Defaulting to \"nothing is written\" would " *
    "compare no pair and pass every call."

# Whether a value can be written through at all. A plain number, a function, a type or a string
# holds no memory a kernel could write, so naming one as the written argument compares nothing.
# A plain-data value that carries a pointer does (an array type built on a `Ptr`), and so does a
# number that is not plain data (`BigInt`, `BigFloat`).
@inline _holds_memory(x) = isbits(x) ? _carries_pointer(typeof(x)) :
    !(x isa Union{Type, Module, Function, Symbol, AbstractString, Nothing, Missing})

# Whether a plain-data type has a `Ptr` in it. Decided from the type, so it folds away for the
# arguments of a call.
Base.@assume_effects :foldable function _carries_pointer(@nospecialize(T::Type), depth::Int = 0)
    T <: Ptr && return true
    (T isa DataType && depth < 4) || return false
    for F in fieldtypes(T)
        _carries_pointer(F, depth + 1) && return true
    end
    return false
end

# Base's own array types define `dataids`, the protocol `Base.mightalias` reads. An array type that
# does not is answered by the fallback, the object's own identity, which never matches the buffer
# the wrapper holds.
const _DeclaredArray = Union{Array, Memory, SubArray, Base.ReshapedArray, PermutedDimsArray, Base.ReinterpretArray, BitArray}
@inline function _declares_ids(x::AbstractArray)
    x isa _DeclaredArray && return true
    ids = Base.dataids(x)
    return !(ids isa Tuple{UInt} && ids[1] === UInt(objectid(x)))
end

const _ALIAS_FIELD_DEPTH = 3

# The address range `[lo, hi)` an array's elements lie in, or `nothing` when it is not known.
# A strided array answers from its pointer and strides. An array type built on a pointer answers
# from its one `Ptr{eltype}` field and its length; with no such field, or several, which pointer
# is the data is not known.
function _memory_region(@nospecialize(x::AbstractArray))
    isempty(x) && return nothing
    if x isa StridedArray && isbitstype(eltype(x))
        lo = hi = UInt(pointer(x))
        for (n, s) in zip(size(x), strides(x))
            span = (n - 1) * s * Base.elsize(x)
            span < 0 ? (lo -= UInt(-span)) : (hi += UInt(span))
        end
        return (lo, hi + UInt(Base.elsize(x)))
    end
    i = _data_pointer_field(typeof(x))
    i == 0 && return nothing
    p = getfield(x, i)::Ptr
    p == C_NULL && return nothing
    return (UInt(p), UInt(p) + UInt(length(x) * sizeof(eltype(x))))
end

# The index of the one field that is a `Ptr` to the array's element type, or 0.
function _data_pointer_field(@nospecialize(T::Type))
    (T isa DataType && T <: AbstractArray && isbitstype(eltype(T))) || return 0
    found = 0
    for (i, F) in pairs(fieldtypes(T))
        F === Ptr{eltype(T)} || continue
        found == 0 || return 0
        found = i
    end
    return found
end

# What `_collect_memory!` finds in an argument: the arrays that declare their ids, which are taken
# at their word; the address ranges of the arrays built on a pointer; and the raw pointers, which
# say where memory starts and not how far it reaches.
struct _Reached
    arrays::Vector{Any}
    regions::Vector{Tuple{UInt, UInt}}
    ptrs::Vector{UInt}
end
_Reached() = _Reached(Any[], Tuple{UInt, UInt}[], UInt[])
Base.isempty(r::_Reached) = isempty(r.arrays) && isempty(r.regions) && isempty(r.ptrs)

# Anything that is not one of those (a wrapper array with no `dataids` method, a workspace struct,
# a factorization) is read through its fields. In an array built on a pointer only the data
# pointer is memory the array covers: another pointer field is a handle, which two arrays can
# share without sharing an element.
function _collect_memory!(r::_Reached, @nospecialize(x), depth::Int)
    if x isa Ptr
        x == C_NULL || push!(r.ptrs, UInt(x))
        return nothing
    end
    _holds_memory(x) || return nothing
    data = 0
    if x isa AbstractArray
        if !isbits(x) && _declares_ids(x)
            push!(r.arrays, x)
            return nothing
        end
        data = _data_pointer_field(typeof(x))
        if data != 0
            region = _memory_region(x)
            isnothing(region) || push!(r.regions, region)
        end
    end
    depth <= 0 && return nothing
    for i in 1:nfields(x)
        isdefined(x, i) || continue
        v = getfield(x, i)
        (data != 0 && v isa Ptr) && continue
        _collect_memory!(r, v, depth - 1)
    end
    return nothing
end

_regions_meet(a::Tuple{UInt, UInt}, b::Tuple{UInt, UInt}) = a[1] < b[2] && b[1] < a[2]

# Whether an address range meets a declared array: by the array's own range where it has one, and
# otherwise by whether the range holds an address the array names as its data.
function _region_meets_array(region::Tuple{UInt, UInt}, @nospecialize(x::AbstractArray))
    other = _memory_region(x)
    isnothing(other) || return _regions_meet(region, other)
    return any(id -> region[1] <= id < region[2], Base.dataids(x))
end

# Whether a raw pointer points at memory the other argument reaches. How far the pointer's own
# memory extends is not known, so this is evidence of sharing and not a comparison of two ranges.
function _pointer_meets(p::UInt, r::_Reached)
    p in r.ptrs && return true
    any(g -> g[1] <= p < g[2], r.regions) && return true
    return any(r.arrays) do x
        g = _memory_region(x)
        isnothing(g) ? (p in Base.dataids(x)) : (g[1] <= p < g[2])
    end
end

# Whether the memory two arguments reach overlaps, by the evidence there is. Two arrays found
# inside them are asked of `Base.mightalias`, exactly as two plain arguments are, so disjoint views
# of one parent inside two wrappers do not overlap. An array built on a pointer is compared by the
# address range it covers. A raw pointer outside such an array has no known extent: one that
# points at memory the other argument reaches is `:undecided`.
@noinline function _deep_overlap(@nospecialize(a), @nospecialize(b))
    ra = _Reached()
    _collect_memory!(ra, a, _ALIAS_FIELD_DEPTH)
    isempty(ra) && return :none
    rb = _Reached()
    _collect_memory!(rb, b, _ALIAS_FIELD_DEPTH)
    found = any(x -> any(y -> Base.mightalias(x, y), rb.arrays), ra.arrays) ||
        any(g -> any(h -> _regions_meet(g, h), rb.regions), ra.regions) ||
        any(g -> any(y -> _region_meets_array(g, y), rb.arrays), ra.regions) ||
        any(g -> any(x -> _region_meets_array(g, x), ra.arrays), rb.regions)
    found && return (a isa AbstractArray && b isa AbstractArray) ? :arrays : :fields
    (any(p -> _pointer_meets(p, rb), ra.ptrs) || any(p -> _pointer_meets(p, ra), rb.ptrs)) &&
        return :undecided
    return :none
end

# How two arguments share memory: `:arrays` when both are arrays, `:fields` when the shared buffer
# sits in a field of an argument that is not an array, `:undecided` when the only evidence is a
# pointer of unknown extent, `:none` otherwise. Two arrays that declare their ids are answered by
# `Base.mightalias` alone, which knows disjoint views of one parent apart and allocates nothing.
# It answers `false` for any plain-data array, whatever it points at, so those are compared by
# address range.
@inline function _overlap(a, b)
    if a isa AbstractArray && b isa AbstractArray
        Base.mightalias(a, b) && return :arrays
        (!isbits(a) && !isbits(b) && _declares_ids(a) && _declares_ids(b)) && return :none
    end
    (_holds_memory(a) && _holds_memory(b)) || return :none
    return _deep_overlap(a, b)
end

@noinline function _noalias_unwritable(target, @nospecialize(f), @nospecialize(arg), p::Int, default::Bool)
    what = "argument $p is a `$(typeof(arg))`, which holds no memory to write"
    throw(
        ArgumentError(
            default ?
                "@assert_noalias $target: $what, so it is not what `$(_func_name(f))` writes, and " *
                "the `!` convention names no other argument. Name the written positions, for " *
                "example `mutates = ($(p + 1),)`." :
                "@assert_noalias $target: mutates = $p, but $what. Name the argument the call writes."
        )
    )
end

@noinline function _noalias_number_default(target, @nospecialize(f), @nospecialize(args::Tuple), p::Int)
    q = something(findfirst(x -> x isa AbstractArray, args))
    throw(
        ArgumentError(
            "@assert_noalias $target: argument $p is a `$(typeof(args[p]))`, a number, and the call " *
                "also takes an array, so the `!` convention does not say which of them " *
                "`$(_func_name(f))` writes. Name the written positions, for example " *
                "`mutates = ($q,)`."
        )
    )
end

function _assert_noalias(
        target, @nospecialize(f), @nospecialize(args::Tuple);
        mutates = nothing, default::Bool = isnothing(mutates), gates::Bool = _guarantee_gates(:noalias)
    )
    n = length(args)
    pos = isnothing(mutates) ? _runtime_mutated(f, n) : _check_mutates(mutates, n)
    isnothing(pos) &&
        throw(ArgumentError("@assert_noalias: `$(_func_name(f))` " * _NOALIAS_NO_BANG))
    # A position that cannot be written compares nothing, and passing would say the call was checked.
    for p in pos
        _holds_memory(args[p]) || _noalias_unwritable(target, f, args[p], Int(p), default)
        # A `BigFloat` holds memory, and as the scale factor of `scale!(a, v)` it is no more the
        # written argument than a `Float64` is. The name alone does not say which the call
        # writes, so the caller does.
        (default && args[p] isa Number && any(x -> x isa AbstractArray, args)) &&
            _noalias_number_default(target, f, args, Int(p))
    end
    # The scan returns on the first overlap and builds the message in a separate frame: a call that
    # satisfies the assertion must allocate nothing, or the assertion changes what it measures.
    for i in pos, j in 1:n
        i == j && continue
        _overlap(args[i], args[j]) === :none || return _noalias_fail(target, args, pos, n, gates)
    end
    return nothing
end

@noinline function _noalias_fail(target, @nospecialize(args::Tuple), pos, n::Int, gates::Bool)
    overlaps = String[]
    undecided = String[]
    arrays = false
    for i in pos, j in 1:n
        i == j && continue
        kind = _overlap(args[i], args[j])
        kind === :none && continue
        arrays |= kind === :arrays
        if kind === :undecided
            push!(undecided, "argument $i (written) and argument $j")
            continue
        end
        # The argument that is not an array is the one whose field holds the shared buffer.
        holder = args[j] isa AbstractArray ? i : j
        push!(
            overlaps, kind === :arrays ? "argument $i (written) and argument $j" :
                "argument $i (written) and argument $j (a buffer held in a field of argument " *
                "$holder, a `$(typeof(args[holder]))`)"
        )
    end
    # A pointer of unknown extent that points at the other argument's memory: reported, since
    # nothing compared says the two do not overlap, and never raised on.
    if isempty(overlaps)
        _fail(
            :noalias, target,
            "arguments may share memory: " * join(undecided, ", ") * ". A pointer held by one " *
                "points at memory the other reaches, and how far that pointer's memory extends " *
                "is not known, so the overlap could not be decided either way.";
            gates = false
        )
        return nothing
    end
    isempty(undecided) || append!(overlaps, undecided .* " (a pointer of unknown extent)")
    # Two arrays that overlap are what the kernel reads and writes. A buffer inside a struct
    # argument is shared memory the kernel may never read, so that overlap alone reports.
    _fail(
        :noalias, target,
        "arguments share memory: " * join(overlaps, ", ") * ". A function that writes one " *
            "argument while reading another assumes they are distinct; when they overlap, the " *
            "result depends on the order the elements happen to be touched, so the same call can " *
            "answer differently under another loop order, blocking, or Julia version. Pass a copy " *
            "of the input, write to a separate destination, or call an in-place form documented " *
            "to accept the overlap.";
        gates = gates && arrays
    )
    return nothing
end

"""
    @assert_noalias f!(args...)
    @assert_noalias mutates=(1, 2) f(args...)

Fail unless the arguments `f` writes share no memory with the arguments it reads.

A kernel that writes one argument while reading another is written on the assumption that the two
are distinct. When they overlap, the answer depends on the order the elements happen to be visited,
so the same call can give a different result under another loop order, another blocking, or another
Julia version. `LinearAlgebra.mul!` states this as a documented precondition; most hand-written
kernels carry it silently.

This is the one check here that reads **values** rather than a signature. Whether two arrays
overlap is a property of the arrays, not of their types, so there is nothing for the value-free
engine to answer and no entry in [`StrictMode.guarantee_names`](@ref) — it cannot be swept by
`audit` or declared on a `@strict_function`. `Base.mightalias` is the oracle: Julia's own predicate,
the one `Base.unalias` uses to decide whether to copy.

Which arguments are written comes from the name — a trailing `!` means argument 1 — and anything
else must say so with `mutates = (…)`. A call that gives neither, or an empty `mutates`, is
rejected rather than passed, since "nothing is written" would compare no pair and accept everything. So is a written position
that holds no memory: `axpy!(a, x, y)` takes a scalar first, so the `!` default names nothing a
kernel could write, and the call raises an `ArgumentError` asking for `mutates = (3,)`. The
convention is not checked beyond that: `ldiv!(F, B)` writes its second argument, and the default
still compares argument 1 against the rest, which for a two-argument call is the same pair.

An argument is compared by the memory it reaches. Two arrays are compared with `Base.mightalias`.
An array type that defines no `Base.dataids` method (a wrapper struct around a `Vector`) and an
argument that is not an array (a workspace struct, a factorization) are read through their fields,
three levels down, and the arrays found there are compared the same way, so disjoint views inside
two wrappers do not overlap. A raw pointer (an array type built on a `Ptr`, a `BigInt`) counts
only where it equals another pointer or the start of an array; an address inside another array
is undecided and is not reported. Arrays held as ELEMENTS, as in `[y, z]` or a `Dict`, are not
followed. An overlap between two arrays raises. An overlap with a buffer held in a field
of a non-array argument warns: the memory is shared, but nothing says the kernel reads that field.

```julia
A = rand(8, 8); C = similar(A)
@assert_noalias mul!(C, A, A)              # ok: A may alias itself, only C is written
@assert_noalias mul!(A, A, A)              # fails: the destination is also an input
@assert_noalias mul!(C, A, view(C, :, 1))  # fails: the view reads what C writes

@assert_noalias mutates=(1, 2) swap!(x, y) # neither the name nor one position is enough
```

A call on arrays that satisfies the assertion allocates nothing: the pair scan returns on the
first overlap and the message is built in another frame. Costs about 2 ns per pair. Reading a
struct argument through its fields allocates.

Overlap is checked for the call that runs, not for every call the method could receive, so this
narrows the property one site at a time rather than proving it once. Rust decides the same question
at compile time for every caller; Julia has no construct that can, which is why this is a run-time
assertion that compiles away rather than a static guarantee.

Like every `@assert_*` macro it expands to the bare call when checks are disabled, and the call's
value is returned. Keyword-argument calls are not supported, since `mutates` names positional
positions and a keyword has none.
"""
macro assert_noalias(args...)
    pos, opts = _macro_call("@assert_noalias", args, (:mutates,))
    isempty(pos) && throw(ArgumentError("@assert_noalias needs a call expression"))
    call = pos[1]
    fexpr, argexprs, kwexprs = _callinfo(call)
    isempty(kwexprs) || throw(
        ArgumentError(
            "@assert_noalias does not support keyword-argument calls; `mutates` names positional " *
                "argument positions, which a keyword has none of."
        )
    )
    target = string(call)
    nargs = length(argexprs)
    # A plain-symbol callee settles the written positions here, so nothing is derived per call. The
    # `!`-less case is a usage error, and raising at expansion reports it without running the call.
    mutates_expr = if haskey(opts, :mutates)
        esc(opts[:mutates])
    elseif fexpr isa Symbol
        endswith(string(fexpr), "!") ||
            throw(ArgumentError("@assert_noalias: `$fexpr` " * _NOALIAS_NO_BANG))
        _bang_positions(nargs)
    else
        nothing
    end
    isdefault = !haskey(opts, :mutates)

    fe = esc(fexpr)
    argsyms = [gensym(:arg) for _ in eachindex(argexprs)]
    binds = Any[:($s = $(esc(e))) for (s, e) in zip(argsyms, argexprs)]

    checked = quote
        $(binds...)
        local _f = $fe
        $(_assert_noalias)($target, _f, ($(argsyms...),); mutates = $mutates_expr, default = $isdefault)
        _f($(argsyms...))
    end
    return _gate(checked, esc(call))
end
