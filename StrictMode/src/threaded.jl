# What threaded code does at a thread count other than the one it was developed at.
#
# Both questions here are about a PROCESS: Julia's thread count is fixed when the process starts,
# so each data point comes from a child started with its own `-t`, through the same machinery
# `latency_report` uses. Nothing in typed IR answers either.
#
# The call and its setup are strings of code for that reason — a closure cannot cross into a
# process that has not loaded what it closes over.

const _THREADED_RE = r"^STRICTMODE_THREADED (\S+) (\S+)$"

_threaded_fail(what, target, exitcode, err) = throw(
    ErrorException(
        "$what: the child process for `$target` did not report a result" *
            (iszero(exitcode) ? "" : " (it exited $exitcode)") * (isempty(err) ? "" : ".\n" * err)
    )
)

# --- speedup ------------------------------------------------------------------------------------

"""
    ThreadedSpeedupReport

What [`threaded_speedup_report`](@ref) measured: the best of `repeats` timings of one call in a
process with one thread (`serial_ms`) and in one with `nthreads` threads (`threaded_ms`).

`workers` is how many threads the call is expected to use, which is what an efficiency bound is
stated against. `cpus` is how many CPUs both processes were confined to, and `pinned` whether they
were confined at all — `false` where `taskset` is not available.
"""
struct ThreadedSpeedupReport
    target::String
    serial_ms::Float64
    threaded_ms::Float64
    nthreads::Int
    workers::Int
    cpus::Int
    pinned::Bool
end

"""
    StrictMode.speedup(r::ThreadedSpeedupReport) -> Float64

Serial time over threaded time. Below `1` the threaded run is the slower one.
"""
speedup(r::ThreadedSpeedupReport) = r.serial_ms / r.threaded_ms

"""
    StrictMode.efficiency(r::ThreadedSpeedupReport) -> Float64

The speedup per worker: `1` is perfect scaling.
"""
efficiency(r::ThreadedSpeedupReport) = speedup(r) / r.workers

function Base.show(io::IO, r::ThreadedSpeedupReport)
    printstyled(io, "ThreadedSpeedupReport"; bold = true)
    print(io, ": ", r.target, "\n")
    print(io, "  1 thread: ", round(r.serial_ms; digits = 3), " ms\n")
    print(
        io, "  ", r.nthreads, " threads: ", round(r.threaded_ms; digits = 3), " ms — ",
        round(speedup(r); digits = 2), "x, ", round(efficiency(r); digits = 2), " per worker over ",
        r.workers, " worker(s)\n"
    )
    if r.pinned
        print(io, "  Both processes were confined to ", r.cpus, " CPU(s).")
    else
        printstyled(io, "  not confined"; color = :yellow)
        print(
            io, ": `taskset` is not available here, so the processes ran on every CPU and the ",
            "numbers do not show what happens with more threads than CPUs."
        )
    end
    return nothing
end

function _speedup_child_script(pkg::Symbol, call::String, setup::String, workers, repeats::Int)
    w = isnothing(workers) ? "Threads.nthreads()" : string(workers)
    return join(
        [
            "using $pkg",
            setup,
            "($call)",                    # compile, and warm whatever the call keeps
            "t = Inf",
            "for _ in 1:$repeats; global t = min(t, @elapsed ($call)); end",
            "println(\"STRICTMODE_THREADED nthreads \", Threads.nthreads())",
            "println(\"STRICTMODE_THREADED workers \", Int($w))",
            "println(\"STRICTMODE_THREADED seconds \", t)",
            "flush(stdout)",
        ], "\n"
    )
end

function _speedup_child(pkg, call, setup, workers, repeats, flags::Cmd, wrapper::Cmd)
    out, err, exitcode = _run_child(
        _speedup_child_script(pkg, call, setup, workers, repeats); flags, wrapper
    )
    vals = _child_values(out, _THREADED_RE)
    secs = tryparse(Float64, get(vals, "seconds", ""))
    nt = tryparse(Int, get(vals, "nthreads", ""))
    w = tryparse(Int, get(vals, "workers", ""))
    (isnothing(secs) || isnothing(nt) || isnothing(w)) &&
        _threaded_fail("threaded_speedup_report", call, exitcode, err)
    return secs * 1000, nt, w
end

"""
    threaded_speedup_report(pkg::Symbol, call; setup = "", cpus = 4, threads = "auto",
                            workers = nothing, repeats = 5) -> ThreadedSpeedupReport

Time `call` in a fresh process with one thread and in another with `threads` threads, both
confined to `cpus` CPUs, and report the two. Returns a [`ThreadedSpeedupReport`](@ref).

The configuration this exists for is the one users start: `julia -t auto`, where the process has
at least as many Julia threads as CPUs. A kernel benchmarked with one thread per core and nothing
else running can scale there and still run slower than its serial path here, and none of the
static guarantees see it.

`call` and `setup` are strings of code, evaluated in the child after `using pkg`; write them fully
qualified. `setup` runs once, `call` once to warm and then `repeats` times, and the best time is
kept. A call that overwrites its input needs to copy it: `"MyPkg.lu!(copy(A))"`.

`workers` is how many threads the call is expected to use — an integer, or code evaluated in the
threaded child, such as `"MyPkg.nworkers()"`. It defaults to the child's `Threads.nthreads()`.

Confinement uses `taskset`, to the CPUs `0:cpus-1`. Where `taskset` is not available the processes
run unconfined and the report says so.

```julia
threaded_speedup_report(:MyPkg, "MyPkg.lu!(copy(A))"; setup = "A = rand(1024, 1024)")
```

The numbers belong to this machine at this moment. The gating form is
`StrictModeTest.test_threaded_speedup`.
"""
function threaded_speedup_report(
        pkg::Symbol, call::AbstractString; setup::AbstractString = "", cpus::Int = 4,
        threads = "auto", workers = nothing, repeats::Int = 5
    )
    cpus >= 1 || throw(ArgumentError("threaded_speedup_report: cpus must be at least 1"))
    repeats >= 1 || throw(ArgumentError("threaded_speedup_report: repeats must be at least 1"))
    taskset = Sys.which("taskset")
    pinned = !isnothing(taskset)
    wrapper = pinned ? `$taskset -c 0-$(cpus - 1)` : ``
    c, s = String(call), String(setup)
    serial, _, _ = _speedup_child(pkg, c, s, 1, repeats, `-t 1`, wrapper)
    threaded, nt, w = _speedup_child(pkg, c, s, workers, repeats, `-t $threads`, wrapper)
    return ThreadedSpeedupReport(c, serial, threaded, nt, w, cpus, pinned)
end

# --- thread-count invariance --------------------------------------------------------------------

"""
    ThreadcountInvariantReport

What [`threadcount_invariant_report`](@ref) found. For each entry of `threads`: `nthreads`, the
count the child really had; `identical`, whether its result has the same bits as the first
entry's; `first_difference`, the index of the first differing byte (`0` when identical); and
`witnessed`, whether the witness said the threaded path ran (`nothing` when no witness was given).
"""
struct ThreadcountInvariantReport
    target::String
    threads::Vector{Int}
    nthreads::Vector{Int}
    identical::Vector{Bool}
    first_difference::Vector{Int}
    witnessed::Union{Nothing, Vector{Bool}}
end

"""
    StrictMode.invariant(r::ThreadcountInvariantReport) -> Bool

Whether every thread count produced the same bits as the first.
"""
invariant(r::ThreadcountInvariantReport) = all(r.identical)

"""
    StrictMode.witnessed(r::ThreadcountInvariantReport) -> Bool

Whether a witness was given and reported, at every thread count above one, that the threaded path
ran. Without that, identical results are also what a call that never threads produces.
"""
witnessed(r::ThreadcountInvariantReport) =
    !isnothing(r.witnessed) && all(i -> r.nthreads[i] <= 1 || r.witnessed[i], eachindex(r.nthreads))

function Base.show(io::IO, r::ThreadcountInvariantReport)
    printstyled(io, "ThreadcountInvariantReport"; bold = true)
    print(io, ": ", r.target, "\n")
    for i in eachindex(r.threads)
        print(io, "  -t ", r.threads[i], " (", r.nthreads[i], " thread(s)): ")
        if r.identical[i]
            printstyled(io, "identical"; color = :green)
        else
            printstyled(io, "differs"; color = :red)
            print(io, " from byte ", r.first_difference[i])
        end
        if !isnothing(r.witnessed) && r.nthreads[i] > 1
            r.witnessed[i] ? print(io, ", threaded path ran") :
                printstyled(io, ", threaded path did NOT run"; color = :yellow)
        end
        print(io, "\n")
    end
    if isnothing(r.witnessed)
        printstyled(io, "  no witness"; color = :yellow)
        print(
            io, ": nothing shows the threaded path ran, and a call that never threads is ",
            "identical at every thread count too."
        )
    end
    return nothing
end

# The result's bytes, written by the child so the comparison is of bits and not of printed values.
const _INVARIANT_BITS = """
__sm_bits(x::AbstractArray) = isbitstype(eltype(x)) ? collect(reinterpret(UInt8, vec(collect(x)))) :
    error("the result is an array of \$(eltype(x)), which has no fixed bit representation")
__sm_bits(x::Tuple) = reduce(vcat, map(__sm_bits, x); init = UInt8[])
__sm_bits(x) = isbits(x) ? collect(reinterpret(UInt8, [x])) :
    error("the result is a \$(typeof(x)), which has no fixed bit representation")
"""

function _invariant_child_script(pkg::Symbol, call::String, setup::String, witness, path::String)
    lines = [
        "using $pkg", _INVARIANT_BITS, setup,
        "__sm_r = ($call)",
        "write($(repr(path)), __sm_bits(__sm_r))",
        "println(\"STRICTMODE_THREADED nthreads \", Threads.nthreads())",
    ]
    isnothing(witness) ||
        push!(lines, "println(\"STRICTMODE_THREADED witness \", (($witness)::Bool))")
    push!(lines, "flush(stdout)")
    return join(lines, "\n")
end

"""
    threadcount_invariant_report(pkg::Symbol, call; setup = "", threads = 1:Sys.CPU_THREADS,
                                 witness = nothing) -> ThreadcountInvariantReport

Run `call` in a fresh process at each thread count in `threads` and compare the results bit for
bit against the first. Returns a [`ThreadcountInvariantReport`](@ref).

The comparison is of the result's bytes, not of values within a tolerance: a threaded kernel that
splits a reduction differently at each thread count returns answers that agree to rounding and are
not the same answer. The result must be an isbits value, an array of them, or a tuple of those;
`setup` must build the same input every time, so seed any random data.

`witness` is code evaluated in the child after the call, returning `true` when the threaded path
ran — a counter the package's pool increments, for example. There is no way to observe that from
outside the package, and without it a call that silently stays serial passes at every thread
count. The report records that no witness was given; `StrictModeTest.test_threadcount_invariant`
refuses to run without one.

`call` and `setup` are strings of code evaluated after `using pkg`, as in
[`threaded_speedup_report`](@ref).

```julia
threadcount_invariant_report(
    :MyPkg, "MyPkg.mul(A, B)";
    setup = "using Random; Random.seed!(1); A = rand(300, 300); B = rand(300, 300)",
    witness = "MyPkg.pool_jobs() > 0", threads = 1:4,
)
```
"""
function threadcount_invariant_report(
        pkg::Symbol, call::AbstractString; setup::AbstractString = "",
        threads = 1:Sys.CPU_THREADS, witness::Union{Nothing, AbstractString} = nothing
    )
    ts = collect(Int, threads)
    isempty(ts) && throw(ArgumentError("threadcount_invariant_report: threads is empty"))
    c, s = String(call), String(setup)
    nthreads = Int[]
    identical = Bool[]
    first_difference = Int[]
    seen = isnothing(witness) ? nothing : Bool[]
    reference = UInt8[]
    mktempdir() do dir
        for (k, t) in enumerate(ts)
            path = joinpath(dir, "result")
            out, err, exitcode = _run_child(
                _invariant_child_script(pkg, c, s, witness, path); flags = `-t $t`
            )
            vals = _child_values(out, _THREADED_RE)
            nt = tryparse(Int, get(vals, "nthreads", ""))
            (isnothing(nt) || !isfile(path)) &&
                _threaded_fail("threadcount_invariant_report", c, exitcode, err)
            if !isnothing(seen)
                w = tryparse(Bool, get(vals, "witness", ""))
                isnothing(w) && _threaded_fail("threadcount_invariant_report", c, exitcode, err)
                push!(seen, w)
            end
            bytes = read(path)
            rm(path)
            k == 1 && (reference = bytes)
            d = findfirst(i -> bytes[i] != reference[i], 1:min(length(bytes), length(reference)))
            d = isnothing(d) ? (length(bytes) == length(reference) ? 0 : min(length(bytes), length(reference)) + 1) : d
            push!(nthreads, nt)
            push!(identical, iszero(d))
            push!(first_difference, d)
        end
    end
    return ThreadcountInvariantReport(c, ts, nthreads, identical, first_difference, seen)
end
