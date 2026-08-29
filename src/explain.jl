# `@explain` — diagnostics. Where the assert macros report a verdict, `@explain` says why: it
# gathers the inferred return type, the typed-IR allocation/boxing signals, and `@code_warntype`
# into one `StrictReport` instead of a raw tool dump.

"""
    StrictReport

The aggregated diagnostic produced by [`@explain`](@ref). Its `MIME"text/plain"` show method
prints a sectioned, human-readable report; the fields are also available programmatically:

- `target::String` — the analyzed call.
- `return_type` / `return_concrete::Bool` — the inferred return type and whether it is concrete.
- `signals` — the typed-IR scan result (`alloc`, `boxing`, `dictlookup`, `abscontainer`, `barrier`,
  and the source location of the first signal), or `nothing` if the scan could not run.
- `local_boxing::Bool` — dynamic dispatch in *this* function's own IR, as opposed to a callee's.
- `scan_error::Union{Nothing,String}` — why the IR scan could not run, if applicable.
- `warntype::String` — captured `@code_warntype` output.
"""
struct StrictReport
    target::String
    return_type::Any
    return_concrete::Bool
    signals::Any
    local_boxing::Bool
    scan_error::Union{Nothing, String}
    warntype::String
end

# Convenience predicates mirroring what the assert macros conclude from the same signals.
would_fail_typestable(r::StrictReport) = !r.return_concrete || r.local_boxing
would_fail_noalloc(r::StrictReport) =
    !isnothing(r.signals) && (r.signals.alloc || r.signals.boxing || !isnothing(r.signals.abscontainer))
would_fail_noboxing(r::StrictReport) =
    !isnothing(r.signals) && (r.signals.boxing || !isnothing(r.signals.abscontainer))

function _strict_report(target, @nospecialize(f), @nospecialize(types::Tuple))
    rts = try
        Base.return_types(f, Tuple{types...})
    catch
        Any[Any]
    end
    rt = isempty(rts) ? Any : reduce((a, b) -> Union{a, b}, rts)
    signals, local_boxing, scan_error = try
        (_alloc_signals(f, types), _alloc_signals(f, types; depth = 0).boxing, nothing)
    catch err
        err isa StrictViolation && rethrow()
        (nothing, false, sprint(showerror, err))
    end
    warntype = try
        sprint(io -> InteractiveUtils.code_warntype(io, f, types))
    catch err
        "(@code_warntype unavailable: $(sprint(showerror, err)))"
    end
    return StrictReport(target, rt, _is_typestable_return(rt), signals, local_boxing, scan_error, warntype)
end

_indent(io, text, prefix) = foreach(ln -> println(io, prefix, ln), eachline(IOBuffer(text)))

# What the IR scan found, as a human-readable list.
function _signal_labels(s)
    labels = String[]
    s.alloc && push!(labels, "allocation")
    s.boxing && push!(labels, "boxing / dynamic dispatch")
    s.dictlookup && push!(labels, "runtime AbstractDict lookup")
    isnothing(s.abscontainer) || push!(labels, "abstract-eltype container (`$(s.abscontainer)`)")
    s.barrier && push!(labels, "one-time-init allocation barrier (not counted)")
    return labels
end

function Base.show(io::IO, ::MIME"text/plain", r::StrictReport)
    println(io, "StrictMode @explain — ", r.target)
    println(io)

    mark = r.return_concrete ? "✓ concrete" : "✗ not concrete"
    println(io, "  Return type:    ", r.return_type, "  ", mark)

    println(
        io, "  Local dispatch: ",
        r.local_boxing ? "✗ this function's own IR dispatches dynamically" : "✓ none in this function's own IR"
    )

    if !isnothing(r.scan_error)
        println(io, "  IR signals:     ? could not scan: ", r.scan_error)
    else
        labels = _signal_labels(r.signals)
        if isempty(labels)
            println(io, "  IR signals:     ✓ none")
        else
            println(io, "  IR signals:     ✗ ", join(labels, ", "))
            r.signals.file == "" || println(io, "                  at ", r.signals.file, ":", r.signals.line)
        end
    end

    println(io)
    println(io, "  Verdict:")
    println(
        io, "    ", would_fail_typestable(r) ? "✗ @assert_typestable would fail" :
            "✓ @assert_typestable would pass"
    )
    if isnothing(r.scan_error)
        println(
            io, "    ", would_fail_noalloc(r) ? "✗ @assert_noalloc would fail" :
                "✓ @assert_noalloc would pass"
        )
        # Only worth mentioning the relaxed check when it differs from no-alloc (i.e. there are
        # allocation signals, but are any of them *boxing*?).
        if would_fail_noalloc(r)
            println(
                io, "    ", would_fail_noboxing(r) ? "✗ @assert_noboxing would fail (boxing / dispatch)" :
                    "✓ @assert_noboxing would pass (allocations are not boxing)"
            )
        end
    else
        println(io, "    ? @assert_noalloc could not be determined (the IR scan did not run)")
    end
    println(io)
    println(
        io, "  These verdicts come from a value-free engine: it reads typed IR, where an allocation\n",
        "  LLVM will later elide is still present. `StrictModeTest`'s `@test_noalloc` /\n",
        "  `@test_typestable` run AllocCheck and JET over the same signature for a proof."
    )

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
    na = isnothing(r.scan_error) ? (would_fail_noalloc(r) ? "allocates" : "noalloc") : "alloc?"
    print(io, "StrictReport(", r.target, ": ", ts, ", ", na, ")")
    return nothing
end

"""
    @explain f(args...)

Diagnose `f(args...)` without throwing. It gathers the inferred return type, a scan of the typed IR
for allocation and dynamic-dispatch signals, and `@code_warntype` into a single
[`StrictReport`](@ref) that explains why a guarantee would fail, along with a verdict for what
[`@assert_typestable`](@ref) and [`@assert_noalloc`](@ref) would conclude.

Think of it as the "tell me why" companion to the assert macros: reach for it when a verdict needs
explaining. It returns the report, which the REPL prints; assign it if you'd rather read the fields
yourself. It's gated by `checks_enabled` and expands to the bare call when disabled.

The engine is the value-free one, so its allocation verdict is a structural guess — for the proof,
add `StrictModeTest` and run `@test_noalloc` / `@test_typestable` on the same call.

```julia
state = (1, 2.0, "three")
component(s, i) = s[i]

@explain component(state, rand(1:3))
# StrictMode @explain — component(state, rand(1:3))
#
#   Return type:    Union{Float64, Int64, String}  ✗ not concrete
#   Local dispatch: ✗ this function's own IR dispatches dynamically
#   IR signals:     ✗ boxing / dynamic dispatch
#
#   Verdict:
#     ✗ @assert_typestable would fail
#     ✗ @assert_noalloc would fail
```
"""
macro explain(args...)
    pos, opts = _macro_call(args, (:types,))
    isempty(pos) && throw(ArgumentError("@explain needs a call expression"))
    call = pos[1]
    target = string(call)
    p = _call_parts(call; types = get(opts, :types, nothing))

    checked = quote
        $(p.binds...)
        $(_strict_report)($target, $(p.checkfn), $(p.types))
    end
    return _gate(checked, esc(call))
end
