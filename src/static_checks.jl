# `@assert_noalloc` — fail if a call allocates. Static proof via AllocCheck where possible,
# empirical `@allocated` fallback when static analysis bails (e.g. a construct it can't reason
# about). Dynamic dispatch / boxing surface here too, since AllocCheck reports them as
# allocating.

function _format_allocs(results)
    io = IOBuffer()
    println(io, "call provably allocates (", length(results), " site(s)):")
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
        try
            results = check_allocs(f, types)
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
        _fail(:noalloc, target, "call allocated $n bytes at runtime (@allocated fallback)")
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
