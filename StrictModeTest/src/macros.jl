# The companion macros. `StrictMode.@assert_noalloc` names a value-free scan that reports;
# `StrictModeTest.@test_noalloc` names the AllocCheck proof of the same property, and it gates.
# Which engine a call site uses is decided by which macro you wrote — there is no mode to switch
# and no ambient state to read.
#
# These are deliberately NOT wrapped in `StrictMode._gate`: a gate that compiles itself away under
# a preference is a gate that can vanish silently. `__init__` refuses to load with checks disabled,
# so the question does not arise.

# Prove `guarantees` and raise if any fails. `kind` names the macro in the exception, so a
# composite reports as `@strict`/`@kernel` rather than as whichever of its parts failed first.
function _test_guarantee(kind::Symbol, guarantees::Tuple, target, @nospecialize(f), @nospecialize(types::Tuple))
    fs = _proof_findings(f, types, guarantees)
    failed = filter(StrictMode._failed, fs)
    isempty(failed) && return nothing
    msg = sprint(io -> StrictMode.format_findings(io, failed; format = :text))
    throw(StrictMode.StrictViolation(kind, target, msg))
end

# Shared expansion for every `@test_*`: evaluate each argument once, run the call for its value,
# prove the guarantees, hand the value back. One `_proof_findings` call covers a composite, so
# `@test_kernel` runs AllocCheck once rather than once per bundled guarantee.
function _test_macro_expr(kind::Symbol, guarantees::Tuple, macroname::String, args)
    pos, opts = StrictMode._macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("$macroname needs a call expression"))
    call = pos[1]
    target = string(call)
    p = StrictMode._call_parts(call; types = get(opts, :types, nothing))
    return quote
        $(p.binds...)
        local _val = $(p.litcall)
        $(_test_guarantee)($(QuoteNode(kind)), $guarantees, $target, $(p.checkfn), $(p.types))
        _val
    end
end

"""
    @test_noalloc f(args...)
    @test_noalloc f(args...) types=(T1, T2, …)

Fail unless AllocCheck can **prove** `f(args...)` allocates nothing on any path.

This is the authoritative counterpart to [`StrictMode.@assert_noalloc`](@ref), which reads typed IR
and only reports. A violation here throws a `StrictMode.StrictViolation`, so it is what a test suite
or a CI gate should use. Each argument is evaluated once and the macro returns the call's value.

Allocations on never-taken throw branches are ignored by default — see [`set_ignore_throw!`](@ref) —
as is a call whose only allocation is a recognized one-time-init barrier
(see [`set_ignore_barrier!`](@ref)).

```julia
@test_noalloc dot3(a, b)              # ok
@test_noalloc grows_a_vector(1000)    # throws StrictViolation listing the allocation sites
```
"""
macro test_noalloc(args...)
    return _test_macro_expr(:noalloc, (:noalloc,), "@test_noalloc", args)
end

"""
    @test_noboxing f(args...)

Fail unless AllocCheck proves `f(args...)` performs no boxing or dynamic dispatch, while
**allowing** legitimate typed heap allocations (a `Vector`, a `Memory`, …). The proving counterpart
to [`StrictMode.@assert_noboxing`](@ref).

```julia
@test_noboxing fill_buffer!(buf, xs)        # ok: allocates a buffer, but no boxing
@test_noboxing sum_runtime_index(htuple)    # throws: jl_get_nth_field_checked (tuple boxing)
```
"""
macro test_noboxing(args...)
    return _test_macro_expr(:noboxing, (:noboxing,), "@test_noboxing", args)
end

"""
    @test_typestable f(args...)

Fail unless `f(args...)` is type stable: the inferred return type is a single concrete type (or a
small isbits `Union`), **and** JET's optimization analysis reports nothing.

[`StrictMode.@assert_typestable`](@ref) throws on the return-type layer too — that half is exact —
but substitutes an IR boxing signal for JET, and only warns on it. This macro is the proof of that
second layer.

```julia
@test_typestable muladd(2.0, 3.0, 1.0)          # ok
@test_typestable pick(heterogeneous_tuple, i)   # throws: Union from runtime tuple index
```
"""
macro test_typestable(args...)
    return _test_macro_expr(:typestable, (:typestable,), "@test_typestable", args)
end

"""
    @test_trim_compatible f(args...)

Fail unless juliac's own `verify_typeinf_trim` verifier accepts `f(args...)` for a
`--trim=safe` build. The authoritative counterpart to
[`StrictMode.@assert_trim_compatible`](@ref)'s static scan, and unlike that scan it covers
reachability-limit union-splits.

```julia
@test_trim_compatible entrypoint(argv)
```
"""
macro test_trim_compatible(args...)
    return _test_macro_expr(:trim_compatible, (:trim_compatible,), "@test_trim_compatible", args)
end

"""
    @test_strict f(args...)

Fail unless `f(args...)` is both type stable and allocation-free — the proving counterpart of
[`StrictMode.@strict`](@ref), which bundles the same two guarantees but only reports the allocation
half.

```julia
@test_strict kernel!(C, A, B)
```
"""
macro test_strict(args...)
    return _test_macro_expr(:strict, (:typestable, :noalloc), "@test_strict", args)
end

"""
    @test_kernel f(args...)

Fail unless `f(args...)` is type stable, allocation-free **and** vectorized — the proving
counterpart of [`StrictMode.@kernel`](@ref). `:vectorized` is a best-effort LLVM-IR scan in both
tiers (it observes compiled output, so it already gated); what this adds over `@kernel` is
AllocCheck's proof for the allocation half and JET's for the stability half.

```julia
@test_kernel axpy!(y, a, x)
```
"""
macro test_kernel(args...)
    return _test_macro_expr(:kernel, (:typestable, :noalloc, :vectorized), "@test_kernel", args)
end
