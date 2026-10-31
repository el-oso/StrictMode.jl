# Load time and time-to-first-call are properties of a FRESH process: once a package is loaded and
# a signature compiled, this session can never measure them again. So every number here comes from
# a child, and the measurement is the only form available — there is nothing in typed IR that says
# how long `using` will take.
#
# The child inherits this session's active project, so it measures the environment under test
# rather than a resolution of its own.

"""
    LatencyReport

What [`latency_report`](@ref) measured, in milliseconds, each from its own fresh process.

`load_ms` is the time for `using` the package. `first_call_ms` pairs each requested call with the
time of its first execution in that process — Julia's compile tax for that signature, which a
warmed session cannot see.

`precompiled` records whether the package's cache was already built when the measurement ran. A
measurement taken without it includes precompilation and is not comparable with one taken after,
which is why [`latency_report`](@ref) builds the cache first and reports that it did.
"""
struct LatencyReport
    target::String
    load_ms::Float64
    first_call_ms::Vector{Pair{String, Float64}}
    precompiled::Bool
end

function Base.show(io::IO, r::LatencyReport)
    printstyled(io, "LatencyReport"; bold = true)
    print(io, ": ", r.target, "\n")
    print(io, "  load: ", round(r.load_ms; digits = 1), " ms\n")
    for (call, ms) in r.first_call_ms
        print(io, "  first call ", call, ": ", round(ms; digits = 1), " ms\n")
    end
    if !r.precompiled
        printstyled(io, "  no precompile cache"; color = :yellow)
        print(
            io, ": the load time above includes building it, so it is not comparable with a ",
            "measurement taken after.\n"
        )
    end
    print(
        io, "  Measured in a fresh process on this machine. Load time and first-call time are ",
        "properties of a cold start, so a warmed session cannot measure them and another machine ",
        "will not reproduce the numbers."
    )
    return nothing
end

const _LATENCY_RE = r"^STRICTMODE_LATENCY (\S+) (\S+)$"

function _latency_child_script(pkg::Symbol, calls::Vector{String})
    lines = [
        "t = @elapsed (using $pkg)",
        "println(\"STRICTMODE_LATENCY load \", t)",
    ]
    for (i, c) in enumerate(calls)
        # The call is timed by index, not by its text: the text is the caller's and may hold a
        # space, a quote, or anything else that would not survive a line-oriented protocol.
        #
        # `@eval` inside the timed region is what makes this a FIRST-call measurement. A top-level
        # statement is compiled before it runs, and the call sitting inside it is specialized as
        # part of that compilation — so a bare `@elapsed (call)` starts its clock after the work it
        # means to measure is already done. Measured on a function with a 4000-statement body:
        # `@elapsed (call)` reports 0.03 ms for the first call and 0.02 ms for the second, while
        # `@elapsed @eval (call)` reports 1791.8 ms and 0.45 ms. Without this, `max_first_call_ms`
        # can never catch a regression.
        #
        # `@eval` charges its own parse and lower to every call: 0.45 ms for a plain call in the
        # measurement above, but ~20 ms for an expression that CONSTRUCTS a closure, because each
        # evaluation builds a fresh anonymous function and specializes it again. A `calls` entry
        # holding a `->` therefore reports a compile on every repetition, not only the first.
        push!(lines, "t$i = @elapsed @eval ($c)")
        push!(lines, "println(\"STRICTMODE_LATENCY call$i \", t$i)")
    end
    push!(lines, "flush(stdout)")
    return join(lines, "\n")
end

"""
    latency_report(pkg::Symbol; calls = String[], precompile = true) -> LatencyReport

Measure, in a fresh child process, how long `using pkg` takes and how long the first execution of
each entry in `calls` takes. Returns a [`LatencyReport`](@ref) and never raises.

Nothing else in StrictMode covers this axis. Every guarantee here is about the code a call runs;
this is about the time paid before it runs at all — the load, and the compile tax on the first call
of a signature. Both are properties of a cold process, so this session cannot measure them and a
child is the only way to ask.

`calls` are strings of Julia code, evaluated in the child after the package loads, in order. Write
them fully qualified, since the child does nothing but `using pkg`:

```julia
latency_report(:MyPkg)
latency_report(:MyPkg; calls = ["MyPkg.solve!(MyPkg.Workspace(8), rand(8))"])
```

The package's precompile cache is built before measuring, so the load time is a warm-cache load
rather than a compilation. `precompiled` on the report records that; a `false` there means the
cache could not be built and the number includes work a second run would not repeat.

Building it costs a child process of its own — about twenty seconds for a package of this size.
Pass `precompile = false` where the caller already knows the cache is warm, such as a test suite
that has just loaded the package it is measuring. The report then says `precompiled = false`,
because what it can state is that *this* call did not build the cache, not that nobody did.

Each `calls` entry is timed around an `@eval`, so the first-call number really does include that
call's compilation — a plain `@elapsed` would not, since a top-level statement is compiled before
it runs. Two consequences for how to write one:

- `@eval` adds its own parse and lower to every entry, 0.45 ms for a plain call.
- An entry that **builds a closure** (`"f(x -> 2x, v)"`) specializes a fresh anonymous function on
  every evaluation, so it measures a compile each time rather than only the first — about 20 ms in
  the case measured. Name the function instead (`"f(double, v)"`) to time a first call.

The child inherits this session's active project, so what is measured is the environment under
test. The numbers are machine-specific and do not transfer between hosts — gate on them only where
the host is pinned, which is what `StrictModeTest.@test_latency`'s budgets are for.
"""
function latency_report(
        pkg::Symbol; calls::AbstractVector{<:AbstractString} = String[], precompile::Bool = true
    )
    cs = String[String(c) for c in calls]
    # Precompile first in its own process. Without this the load time measures cache building,
    # which is work the next run does not repeat — a number that halves on a rerun is not a budget.
    precompiled = precompile && try
        pre = `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -e
            "import Pkg; Pkg.precompile()"`
        success(pipeline(pre; stdout = devnull, stderr = devnull))
    catch
        false
    end
    script = _latency_child_script(pkg, cs)
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -e $script`
    outbuf, errbuf = IOBuffer(), IOBuffer()
    proc = run(pipeline(cmd; stdout = outbuf, stderr = errbuf); wait = false)
    wait(proc)
    out = String(take!(outbuf))
    err = String(take!(errbuf))
    seconds = Dict{String, Float64}()
    for line in eachline(IOBuffer(out))
        m = match(_LATENCY_RE, line)
        isnothing(m) && continue
        v = tryparse(Float64, m[2])
        isnothing(v) || (seconds[m[1]] = v)
    end
    haskey(seconds, "load") || throw(
        ErrorException(
            "latency_report: the child process did not report a load time for `$pkg`" *
                (iszero(proc.exitcode) ? "" : " (it exited $(proc.exitcode))") *
                (isempty(err) ? "" : ".\n" * err)
        )
    )
    firsts = Pair{String, Float64}[]
    for (i, c) in enumerate(cs)
        haskey(seconds, "call$i") || continue
        push!(firsts, c => seconds["call$i"] * 1000)
    end
    return LatencyReport(String(pkg), seconds["load"] * 1000, firsts, precompiled)
end
