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
    n = _allocated(thunk)         # measure the steady-state call
    if n > 0
        _fail(
            :noalloc, target,
            "call allocated $n bytes at runtime (@allocated fallback). If the checked call " *
                "references a non-`const` global, the allocation may be from the *binding* (global " *
                "access boxes), not the function — make it `const` or a local, or use `:full` mode."
        )
    end
    return val
end

"""
    @assert_noalloc f(args...)
    @assert_noalloc static=false f(args...)

Fail unless the call `f(args...)` is allocation-free.

In the default `:full` [`analysis_mode`](@ref) StrictMode asks
[AllocCheck](https://github.com/JuliaLang/AllocCheck.jl) to *prove* the call cannot allocate; if
the proof reports any allocation site (including dynamic dispatch or boxing) the guarantee fails
with those sites. When static analysis cannot run, it falls back to an empirical `@allocated`
measurement after a warmup call. In `:fast` mode the empirical `@allocated` path is the default.
Pass `static = true`/`false` to force a path regardless of mode.

Each argument is evaluated exactly once. When checks are disabled (the production default) this
expands to the bare call — zero overhead.

```julia
@assert_noalloc sum(rand(100))         # ok
@assert_noalloc grows_a_vector(1000)   # throws StrictViolation listing the allocation
```
"""
macro assert_noalloc(args...)
    # Default to AllocCheck's static proof in :full analysis, the empirical @allocated path in
    # :fast; an explicit `static = …` always wins.
    static = ANALYSIS_MODE === :full
    call = nothing
    for a in args
        if Meta.isexpr(a, :(=)) && a.args[1] === :static
            static = a.args[2]::Bool
        else
            call = a
        end
    end
    call === nothing && throw(ArgumentError("@assert_noalloc needs a call expression"))

    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)
    thunk = Expr(:->, Expr(:tuple), Expr(:block, Expr(:call, esc(fexpr), syms...)))

    checked = quote
        $(binds...)
        $(_assert_noalloc)($target, $(esc(fexpr)), $types, $thunk; static = $static)
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
macro assert_noboxing(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)

    checked = quote
        $(binds...)
        local _val = $litcall
        $(_assert_noboxing)($target, $fe, $types)
        _val
    end
    return _gate(checked, esc(call))
end
