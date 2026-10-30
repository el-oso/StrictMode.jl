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

# The scan half on its own, with no thunk: the caller already has the value.
function _assert_noalloc_scan(target, @nospecialize(f), @nospecialize(types::Tuple))
    sig = _alloc_signals(f, types)
    if sig.alloc || sig.boxing || !isnothing(sig.abscontainer)
        _fail(:noalloc, target, _box_msg("allocates / boxes (value-free IR scan)", sig))
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
        sig = _alloc_signals(f, types)
        if sig.alloc || sig.boxing || !isnothing(sig.abscontainer)
            _fail(:noalloc, target, _box_msg("allocates / boxes (value-free IR scan)", sig))
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
    pos, opts = _macro_call(args, (:static, :types))
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
    sig = _alloc_signals(f, types)
    if sig.boxing || !isnothing(sig.abscontainer)
        _fail(:noboxing, target, _box_msg("boxing / dynamic dispatch (value-free IR scan)", sig))
    end
    return nothing
end

"""
    @assert_noboxing f(args...)

Report if the call boxes or dynamically dispatches — the *type-uncertainty* subclass of
allocations — while **allowing** legitimate typed heap allocations (a `Vector`, a `Memory`, …).

This is the relaxed sibling of [`@assert_noalloc`](@ref): use it for a hot path that may
allocate a buffer but must never box (the runtime-tuple-index trap, captured-variable `Core.Box`,
or accidental dynamic dispatch). Like `@assert_noalloc` it reads typed IR and therefore **reports
rather than gates**; `StrictModeTest`'s `@test_noboxing` classifies AllocCheck's allocation
instances and does gate. Each argument is evaluated once; the macro evaluates to the call's value;
disabled builds expand to the bare call.

```julia
@assert_noboxing fill_buffer!(buf, xs)        # ok: allocates a buffer, but no boxing
@assert_noboxing sum_runtime_index(htuple)    # warns: runtime tuple index (boxing)
```
"""
macro assert_noboxing(args...)
    pos, opts = _macro_call(args, (:types,))
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
    if sig.dictlookup
        _fail(
            :owned, target,
            "hot path resolves a runtime AbstractDict lookup (static-ownership violation): give " *
                "the type a const-dispatched accessor (Ref-per-concrete-type) instead of a runtime " *
                "keyed lookup.";
            gates = gates
        )
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
    pos, opts = _macro_call(args, (:types, :depth))
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
    pos, opts = _macro_call(args, (:types,))
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

# Julia's convention is that a trailing `!` marks a function that mutates its first argument
# (`mul!`, `copyto!`, `ldiv!`), and that is the only default this can justify. A name without `!`
# carries no such claim, so the caller must name the written positions: guessing would compare the
# wrong pair and find nothing, which reads identically to "no aliasing here".
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

function _assert_noalias(
        target, @nospecialize(f), @nospecialize(args::Tuple);
        mutates = nothing, gates::Bool = _guarantee_gates(:noalias)
    )
    n = length(args)
    pos = isnothing(mutates) ? _runtime_mutated(f, n) : _check_mutates(mutates, n)
    isnothing(pos) &&
        throw(ArgumentError("@assert_noalias: `$(_func_name(f))` " * _NOALIAS_NO_BANG))
    # The scan returns on the first overlap and builds the message in a separate frame: a call that
    # satisfies the assertion must allocate nothing, or the assertion changes what it measures.
    for i in pos, j in 1:n
        i == j && continue
        Base.mightalias(args[i], args[j]) && return _noalias_fail(target, args, pos, n, gates)
    end
    return nothing
end

@noinline function _noalias_fail(target, @nospecialize(args::Tuple), pos, n::Int, gates::Bool)
    overlaps = String[]
    for i in pos, j in 1:n
        i == j && continue
        Base.mightalias(args[i], args[j]) && push!(overlaps, "argument $i (written) and argument $j")
    end
    _fail(
        :noalias, target,
        "arguments share memory: " * join(overlaps, ", ") * ". A function that writes one " *
            "argument while reading another assumes they are distinct; when they overlap, the " *
            "result depends on the order the elements happen to be touched, so the same call can " *
            "answer differently under another loop order, blocking, or Julia version. Pass a copy " *
            "of the input, write to a separate destination, or call an in-place form documented " *
            "to accept the overlap.";
        gates = gates
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
else must say so with `mutates = (…)`. A call that gives neither is rejected rather than passed,
since "nothing is written" would compare no pair and accept everything.

```julia
A = rand(8, 8); C = similar(A)
@assert_noalias mul!(C, A, A)              # ok: A may alias itself, only C is written
@assert_noalias mul!(A, A, A)              # fails: the destination is also an input
@assert_noalias mul!(C, A, view(C, :, 1))  # fails: the view reads what C writes

@assert_noalias mutates=(1, 2) swap!(x, y) # neither the name nor one position is enough
```

A call that satisfies the assertion allocates nothing: the pair scan returns on the first overlap
and the message is built in another frame. Costs about 2 ns per pair.

Overlap is checked for the call that runs, not for every call the method could receive, so this
narrows the property one site at a time rather than proving it once. Rust decides the same question
at compile time for every caller; Julia has no construct that can, which is why this is a run-time
assertion that compiles away rather than a static guarantee.

Like every `@assert_*` macro it expands to the bare call when checks are disabled, and the call's
value is returned. Keyword-argument calls are not supported, since `mutates` names positional
positions and a keyword has none.
"""
macro assert_noalias(args...)
    pos, opts = _macro_call(args, (:mutates,))
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

    fe = esc(fexpr)
    argsyms = [gensym(:arg) for _ in eachindex(argexprs)]
    binds = Any[:($s = $(esc(e))) for (s, e) in zip(argsyms, argexprs)]

    checked = quote
        $(binds...)
        local _f = $fe
        $(_assert_noalias)($target, _f, ($(argsyms...),); mutates = $mutates_expr)
        _f($(argsyms...))
    end
    return _gate(checked, esc(call))
end
