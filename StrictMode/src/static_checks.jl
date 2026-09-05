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

    checked = quote
        $(p.binds...)
        $(_assert_noalloc)($target, $(p.checkfn), $(p.types), $(p.thunk); mode = $(QuoteNode(mode)))
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
        $(_assert_owned)($target, $(p.checkfn), $(p.types); depth = $depth_expr)
        _val
    end
    return _gate(checked, esc(call))
end
