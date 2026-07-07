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


function _assert_noalloc(target, @nospecialize(f), @nospecialize(types::Tuple), thunk::F; static::Bool) where {F}
    val = thunk()                 # warm up / force compilation, and capture the call's value
    if static
        _require_backend()
        try
            results = _be_check_allocs(f, types)
            if !isempty(results)
                _fail(:noalloc, target, _format_allocs(results))
            end
            return val
        catch err
            err isa StrictViolation && rethrow()
            # Static analysis could not run on this call; fall through to the empirical path.
        end
    end
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
                _be_check_allocs(f, types)
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
guarantee fails and lists them. When static analysis can't run, it falls back to measuring with
`@allocated` after a warmup call, and in `:fast` mode that empirical path is the default. Pass
`static = true`/`false` to force one path regardless of mode.

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
    # Default to AllocCheck's static proof in :full analysis, the empirical @allocated path in
    # :fast; an explicit `static = …` always wins.
    pos, opts = _macro_call(args, (:static, :types))
    static = haskey(opts, :static) ? opts[:static]::Bool : ANALYSIS_MODE === :full
    isempty(pos) && throw(ArgumentError("@assert_noalloc needs a call expression"))
    call = pos[1]
    target = string(call)
    p = _call_parts(call; types = get(opts, :types, nothing))

    checked = quote
        $(p.binds...)
        $(_assert_noalloc)($target, $(p.checkfn), $(p.types), $(p.thunk); static = $static)
    end
    return _gate(checked, esc(call))
end

# --- @assert_noboxing: the boxing/dispatch subclass of allocations specifically ---
# (Classifying an AllocCheck instance as boxing lives in the StrictModeAnalysisExt extension,
# behind `_be_is_boxing`, since it pattern-matches AllocCheck's instance types.)

function _assert_noboxing(target, @nospecialize(f), @nospecialize(types::Tuple))
    _require_backend()
    results = try
        _be_check_allocs(f, types)
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
    target = string(call)
    p = _call_parts(call; types = get(opts, :types, nothing))

    checked = quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_assert_noboxing)($target, $(p.checkfn), $(p.types))
        _val
    end
    return _gate(checked, esc(call))
end

# --- @assert_owned: no runtime AbstractDict lookup on owned scratch (GKH-ownership lint) ---
# Value-free structural lint (same category as @assert_noboxing): scans optimized typed IR for a
# runtime `AbstractDict` accessor reached on the hot path, following non-inlined callees (the
# lookup usually lives in a workspace accessor, not the top function). No backend, no timing.

function _assert_owned(target, @nospecialize(f), @nospecialize(types::Tuple); depth::Int = 2)
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
the bare call. Pass `depth = n` (default 2) to control how many non-inlined callee levels are
walked.

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
    depth = haskey(opts, :depth) ? opts[:depth]::Int : 2
    p = _call_parts(call; types = get(opts, :types, nothing))

    checked = quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_assert_owned)($target, $(p.checkfn), $(p.types); depth = $depth)
        _val
    end
    return _gate(checked, esc(call))
end
