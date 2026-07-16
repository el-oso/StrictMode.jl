# `@assert_noalloc` — fail if a call allocates. Static proof via AllocCheck where possible,
# empirical `@allocated` fallback when static analysis bails (e.g. a construct it can't reason
# about). Dynamic dispatch / boxing surface here too, since AllocCheck reports them as
# allocating.

function _format_allocs(results; header = "call provably allocates")
    io = IOBuffer()
    println(io, header, " (", length(results), " site(s)):")
    for (i, a) in enumerate(results)
        print(io, "  [", i, "] ")
        # AllocCheck instances `show` with their source location and reason; reuse that.
        print(io, a)
        i < length(results) && println(io)
    end
    return String(take!(io))
end

# Force specialization on the thunk type (`where {F}`): otherwise calling a Function-typed
# argument is a dynamic dispatch that itself allocates, producing a false positive in the
# empirical path.
@inline _allocated(thunk::F) where {F} = @allocated thunk()

# Resolve @assert_noalloc's (and @strict's/@kernel's) check strategy. `static_opt` is the parsed
# `static=` keyword value, or `nothing` if not given. An explicit value always wins: `true` forces
# AllocCheck's static proof, `false` forces the empirical `@allocated` path. With no override, the
# default is AllocCheck in `:full` analysis and the value-free `_alloc_signals` heuristic in
# `:fast` — not `@allocated`, which is value-dependent and reserved for the explicit opt-out.
_noalloc_mode(static_opt::Union{Nothing, Bool}) =
    static_opt === nothing ? (ANALYSIS_MODE === :full ? :static : :heuristic) :
    static_opt ? :static : :empirical

function _assert_noalloc(target, @nospecialize(f), @nospecialize(types::Tuple), thunk::F; mode::Symbol) where {F}
    val = thunk()                 # warm up / force compilation, and capture the call's value
    if mode === :static
        _require_backend()
        try
            results, _ = _checked_allocs(f, types)
            if !isempty(results)
                _fail(:noalloc, target, _format_allocs(results))
            end
            return val
        catch err
            err isa StrictViolation && rethrow()
            # Static analysis could not run on this call; fall through to the empirical path.
        end
    elseif mode === :heuristic
        # F38 — the :fast default (no explicit `static=`). A value-free IR scan (`_alloc_signals`,
        # the same engine `findings(...; mode=:fast)` uses), not the value-dependent `@allocated`
        # measurement below: matches what `analysis_mode`'s docstring already promises for the
        # batch API ("quick triage, no execution"), which this macro's `:fast` path had been
        # silently missing — it always fell straight to `@allocated`, an empirical measurement of
        # THIS call's inputs, not a signature-level verdict.
        sig = _alloc_signals(f, types)
        if sig.alloc || sig.boxing || sig.abscontainer !== nothing
            _fail(:noalloc, target, _box_msg("allocates / boxes (fast heuristic)", sig))
        end
        return val
    end
    # mode === :empirical (explicit `static=false`), or :static's fallback when AllocCheck
    # could not analyze this call.
    n = _allocated(thunk)         # measure the steady-state call (gc_num delta)
    if n > 0
        # `@allocated` is the `gc_num().allocd` delta, which can be **nonzero with no real allocation** — a
        # GC accounting artifact (SIMD / `GC.@preserve`-heavy kernels show a fixed per-call delta even when
        # AllocCheck and `--track-allocation` prove the call allocates nothing). So a nonzero number alone
        # is not proof. If the static backend (AllocCheck) is loaded, it is authoritative — escalate to it:
        # only fail if it *also* finds a real allocation site; if it proves the call clean, the `@allocated`
        # number was an artifact, so pass (with a note).
        if backend_available()
            results = try
                first(_checked_allocs(f, types))
            catch err
                err isa StrictViolation && rethrow()
                nothing
            end
            if results !== nothing && isempty(results)
                @warn "StrictMode @assert_noalloc: `$target` measured @allocated=$n B, but AllocCheck " *
                    "proves the call allocates nothing — a gc_num accounting artifact (common in SIMD / " *
                    "GC.@preserve kernels), not an allocation. Treating as alloc-free." maxlog = 1
                return val
            end
            results !== nothing && !isempty(results) && _fail(:noalloc, target, _format_allocs(results))
        end
        _fail(
            :noalloc, target,
            "call allocated $n bytes at runtime (@allocated). NOTE: `@allocated` measures the gc_num " *
                "counter, which can report a per-call artifact with no real allocation on SIMD / " *
                "GC.@preserve-heavy code — load AllocCheck and use `:full` mode for a definitive static " *
                "proof. If the call references a non-`const` global, the allocation may be the binding " *
                "(global access boxes), not the function — make it `const`/local."
        )
    end
    return val
end

"""
    @assert_noalloc f(args...)
    @assert_noalloc f(args...; kw...)
    @assert_noalloc static=false f(args...)
    @assert_noalloc f(args...) types=(T1, T2, …)

Fail unless the call `f(args...)` is allocation-free.

In the default `:full` [`analysis_mode`](@ref), StrictMode hands the call to
[AllocCheck](https://github.com/JuliaLang/AllocCheck.jl) and asks it to prove the call cannot
allocate. If the proof turns up any allocation site, dynamic dispatch and boxing included, the
guarantee fails and lists them. In `:fast` mode, the default is the same value-free IR heuristic
`findings(...; mode=:fast)` uses (`StrictMode._alloc_signals` — no execution beyond the one
warmup call every path needs to produce the return value). Pass `static = false` to force the
empirical `@allocated`-after-warmup path instead (useful when the heuristic can't reason about a
construct, or per E3, when a non-`const` global's binding boxing is the actual culprit); `static =
true` forces the AllocCheck proof regardless of mode.

Each argument is evaluated exactly once. With checks disabled (the production default) this expands
to the bare call, with no overhead left behind.

**Keyword arguments** are supported: `f(x; k=v)` is proved at its real specialization (routed
through `Core.kwcall`, so AllocCheck sees the keyword sorter's method). **`types = (…)`** pins the
analyzed signature explicitly, mirroring [`@assert_typestable`](@ref) — handy for type-argument
functions where `typeof.(args)` would not name the real call-site specialization.

```julia
@assert_noalloc sum(rand(100))         # ok
@assert_noalloc grows_a_vector(1000)   # throws StrictViolation listing the allocation
@assert_noalloc fill!(buf, x; offset=0)  # ok: keyword call proved as-is
```
"""
macro assert_noalloc(args...)
    # Default to AllocCheck's static proof in :full analysis, the value-free _alloc_signals
    # heuristic in :fast; an explicit `static = …` always wins (`false` forces the empirical
    # @allocated path — see `_noalloc_mode`).
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
# (Classifying an AllocCheck instance as boxing lives in the StrictModeAnalysisExt extension,
# behind `_be_is_boxing`, since it pattern-matches AllocCheck's instance types.)

function _assert_noboxing(target, @nospecialize(f), @nospecialize(types::Tuple))
    _require_backend()
    results = try
        first(_checked_allocs(f, types))
    catch err
        err isa StrictViolation && rethrow()
        _fail(:noboxing, target, "AllocCheck could not analyze this call: $(sprint(showerror, err))")
        return nothing
    end
    boxing = filter(_be_is_boxing, results)
    if !isempty(boxing)
        _fail(:noboxing, target, _format_allocs(boxing; header = "call boxes / dynamically dispatches"))
    end
    return nothing
end

"""
    @assert_noboxing f(args...)

Fail if the call boxes or dynamically dispatches — the *type-uncertainty* subclass of
allocations — while **allowing** legitimate typed heap allocations (a `Vector`, a `Memory`, …).

This is the relaxed sibling of [`@assert_noalloc`](@ref): use it for a hot path that may
allocate a buffer but must never box (the runtime-tuple-index trap, captured-variable `Core.Box`,
or accidental dynamic dispatch). It is always a static [AllocCheck] analysis — it must classify
each allocation — so it ignores the `:fast` [`analysis_mode`](@ref). Each argument is evaluated
once; the macro evaluates to the call's value; disabled builds expand to the bare call.

```julia
@assert_noboxing fill_buffer!(buf, xs)        # ok: allocates a buffer, but no boxing
@assert_noboxing sum_runtime_index(htuple)    # throws: jl_get_nth_field_checked (tuple boxing)
```
"""
macro assert_noboxing(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@assert_noboxing needs a call expression"))
    call = pos[1]
    checked = _guarantee_expr(call, _assert_noboxing; types = get(opts, :types, nothing))
    return _gate(checked, esc(call))
end

# --- @assert_owned: no runtime AbstractDict lookup on owned scratch (GKH-ownership lint) ---
# Value-free structural lint (same category as @assert_noboxing): scans optimized typed IR for a
# runtime `AbstractDict` accessor reached on the hot path, following non-inlined callees (the
# lookup usually lives in a workspace accessor, not the top function). No backend, no timing.

function _assert_owned(target, @nospecialize(f), @nospecialize(types::Tuple); depth::Int = _FAST_ALLOC_DEPTH[])
    sig = _alloc_signals(f, types; depth = depth)
    if sig.dictlookup
        _fail(
            :owned, target,
            "hot path resolves a runtime AbstractDict lookup (owned-scratch/GKH violation): give " *
                "the type a const-dispatched accessor (Ref-per-concrete-type) instead of a runtime " *
                "keyed lookup."
        )
    end
    return nothing
end

"""
    @assert_owned f(args...)

Fail if the call reaches a **runtime `AbstractDict` lookup** on its hot path — the *owned-scratch*
(a.k.a. GKH-ownership) violation: an owned workspace/scratch accessor must resolve to a
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
