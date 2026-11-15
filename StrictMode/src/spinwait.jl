# How a spawned task WAITS, read from typed IR.
#
# The defect is a wait loop with no blocking stage, not the presence of a spin: a pool that spins
# before it parks is the correct shape, so `yield()` in a loop is not a finding by itself. What
# separates the two is whether the task can ever stop consuming a CPU. A loop whose only waiting
# operations are `yield`, a safepoint, a pause or a fence runs at full occupancy for as long as it
# waits, and every `yield` returns the task to the shared queue, where it can wake a spare Julia
# thread that then competes with the workers for a core.
#
# A finding needs evidence on both sides: a waiting operation was READ in a loop, and no blocking
# operation was read anywhere the task reaches. A loop with neither says nothing about how it
# waits — it may block in a foreign call, as a read from a file does — and is not reported.
#
# Only a task that can MIGRATE is judged. A task is created bound to the thread that first runs it
# (`Task(f)` and `@async` leave it so); `Threads.@spawn` releases it by writing `sticky = false`.
# A bound task cannot wake a spare thread.
#
# The scan follows `:invoke` into callees outside Base, so a worker loop written as a named
# function is read. A callee in Base is judged by its name and argument types and entered only
# when it carries a user function: `yield` itself parks through `wait`, and entering it would read
# every spin as blocking.
#
# Whatever the scan could not read is counted and shown — a task whose closure type is unknown, a
# dynamic call, a callee past the body limit — because an unread task is not a task that parks.

"""
    StrictMode.SpinWaitFinding

One migratable task that waits in a loop and reaches no blocking call. `polls` are the waiting
operations read, `atomic_poll` whether an atomic field is read, and `unfollowed` how many calls in
the task's reach the scan did not follow — a blocking call inside one of those reads as absent.
"""
struct SpinWaitFinding
    target::String
    reason::String
    polls::Vector{Symbol}
    atomic_poll::Bool
    unfollowed::Int
end

"""
    StrictMode.SpinWaitReport

What [`spin_wait_report`](@ref StrictMode.spin_wait_report) read.

- `findings` — the migratable tasks that spin without a blocking stage.
- `tasks` — every task creation found.
- `bound` — how many of those stay bound to a thread and were therefore not judged.
- `unread` — one line per task whose body could not be read.
- `unfollowed` — calls the scan did not follow, outside the tasks that carry a finding.

A report with no findings is a statement about what was read: check `unread` and `unfollowed`
before taking it as a clean result.
"""
struct SpinWaitReport
    target::String
    findings::Vector{SpinWaitFinding}
    tasks::Int
    bound::Int
    unread::Vector{String}
    unfollowed::Int
end

# Operations that park the task, so the loop can reach a state where it consumes no CPU. `lock` is
# absent: taking a lock is mutual exclusion, not a wait stage, and a `SpinLock` spins.
const _SW_BLOCK_OPS = Set{Symbol}(
    (
        :wait, :sleep, :take!, :fetch, :acquire, :waitany, :waitall, :timedwait, :systemsleep,
        :take_buffered, :take_unbuffered, :put_buffered, :put_unbuffered,
    )
)
# Blocking only when a channel is among the arguments.
const _SW_CHANNEL_OPS = Set{Symbol}((:iterate, :put!))
# `GC.safepoint()` and a CPU pause are foreign calls, not Julia calls.
const _SW_POLL_FCALLS = Dict{Symbol, Symbol}(:jl_gc_safepoint => :safepoint, :jl_cpu_pause => :cpu_pause)
const _SW_BLOCK_FCALLS = Dict{Symbol, Symbol}(:usleep => :systemsleep, :nanosleep => :systemsleep)
# Builtins that make a call the scan cannot resolve.
const _SW_DYNAMIC_BUILTINS = Set{Symbol}((:_apply_iterate, :invoke, :invokelatest, :_call_latest, :_call_in_world))
const _SW_ATOMIC_ORDERS = Set{Symbol}(
    (:unordered, :monotonic, :acquire, :release, :acquire_release, :sequentially_consistent)
)
const _SW_MAX_BODIES = 64

# Everything one root signature reaches: the root's body and the non-Base callees it invokes.
mutable struct _SwReach
    polls::Vector{Symbol}
    blocks::Vector{Symbol}
    loop::Bool
    atomic::Bool
    unfollowed::Int
    bodies::Int
    tasks::Vector{Any}
end
_SwReach() = _SwReach(Symbol[], Symbol[], false, false, 0, 0, Any[])

_sw_note!(v::Vector{Symbol}, s::Symbol) = (s in v || push!(v, s); nothing)

function _sw_is_base(m::Module)
    root = Base.moduleroot(m)
    return root === Base || root === Core
end

# Whether a type is, or carries as a parameter, a function defined outside Base — a closure handed
# to `map`, `foreach` or a comprehension's `Generator`.
function _sw_carries_user_function(@nospecialize(T))
    T = Base.unwrap_unionall(T)
    T isa DataType || return false
    T <: Function && !_sw_is_base(parentmodule(T)) && return true
    return any(_sw_carries_user_function, T.parameters)
end

# A callee outside Base is entered. One in Base is entered only when it was handed user code to
# run, since that is the one way a Base method reaches back into the analyzed package.
_sw_follows(mi::Core.MethodInstance) =
    !_sw_is_base(mi.def.module) || _sw_carries_user_function(mi.specTypes)

# The value a call's callee slot names, when it is a constant.
function _sw_callee_value(@nospecialize(a))
    a isa GlobalRef || return a isa Core.SSAValue || a isa Core.Argument ? nothing : a
    isconst(a.mod, a.name) || return nothing
    return try
        getglobal(a.mod, a.name)
    catch
        nothing
    end
end

# `spec` is the callee's specialized signature, or `nothing` for a call resolved by name alone.
function _sw_classify(name::Symbol, @nospecialize(spec))
    name === :yield && return :poll
    ps = spec isa DataType ? spec.parameters : ()
    if name in _SW_BLOCK_OPS
        # `take!` on a buffer empties it and returns at once.
        name === :take! && any(p -> p isa Type && p <: IO, ps) && return :other
        return :block
    end
    name in _SW_CHANNEL_OPS && any(p -> p isa Type && p <: AbstractChannel, ps) && return :block
    return :other
end

function _sw_record!(r::_SwReach, name::Symbol, @nospecialize(spec))
    k = _sw_classify(name, spec)
    k === :poll && _sw_note!(r.polls, name)
    k === :block && _sw_note!(r.blocks, name)
    return k
end

# `getfield(x, :f, :order)` is an atomic read. The third argument of a plain `getfield` is a
# bounds-check flag, so the ordering has to be matched, not the argument count.
_sw_is_atomic_read(st::Expr, name::Symbol) =
    name === :getfield && length(st.args) >= 4 && st.args[4] isa QuoteNode &&
    st.args[4].value in _SW_ATOMIC_ORDERS

# The task a `jl_new_task` statement creates: its closure type and whether it can migrate.
# The closure is the first ccall argument, at index 6 — after the function, the return type, the
# argument types, the required-argument count and the calling convention.
function _sw_task(ci::Core.CodeInfo, i::Int, st::Expr, @nospecialize(sig))
    a = length(st.args) >= 6 ? st.args[6] : nothing
    T = if a isa Core.SSAValue
        ci.ssavaluetypes isa Vector ? _widen_taint(ci.ssavaluetypes[a.id]) : nothing
    elseif a isa Core.Argument
        sig isa DataType && a.n <= length(sig.parameters) ? sig.parameters[a.n] : nothing
    else
        v = _sw_callee_value(a isa QuoteNode ? a.value : a)
        isnothing(v) ? nothing : Core.Typeof(v)
    end
    readable = T isa Type && isconcretetype(T)
    # A task starts bound to its thread. `false` written to `sticky` releases it; a written value
    # that is not a literal is treated as releasing it, so the task is judged rather than skipped.
    migrates = false
    for s in ci.code
        Meta.isexpr(s, :call) && length(s.args) == 4 || continue
        _sw_callee_value(s.args[1]) === setfield! || continue
        s.args[2] == Core.SSAValue(i) || continue
        s.args[3] isa QuoteNode && s.args[3].value === :sticky || continue
        migrates = s.args[4] !== true
    end
    why = readable ? "" : "a task whose function has no concrete type here (" * string(T) * ")"
    return (; T = readable ? T : nothing, migrates, why)
end

function _sw_scan!(r::_SwReach, ci::Core.CodeInfo, @nospecialize(sig), queue::Vector{Any})
    for i in eachindex(ci.code)
        st = ci.code[i]
        if (st isa Core.GotoNode && st.label <= i) || (st isa Core.GotoIfNot && st.dest <= i)
            r.loop = true
        end
        st isa Expr || continue
        if st.head === :foreigncall
            fn = _fcall_name(st)
            if fn === :jl_new_task
                push!(r.tasks, _sw_task(ci, i, st, sig))
            elseif haskey(_SW_POLL_FCALLS, fn)
                _sw_note!(r.polls, _SW_POLL_FCALLS[fn])
            elseif haskey(_SW_BLOCK_FCALLS, fn)
                _sw_note!(r.blocks, _SW_BLOCK_FCALLS[fn])
            end
        elseif st.head === :invoke
            mi = _invoke_mi(st.args[1])
            if !(mi isa Core.MethodInstance && mi.def isa Method)
                r.unfollowed += 1
                continue
            end
            k = _sw_record!(r, mi.def.name, mi.specTypes)
            k === :other && _sw_follows(mi) && push!(queue, mi.specTypes)
        elseif st.head === :call
            v = _sw_callee_value(st.args[1])
            if v isa Core.IntrinsicFunction || v isa Core.Builtin
                name = nameof(v)
                r.atomic |= _sw_is_atomic_read(st, name)
                # `Threads.atomic_fence()` is an intrinsic of that name, or an `llvmcall` of a
                # `fence` instruction, depending on the Julia version.
                if name === :atomic_fence ||
                        (name === :llvmcall && any(x -> x isa String && occursin("fence", x), st.args))
                    _sw_note!(r.polls, :atomic_fence)
                elseif name in _SW_DYNAMIC_BUILTINS
                    r.unfollowed += 1
                end
            else
                # A call left to run-time dispatch: known only by name, if at all.
                a = st.args[1]
                k = a isa GlobalRef ? _sw_record!(r, a.name, nothing) : :other
                k === :other && (r.unfollowed += 1)
            end
        end
    end
    return r
end

function _sw_reach(@nospecialize(sig))
    r = _SwReach()
    seen = Set{Any}()
    queue = Any[sig]
    while !isempty(queue)
        s = pop!(queue)
        s in seen && continue
        push!(seen, s)
        if length(seen) > _SW_MAX_BODIES
            r.unfollowed += 1
            continue
        end
        cts = try
            _code_typed_by_type(s; optimize = true)
        catch
            Any[]
        end
        read = false
        for pr in cts
            ci = first(pr)
            ci isa Core.CodeInfo || continue
            read = true
            r.bodies += 1
            _sw_scan!(r, ci, s, queue)
        end
        read || (r.unfollowed += 1)
    end
    return r
end

function _sw_finding(@nospecialize(T), r::_SwReach)
    reason = "waits by " * join(string.(r.polls), "/") * " in a loop and reaches no blocking " *
        "call, so it keeps a CPU busy for as long as it waits"
    if :yield in r.polls
        reason *= "; each `yield` also returns the task to the shared queue, where it can wake " *
            "a spare Julia thread that then competes with the workers for a core"
    end
    reason *= ". Add a blocking stage — spin, then bound the yielding, then `wait` on a " *
        "`Threads.Event` — or bind the worker to its thread."
    if r.unfollowed > 0
        reason *= " " * string(r.unfollowed) * " call(s) it reaches were not followed; a " *
            "blocking call inside one reads as absent."
    end
    return SpinWaitFinding(string(T), reason, copy(r.polls), r.atomic, r.unfollowed)
end

"""
    StrictMode.spin_wait_report(f, types) -> SpinWaitReport

Report the migratable tasks `f(types...)` spawns that wait in a loop without ever blocking.

A long-lived worker started with `Threads.@spawn` can move between Julia threads, and a loop that
waits by `yield()`, `GC.safepoint()`, a CPU pause or a fence alone keeps a CPU busy for as long as
it waits. Under `julia -t auto` the process has more Julia threads than CPUs, so such workers
compete with the ones doing the work. The shape that does not is spin, then bounded yielding, then
a blocking `wait`.

A task is reported when a waiting operation is read in a loop and no blocking operation — `wait`,
`sleep`, `take!`, `fetch`, `acquire`, iterating or `put!`-ing a channel — is read anywhere the task
reaches. So a pool that spins before it parks passes, and so does a loop that only blocks. The
scan reads the task's closure and the callees outside Base it invokes, and the tasks those spawn
in turn.

Tasks that stay bound to a thread are counted in `bound` and not judged: `Task(f)` and `@async`
create a bound task, and `Threads.@spawn` releases it.

Advisory, with these limits:

- A blocking call inside a call that was not followed reads as absent. Those calls are counted in
  each finding and in the report's `unfollowed`.
- A task whose closure type is not concrete at the spawn site is listed in `unread`.
- A loop that yields between units of work, without waiting for anything, is reported as well.
- The tasks of `Threads.@threads` are created inside Base and are not found.

```julia
r = StrictMode.spin_wait_report(start_pool!, (Int,))
isempty(r.findings) && isempty(r.unread)
```
"""
function spin_wait_report(@nospecialize(f), @nospecialize(types::Tuple))
    target = string(f isa Function || f isa Type ? f : typeof(f)) * _sig_string(types)
    cts = try
        _code_typed(f, types; optimize = true)
    catch err
        throw(ArgumentError("spin_wait_report: could not analyze $target: $(sprint(showerror, err))"))
    end
    isempty(cts) && throw(ArgumentError("spin_wait_report: no method matches $target"))

    root = _sw_reach(Base.signature_type(f, types))
    findings = SpinWaitFinding[]
    unread = String[]
    unfollowed = root.unfollowed
    ntasks = 0
    bound = 0
    pending = copy(root.tasks)
    judged = Set{Any}()
    while !isempty(pending)
        t = popfirst!(pending)
        ntasks += 1
        if isnothing(t.T)
            push!(unread, t.why)
            continue
        end
        t.migrates || (bound += 1)
        (t.T, t.migrates) in judged && continue
        push!(judged, (t.T, t.migrates))
        r = _sw_reach(Tuple{t.T})
        if iszero(r.bodies)
            push!(unread, "a task whose body has no typed IR (" * string(t.T) * ")")
            continue
        end
        append!(pending, r.tasks)       # a task may spawn the workers
        if t.migrates && r.loop && !isempty(r.polls) && isempty(r.blocks)
            push!(findings, _sw_finding(t.T, r))
        else
            unfollowed += r.unfollowed
        end
    end
    return SpinWaitReport(target, findings, ntasks, bound, unread, unfollowed)
end

function Base.show(io::IO, r::SpinWaitReport)
    printstyled(io, "SpinWaitReport"; bold = true)
    print(io, ": ", r.target, " — ", r.tasks, " task(s) found")
    r.bound > 0 && print(io, ", ", r.bound, " bound to a thread and not judged")
    print(io, "\n")
    for v in r.findings
        printstyled(io, "  [busy_wait] "; color = :yellow, bold = true)
        print(io, v.target, "\n      ", v.reason, "\n")
        v.atomic_poll && print(io, "      the task polls an atomic field\n")
    end
    for u in r.unread
        printstyled(io, "  [not read] "; color = :yellow, bold = true)
        print(io, u, "\n")
    end
    if r.unfollowed > 0
        printstyled(io, "  [not followed] "; color = :yellow, bold = true)
        print(
            io, r.unfollowed, " call(s) outside the findings — a task spawned or a wait loop ",
            "inside one reads as absent\n"
        )
    end
    if isempty(r.findings) && isempty(r.unread) && iszero(r.unfollowed)
        printstyled(io, "  no spin-wait loop"; color = :green)
        print(io, " in the ", r.tasks - r.bound, " migratable task(s) read\n")
    end
    return nothing
end
