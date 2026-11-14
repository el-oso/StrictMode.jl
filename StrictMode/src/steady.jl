# Allocation that stops after a bounded number of calls is not a property of the code: a pool that
# grows to a high-water mark allocates again whenever the mark moves, so `:noalloc` can never pass
# and should not. The claim such code makes is about the CALL SEQUENCE — warm it, and from then on
# it allocates nothing — which is settled by measuring.
#
# That needs real argument values and has to run the call, so it cannot live in the value-free
# `findings`/`audit` pipeline or at a `src` call site. It is the same species as `memsafe_report`
# and `mca_report`: a value-taking function that measures and reports. The gating form is
# `StrictModeTest.@test_steady_state`, which raises; this one never does.

"""
    SteadyStateReport

What [`steady_state_report`](@ref) measured. `bytes` is the allocation of the measured call — the
worst of `repeats` of them — after `warmups` warming calls. `noise` is what an allocation-free
control window of the same duration recorded, measured only when `bytes` is positive and left at
zero otherwise. `fresh_task` records whether the measured call ran on a newly scheduled task, which
is what distinguishes a pool from a per-task initializer, and `nthreads` how many threads the
session had.

Three verdicts, because `@allocated` counts allocation for the whole PROCESS:

- [`steady`](@ref StrictMode.steady) — `iszero(bytes)`. Another task's allocation can only ADD to
  the figure, so a zero is this call's own however busy the process is.
- allocating — `bytes` is positive and the control recorded nothing, so the figure is the call's.
- [`inconclusive`](@ref StrictMode.inconclusive) — the control recorded allocation too, so
  something else in the process was allocating and `bytes` cannot be attributed.

The measurement covers the calls that ran and says nothing about an argument shape it was not
given.
"""
struct SteadyStateReport
    target::String
    bytes::Int
    noise::Int
    warmups::Int
    repeats::Int
    fresh_task::Bool
    nthreads::Int
end

# A busy wait, so the control window allocates nothing of its own.
_spin(window_ns::UInt64) = (
    t0 = time_ns(); while time_ns() - t0 < window_ns
    end; nothing
)

# What a process-wide counter records over a window that allocates NOTHING. Anything it reports was
# allocated by something else, which is what makes a positive figure for the measured call
# unattributable. The window matches the call's own duration, so it is exposed to a neighbor for as
# long as the call was; a very short call therefore gets a very short control.
function _control_bytes(window_ns::UInt64, repeats::Int)
    w = max(window_ns, one(UInt64))
    _spin(w)
    return maximum(_ -> (@allocated _spin(w)), 1:repeats)
end

"""
    StrictMode.steady(r::SteadyStateReport) -> Bool

Whether the measured call allocated nothing. An [`inconclusive`](@ref StrictMode.inconclusive)
report is not steady: a figure that cannot be attributed is not a pass.
"""
steady(r::SteadyStateReport) = iszero(r.bytes)

"""
    StrictMode.inconclusive(r::SteadyStateReport) -> Bool

Whether something else in the process was allocating while the call was measured, which leaves
`bytes` unattributable. Neither steady nor a count of what this call allocates.
"""
inconclusive(r::SteadyStateReport) = !iszero(r.bytes) && !iszero(r.noise)

function Base.show(io::IO, r::SteadyStateReport)
    printstyled(io, "SteadyStateReport"; bold = true)
    print(io, ": ", r.target, "\n")
    if steady(r)
        printstyled(io, "  steady"; color = :green)
        print(io, ": allocates nothing after ", r.warmups, " warmup call(s)")
    elseif inconclusive(r)
        printstyled(io, "  INCONCLUSIVE"; color = :yellow, bold = true)
        print(
            io, ": read ", r.bytes, " byte(s), but an allocation-free control window recorded ",
            r.noise, " byte(s) of its own"
        )
    else
        printstyled(io, "  NOT steady"; color = :yellow, bold = true)
        print(io, ": allocated ", r.bytes, " byte(s) after ", r.warmups, " warmup call(s)")
    end
    r.fresh_task && print(io, ", measured on a fresh task")
    r.repeats > 1 && print(io, ", worst of ", r.repeats)
    print(io, ".\n")
    if inconclusive(r)
        print(
            io, "  `@allocated` counts allocation for the whole process, so another task running ",
            "beside this one lands in the figure — this session has ", r.nthreads,
            " thread(s). Measure on a quiet process.\n"
        )
    elseif !steady(r)
        print(
            io, "  A pool still climbing to its high-water mark needs more warmups; one that ",
            "allocates per task is steady on the warming task and not on a fresh one.\n"
        )
    end
    print(
        io, "  Measured over the calls that ran, so it says nothing about an argument shape it ",
        "was not given."
    )
    return nothing
end

"""
    steady_state_report(f, args...; warmups = 2, repeats = 1, fresh_task = false) -> SteadyStateReport

Measure whether `f(args...)` allocates anything **once warmed**: the call is made `warmups` times,
then measured. Returns a [`SteadyStateReport`](@ref) and never raises.

This is the development-time counterpart to `StrictModeTest.@test_steady_state`, for code whose only
allocation is a workspace pool climbing to a high-water mark. `:noalloc` cannot express that — the
growth path exists on every path, so an all-paths proof must report it forever — and the property
the code really has is about the call sequence, which is why this measures rather than infers.

Like [`memsafe_report`](@ref) and [`mca_report`](@ref) it takes **values**, not types, and runs the
call. It therefore sits outside the value-free `findings`/`audit` pipeline and does not belong at a
`src` call site: put it in a probe, a dogfood block, or a REPL session.

```julia
ws = Workspace()
steady_state_report(solve!, ws, A, b)          # SteadyStateReport: steady
steady_state_report(scratch, ws; fresh_task = true)   # per-task init shows up here
```

`fresh_task = true` measures on a newly scheduled task, which is what separates a **pool** from a
**per-task initializer**: a pool at its high-water mark allocates nothing for any caller, while a
`OncePerTask` accessor is steady on the warming task and not on a fresh one.

`repeats` measures more than once and keeps the worst, for a pool whose growth is uneven.

**A positive figure is checked against a control before it is believed.** `@allocated` counts
allocation for the whole process, not for this call, so a task running beside the measurement lands
in the number — a neighbor allocating in a loop is enough to charge hundreds of kilobytes to an
allocation-free kernel. So a positive figure is followed by an allocation-free window of the same
duration: whatever that window records was allocated by something else, and the report is then
[`inconclusive`](@ref StrictMode.inconclusive) rather than a count of this call's allocation. An
inconclusive report is not a steady one — a figure that cannot be attributed is not a pass — so
measure on a quiet process.

A zero needs no control. Another task's allocation can only add to a process-wide figure, so
`steady` is trustworthy however busy the session is.

A `steady` report covers the calls that ran. It says nothing about an argument shape it was not
given, where an all-paths proof would have — so choose the shapes you measure the way you would
choose benchmark sizes.
"""
function steady_state_report(
        @nospecialize(f), args...;
        warmups::Int = 2, repeats::Int = 1, fresh_task::Bool = false
    )
    warmups >= 1 || throw(ArgumentError("steady_state_report: warmups must be at least 1"))
    repeats >= 1 || throw(ArgumentError("steady_state_report: repeats must be at least 1"))
    target = string(nameof(typeof(f) <: Function ? f : typeof(f))) *
        "(" * join(map(a -> string(typeof(a)), args), ", ") * ")"
    for _ in 1:warmups
        f(args...)
    end
    measure() = @allocated f(args...)
    sample() = fresh_task ? fetch(schedule(Task(() -> measure()))) : measure()
    bytes = maximum(_ -> sample(), 1:repeats)
    # Another task's allocation can only ADD to a process-wide figure, so a zero is this call's own
    # whatever else is running and needs no control. A positive figure does need one, because
    # `@allocated` cannot say whose allocation it counted.
    noise = iszero(bytes) ? 0 :
        _control_bytes(round(UInt64, 1.0e9 * (@elapsed f(args...))), repeats)
    return SteadyStateReport(target, bytes, noise, warmups, repeats, fresh_task, Threads.nthreads())
end

"""
    StrictMode.AllocatedBytes

What one call allocates, measured. `bytes` is the largest figure over `windows` measurements, so a
call that allocates only on some of them is not read as clean; `noise` is what an allocation-free
window of the same duration recorded, which is `0` whenever `bytes` is.

See [`allocated_bytes`](@ref StrictMode.allocated_bytes).
"""
struct AllocatedBytes
    target::String
    bytes::Int
    noise::Int
    warmups::Int
    windows::Int
end

# A type passed as a value sits in a tuple as `DataType`, which would make the measured call a
# dynamic dispatch. Carrying it as a type parameter lets the window splice the type itself back in.
struct _TypeArg{T} end
_wrap_type(@nospecialize(a)) = a isa Type ? _TypeArg{a}() : a
_window_slot(::Type{_TypeArg{T}}, ex) where {T} = T
_window_slot(::Type, ex) = ex

# The measured window. The counter is process-wide, so the window has to contain the call and
# nothing else: a dynamic dispatch on the callee or on an argument allocates inside it and is
# charged to the call.
#
# Three things keep it to the call alone, and each is required:
# - The callee and the arguments arrive as `f::F` and as a tuple with a type parameter. A plain
#   `f` or `args...` that is only passed on is not specialized for a function-valued argument, and
#   `@allocated f(args...)` is such a pass-through — it lowers to `Base.allocated(f, args...)`.
# - The call is generated with its positional and keyword arguments written out, so a keyword
#   call dispatches the way one written by hand does.
# - The result is kept alive until the counter has been read. A result nothing uses lets the
#   compiler delete the allocation that produced it.
@generated function _alloc_window(
        f::F, args::A, ::Val{names}, kw::K
    ) where {F, A <: Tuple, names, K <: Tuple}
    pos = Any[_window_slot(A.parameters[i], :(args[$i])) for i in eachindex(A.parameters)]
    kws = Any[
        Expr(:kw, names[i], _window_slot(K.parameters[i], :(kw[$i])))
            for i in eachindex(K.parameters)
    ]
    callee = _window_slot(F, :f)
    call = isempty(kws) ? Expr(:call, callee, pos...) :
        Expr(:call, callee, Expr(:parameters, kws...), pos...)
    return quote
        Base.@_noinline_meta
        b0 = Base.gc_bytes()
        r = $call
        b1 = Base.gc_bytes()
        Base.donotdelete(r)
        return Int(b1 - b0)
    end
end

_alloc_target(f, args::Tuple, kw::NamedTuple) =
    string(f isa Function || f isa Type ? f : typeof(f)) * "(" *
    join(map(a -> string(Core.Typeof(a)), args), ", ") *
    (isempty(kw) ? "" : "; " * join(("$k::$(Core.Typeof(v))" for (k, v) in pairs(kw)), ", ")) * ")"

"""
    StrictMode.allocated_bytes(f, args = (), kw = (;); warmups = 2, windows = 3) -> AllocatedBytes

Measure what `f(args...; kw...)` allocates. The callee and every argument are concrete inside the
measured window, so the figure does not depend on how the caller's bindings are declared — a
non-const global callee, or a function passed as an argument, adds nothing to it.

`args` is a tuple of values and `kw` a `NamedTuple`. The call is run `warmups + windows` times: the
first `warmups` are discarded and the largest figure of the rest is kept, so a call that allocates
only now and then — a buffer that grows on some calls — is reported.

The allocation counter is process-wide and cannot say whose allocation it counted. A positive
figure is therefore followed by an allocation-free control window of the same duration, and
[`inconclusive`](@ref StrictMode.inconclusive) reports whether that also recorded bytes. A control
that recorded nothing shows the process was quiet then; it cannot show it was quiet during the
measurement. A zero needs no control, because another task's allocation can only add.

The arguments reach the call as run-time values. A call the compiler would fold away when written
with literal arguments is measured as the call it is with those values supplied at run time.

The gating form is `StrictModeTest.@test_allocated_zero`, which reads the call expression directly.

```julia
r = StrictMode.allocated_bytes(gemm!, (C, A, B), (alpha = 2.0, beta = 1.0))
iszero(r.bytes)
```
"""
function allocated_bytes(
        @nospecialize(f), args::Tuple = (), kw::NamedTuple = (;);
        warmups::Int = 2, windows::Int = 3
    )
    warmups >= 1 || throw(ArgumentError("allocated_bytes: warmups must be at least 1"))
    windows >= 1 || throw(ArgumentError("allocated_bytes: windows must be at least 1"))
    wf = _wrap_type(f)
    wargs = map(_wrap_type, args)
    names = Val(keys(kw))
    wkw = map(_wrap_type, values(kw))
    once() = _alloc_window(wf, wargs, names, wkw)::Int
    # Warming through the window compiles the window too, so no measured call pays for it.
    for _ in 1:warmups
        once()
    end
    t0 = time_ns()
    bytes = maximum(_ -> once(), 1:windows)
    per_window = (time_ns() - t0) ÷ UInt64(windows)
    noise = iszero(bytes) ? 0 : _control_bytes(per_window, windows)
    return AllocatedBytes(_alloc_target(f, args, kw), bytes, noise, warmups, windows)
end

"""
    StrictMode.inconclusive(r::AllocatedBytes) -> Bool

Whether something else in the process was allocating while the call was measured, which leaves
`bytes` unattributable.
"""
inconclusive(r::AllocatedBytes) = !iszero(r.bytes) && !iszero(r.noise)

function Base.show(io::IO, r::AllocatedBytes)
    printstyled(io, "AllocatedBytes"; bold = true)
    print(io, ": ", r.target, "\n")
    if iszero(r.bytes)
        printstyled(io, "  zero"; color = :green)
        print(io, ": allocates nothing over ", r.windows, " window(s)")
    elseif inconclusive(r)
        printstyled(io, "  INCONCLUSIVE"; color = :yellow, bold = true)
        print(
            io, ": ", r.bytes, " byte(s), but an allocation-free control window recorded ",
            r.noise, " — something else in this process was allocating"
        )
    else
        printstyled(io, "  ", r.bytes, " byte(s)"; color = :red)
        print(io, " in the worst of ", r.windows, " window(s); a control window recorded 0")
    end
    return nothing
end
