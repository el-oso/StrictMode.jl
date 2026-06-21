# `@explain` — diagnostics mode. Where the assert macros *fail loudly*, `@explain` *tells you
# why*: it aggregates `@code_warntype`, JET `@report_opt` and AllocCheck into one digestible
# `StrictReport` instead of a raw tool dump.

"""
    StrictReport

The aggregated diagnostic produced by [`@explain`](@ref). Its `MIME"text/plain"` show method
prints a sectioned, human-readable report; the fields are also available programmatically:

- `target::String` — the analyzed call.
- `return_type` / `return_concrete::Bool` — the inferred return type and whether it is concrete.
- `opt_result` / `opt_reports` — JET `@report_opt` result and its reports (type instability,
  runtime dispatch, boxing).
- `allocs` — AllocCheck allocation sites (`nothing` if static analysis could not run).
- `alloc_error::Union{Nothing,String}` — why AllocCheck could not run, if applicable.
- `warntype::String` — captured `@code_warntype` output.
"""
struct StrictReport
    target::String
    return_type::Any
    return_concrete::Bool
    opt_result::Any
    opt_reports::Any
    allocs::Union{Nothing, Vector}
    alloc_error::Union{Nothing, String}
    warntype::String
end

# Convenience predicates mirroring what the assert macros would conclude.
would_fail_typestable(r::StrictReport) = !r.return_concrete || !isempty(r.opt_reports)
would_fail_noalloc(r::StrictReport) = r.alloc_error === nothing && r.allocs !== nothing && !isempty(r.allocs)
would_fail_noboxing(r::StrictReport) = r.alloc_error === nothing && r.allocs !== nothing && any(_is_boxing, r.allocs)

function _explain(target, @nospecialize(f), @nospecialize(types::Tuple), opt_result)
    rts = try
        Base.return_types(f, Tuple{types...})
    catch
        Any[Any]
    end
    rt = isempty(rts) ? Any : reduce((a, b) -> Union{a, b}, rts)
    opt_reports = JET.get_reports(opt_result)
    allocs, alloc_error = try
        (check_allocs(f, types), nothing)
    catch err
        err isa StrictViolation && rethrow()
        (nothing, sprint(showerror, err))
    end
    warntype = try
        sprint(io -> InteractiveUtils.code_warntype(io, f, types))
    catch err
        "(@code_warntype unavailable: $(sprint(showerror, err)))"
    end
    return StrictReport(target, rt, isconcretetype(rt), opt_result, opt_reports, allocs, alloc_error, warntype)
end

_indent(io, text, prefix) = foreach(ln -> println(io, prefix, ln), eachline(IOBuffer(text)))

function Base.show(io::IO, ::MIME"text/plain", r::StrictReport)
    println(io, "StrictMode @explain — ", r.target)
    println(io)

    # Return type
    mark = r.return_concrete ? "✓ concrete" : "✗ not concrete"
    println(io, "  Return type:    ", r.return_type, "  ", mark)

    # Type stability (JET)
    if isempty(r.opt_reports)
        println(io, "  Type stability: ✓ no issues (JET @report_opt)")
    else
        println(io, "  Type stability: ✗ ", length(r.opt_reports), " issue(s) (JET @report_opt):")
        _indent(io, rstrip(sprint(show, r.opt_result)), "    │ ")
    end

    # Allocations (AllocCheck)
    if r.alloc_error !== nothing
        println(io, "  Allocations:    ? could not analyze statically: ", r.alloc_error)
    elseif isempty(r.allocs)
        println(io, "  Allocations:    ✓ none (AllocCheck)")
    else
        println(io, "  Allocations:    ✗ ", length(r.allocs), " site(s) (AllocCheck):")
        for (i, a) in enumerate(r.allocs)
            println(io, "    [", i, "] ", a)
        end
    end

    # Verdict
    println(io)
    println(io, "  Verdict:")
    println(
        io, "    ", would_fail_typestable(r) ? "✗ @assert_typestable would fail" :
            "✓ @assert_typestable would pass"
    )
    if r.alloc_error !== nothing
        println(io, "    ? @assert_noalloc could not be statically determined (try `static = false`)")
    else
        println(
            io, "    ", would_fail_noalloc(r) ? "✗ @assert_noalloc would fail" :
                "✓ @assert_noalloc would pass"
        )
        # Only worth mentioning the relaxed check when it differs from no-alloc (i.e. there are
        # allocations, but are any of them *boxing*?).
        if would_fail_noalloc(r)
            println(
                io, "    ", would_fail_noboxing(r) ? "✗ @assert_noboxing would fail (boxing / dispatch)" :
                    "✓ @assert_noboxing would pass (allocations are not boxing)"
            )
        end
    end

    # Full @code_warntype, but only when there is an instability worth digging into.
    if would_fail_typestable(r)
        println(io)
        println(io, "  ── @code_warntype ──")
        _indent(io, rstrip(r.warntype), "  ")
    end
    return nothing
end

function Base.show(io::IO, r::StrictReport)
    ts = would_fail_typestable(r) ? "unstable" : "stable"
    na = r.alloc_error !== nothing ? "alloc?" : (would_fail_noalloc(r) ? "allocates" : "noalloc")
    print(io, "StrictReport(", r.target, ": ", ts, ", ", na, ")")
    return nothing
end

"""
    @explain f(args...)

Diagnose `f(args...)` without throwing: aggregate `@code_warntype`, JET `@report_opt` and
AllocCheck into a single [`StrictReport`](@ref) that explains *why* a guarantee would fail
(non-concrete return type, runtime dispatch / boxing, allocation sites) and a verdict for what
[`@assert_typestable`](@ref) / [`@assert_noalloc`](@ref) would conclude.

This is the "tell me why" companion to the fail-loud assert macros: reach for it when a
[`StrictViolation`](@ref) needs explaining. It returns the report (the REPL prints it); assign
it to inspect the fields programmatically. Like the asserts it is gated by `checks_enabled` and
expands to the bare call when disabled.

```julia
state = (1, 2.0, "three")
component(s, i) = s[i]

@explain component(state, rand(1:3))
# StrictMode @explain — component(state, rand(1:3))
#
#   Return type:    Union{Float64, Int64, String}  ✗ not concrete
#   Type stability: ✗ 1 issue(s) (JET @report_opt): …
#   Allocations:    ✗ 1 site(s) (AllocCheck): …
#
#   Verdict:
#     ✗ @assert_typestable would fail
#     ✗ @assert_noalloc would fail
```
"""
macro explain(call)
    target = string(call)
    fexpr, argexprs = _callinfo(call)
    syms, binds = _bind_args(argexprs)
    fe = esc(fexpr)
    litcall = Expr(:call, fe, syms...)
    types = Expr(:tuple, (:(typeof($s)) for s in syms)...)

    checked = quote
        $(binds...)
        $(_explain)($target, $fe, $types, JET.@report_opt($litcall))
    end
    return _gate(checked, esc(call))
end
