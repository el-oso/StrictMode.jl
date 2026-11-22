# How a spawned worker waits. The discriminator is whether the task can ever park, not whether it
# spins: a pool that spins before it blocks is the correct shape.

@testitem "spin_wait_report flags a migratable task that waits without parking" begin
    using StrictMode

    module SpinPool
    mutable struct P
        @atomic gen::Int
        ev::Threads.Event
        ch::Channel{Int}
        io::IOBuffer
    end

    # Waits by `yield` alone: the loop holds a CPU for as long as it waits, and every `yield`
    # returns the task to the shared queue where it can wake a spare Julia thread.
    function start_broken(p::P)
        Threads.@spawn begin
            seen = 0
            while (@atomic p.gen) == seen
                yield()
            end
            nothing
        end
    end

    # The same loop as a named function the closure calls, which is how a pool is usually written.
    @noinline function worker_loop(p::P)
        while iszero(@atomic p.gen)
            yield()
        end
        return nothing
    end
    start_named(p::P) = Threads.@spawn worker_loop(p)

    # Workers spawned by a helper, from a comprehension.
    @noinline spawn_one(p::P) = Threads.@spawn worker_loop(p)
    start_pool(p::P, n::Int) = [spawn_one(p) for _ in 1:n]

    # Spin, then block. This is the shape the check must approve.
    function start_fixed(p::P)
        Threads.@spawn begin
            seen = 0
            while (@atomic p.gen) == seen
                spun = false
                for _ in 1:2048
                    if (@atomic p.gen) != seen
                        spun = true
                        break
                    end
                    Base.Threads.atomic_fence()
                end
                spun && break
                wait(p.ev)
            end
            nothing
        end
    end

    # The blocking stage sits in a callee.
    @noinline park(p::P) = wait(p.ev)
    function start_parks_in_callee(p::P)
        Threads.@spawn while iszero(@atomic p.gen)
            yield()
            park(p)
        end
    end

    # A fence, a safepoint and a pause keep the CPU without even requeuing the task.
    function start_fence_only(p::P)
        Threads.@spawn while iszero(@atomic p.gen)
            Base.Threads.atomic_fence()
        end
    end
    function start_safepoint_only(p::P)
        Threads.@spawn while iszero(@atomic p.gen)
            GC.safepoint()
        end
    end
    function start_pause_only(p::P)
        Threads.@spawn while iszero(@atomic p.gen)
            ccall(:jl_cpu_pause, Cvoid, ())
        end
    end

    # Emptying a buffer and taking a spin lock do not park the task.
    function start_drains_buffer(p::P)
        Threads.@spawn while iszero(@atomic p.gen)
            yield()
            take!(p.io)
        end
    end
    function start_spinlock(p::P, l::Threads.SpinLock)
        Threads.@spawn while iszero(@atomic p.gen)
            lock(l)
            unlock(l)
            yield()
        end
    end

    # Blocking workers with no spin at all.
    function start_channel(p::P)
        Threads.@spawn for job in p.ch
            @atomic p.gen += job
        end
    end
    function start_channel_yielding(p::P)
        Threads.@spawn for job in p.ch
            yield()
        end
    end
    function start_reader(p::P, io::IOStream)
        Threads.@spawn while !eof(io)
            readline(io)
        end
    end

    # Bound to a thread: by an explicit write, and by never being released.
    function start_pinned(p::P)
        t = Threads.@spawn while iszero(@atomic p.gen)
            yield()
        end
        t.sticky = true
        return t
    end
    start_async(p::P) = @async while iszero(@atomic p.gen)
        yield()
    end
    start_task(p::P) = schedule(
        Task(
            () -> while iszero(@atomic p.gen)
                yield()
            end
        )
    )

    # A bound task that spawns the migratable worker.
    start_supervised(p::P) = @async start_broken(p)

    # A task whose function is not known at the spawn site.
    start_unknown(f) = schedule(Task(f))

    spawns_nothing(p::P) = (@atomic p.gen) + 1
    end

    T = (SpinPool.P,)
    polls(r) = only(r.findings).polls
    clean(r) = isempty(r.findings) && isempty(r.unread)

    r = StrictMode.spin_wait_report(SpinPool.start_broken, T)
    v = only(r.findings)
    @test :yield in v.polls
    @test v.atomic_poll
    @test occursin("shared queue", v.reason)
    @test occursin("busy_wait", sprint(show, r))

    # The loop is read through the call, whether the closure reaches it directly or the spawn
    # itself sits in a helper.
    rn = StrictMode.spin_wait_report(SpinPool.start_named, T)
    @test :yield in polls(rn)
    rpool = StrictMode.spin_wait_report(SpinPool.start_pool, (SpinPool.P, Int))
    @test isone(rpool.tasks)
    @test :yield in polls(rpool)

    # The correct shape passes, with its blocking stage in the loop or in a callee. A per-loop rule
    # would report the inner spin loop, since the `wait` sits in the enclosing one.
    rf = StrictMode.spin_wait_report(SpinPool.start_fixed, T)
    @test clean(rf)
    @test isone(rf.tasks)
    @test occursin("no spin-wait loop", sprint(show, rf))
    @test clean(StrictMode.spin_wait_report(SpinPool.start_parks_in_callee, T))

    # Waiting operations that are not Julia calls.
    @test polls(StrictMode.spin_wait_report(SpinPool.start_fence_only, T)) == [:atomic_fence]
    @test polls(StrictMode.spin_wait_report(SpinPool.start_safepoint_only, T)) == [:safepoint]
    @test polls(StrictMode.spin_wait_report(SpinPool.start_pause_only, T)) == [:cpu_pause]

    # A blocking NAME on a non-blocking operation does not excuse the spin.
    @test :yield in polls(StrictMode.spin_wait_report(SpinPool.start_drains_buffer, T))
    @test :yield in polls(
        StrictMode.spin_wait_report(SpinPool.start_spinlock, (SpinPool.P, Threads.SpinLock))
    )

    # A loop that only blocks is not a spin, and a channel loop that also yields still parks.
    @test clean(StrictMode.spin_wait_report(SpinPool.start_channel, T))
    @test clean(StrictMode.spin_wait_report(SpinPool.start_channel_yielding, T))
    @test clean(StrictMode.spin_wait_report(SpinPool.start_reader, (SpinPool.P, IOStream)))

    # A bound task is counted and not judged. `Threads.@spawn` writes `sticky = false`; `@async`
    # and `Task` write nothing and leave the task bound.
    for start in (SpinPool.start_pinned, SpinPool.start_async, SpinPool.start_task)
        rb = StrictMode.spin_wait_report(start, T)
        @test isempty(rb.findings)
        @test isone(rb.tasks)
        @test isone(rb.bound)
        @test occursin("bound to a thread", sprint(show, rb))
    end

    # …but the tasks it spawns are read.
    rs = StrictMode.spin_wait_report(SpinPool.start_supervised, T)
    @test rs.tasks == 2
    @test isone(rs.bound)
    @test :yield in polls(rs)

    # A task that could not be read is listed, and the report does not render as clean.
    ru = StrictMode.spin_wait_report(SpinPool.start_unknown, (Function,))
    @test isone(ru.tasks)
    @test isone(length(ru.unread))
    @test isempty(ru.findings)
    @test occursin("not read", sprint(show, ru))
    @test !occursin("no spin-wait loop", sprint(show, ru))

    # Nothing spawned, nothing to say.
    rz = StrictMode.spin_wait_report(SpinPool.spawns_nothing, T)
    @test iszero(rz.tasks)
    @test isempty(rz.findings)

    @test_throws "no method matches" StrictMode.spin_wait_report(SpinPool.start_broken, (Int,))
end

@testitem "spin_wait_report reads a spin behind a Base call handed a user value" begin
    using StrictMode

    module SpinShow
    const go = Threads.Atomic{Bool}(false)
    struct Spin end
    @noinline function spinwait()
        while !go[]
            yield()
        end
        return 1
    end
    # A `show` method that spins: Base's printing runs it.
    Base.show(io::IO, ::Spin) = (spinwait(); print(io, "Spin"))
    struct Parks end
    @noinline park() = wait(Threads.Event())
    Base.show(io::IO, ::Parks) = (park(); print(io, "Parks"))
    # Base's default `show` of `Out` prints its field, whose `show` spins; `Out`'s own parks.
    struct Out; x::Spin; end
    Base.show(io::IO, ::Out) = (park(); print(io, "Out"))
    @noinline dflt(io::IOBuffer, o::Out) = (@noinline invoke(show, Tuple{IO, Any}, io, o))

    direct() = fetch(Threads.@spawn spinwait())
    # Blocks properly, and hands Base nothing of its own.
    blocks() = fetch(Threads.@spawn park())
    # The user type is concrete at the Base call; the spin is inside Base's printing of it.
    viashow(s::Spin) = fetch(Threads.@spawn repr(s))
    # The value reaches Base typed `Any`, so which `show` runs is not known from the IR.
    viaany(r::Base.RefValue{Any}) = fetch(Threads.@spawn string("a", r[]))
    # A `show` that parks, reached the same way as `viashow`.
    viashow_parks(s::Parks) = fetch(Threads.@spawn repr(s))
    # `invoke` runs Base's default `show`, which the call-site types do not select.
    viainvoke(o::Out) = fetch(Threads.@spawn dflt(IOBuffer(), o))
    end

    clean(r) = isempty(r.findings) && isempty(r.unread) && iszero(r.unfollowed)

    @test :yield in only(StrictMode.spin_wait_report(SpinShow.direct, ()).findings).polls

    @test clean(StrictMode.spin_wait_report(SpinShow.blocks, ()))

    # Base is entered when it is handed a user value whose type the call site names, so the user
    # `show` it runs is read: one that spins is a finding, one that parks is clean.
    @test :yield in only(StrictMode.spin_wait_report(SpinShow.viashow, (SpinShow.Spin,)).findings).polls
    @test clean(StrictMode.spin_wait_report(SpinShow.viashow_parks, (SpinShow.Parks,)))

    # A value typed `Any` at the Base call, and an `invoke` of a method the site does not select,
    # are counted rather than read, so the report is not clean. Reading the `invoke` at the site's
    # types would read `Out`'s own `show`, which parks, and report the call as clean.
    for (f, T) in ((SpinShow.viaany, (Base.RefValue{Any},)), (SpinShow.viainvoke, (SpinShow.Out,)))
        r = StrictMode.spin_wait_report(f, T)
        @test isempty(r.findings)
        @test r.unfollowed > 0
        @test !clean(r)
        @test !occursin("no spin-wait loop", sprint(show, r))
    end
end

@testitem "spin_wait_report reads the method a wider invoke runs" begin
    using StrictMode
    module WideSpin
    mutable struct P
        @atomic gen::Int
        ev::Threads.Event
    end
    @noinline function spins(p::P, n::Integer)
        while iszero(@atomic p.gen)
            yield()
        end
        return nothing
    end
    @noinline spins(p::P, n::Int) = (wait(p.ev); nothing)
    @noinline parks(p::P, n::Integer) = (wait(p.ev); nothing)
    @noinline function parks(p::P, n::Int)
        while iszero(@atomic p.gen)
            yield()
        end
        return nothing
    end
    # `invoke` runs the `Integer` method on an `Int`; `(P, Int)` dispatches to the other one.
    start_spinning(p::P, n::Int) = Threads.@spawn invoke(spins, Tuple{P, Integer}, p, n)
    start_parking(p::P, n::Int) = Threads.@spawn invoke(parks, Tuple{P, Integer}, p, n)
    end
    M = WideSpin
    r = spin_wait_report(M.start_spinning, (M.P, Int))
    @test length(r.findings) == 1 && r.unfollowed == 0
    r = spin_wait_report(M.start_parking, (M.P, Int))
    @test isempty(r.findings) && r.unfollowed == 0
end
