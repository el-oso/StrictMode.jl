@testitem "the scan follows the package's own helpers past the Base depth limit" begin
    using StrictMode
    @noinline h6(x) = (v = Float64[]; push!(v, x); v)
    @noinline h5(x) = h6(x)
    @noinline h4(x) = h5(x)
    @noinline h3(x) = h4(x)
    @noinline h2(x) = h3(x)
    @noinline h1(x) = h2(x)
    top(x) = h1(x)
    @test StrictMode._alloc_signals(top, (Float64,)).alloc
    f = only(StrictMode.findings(top, (Float64,); guarantees = (:noalloc,)))
    @test StrictMode._failed(f)
    @test f.code === :SM0002
end

@testitem "a scan that did not read the whole call tree never passes" begin
    using StrictMode
    @noinline c4(x) = x + 1.0
    @noinline c3(x) = c4(x) * 2.0
    @noinline c2(x) = c3(x) - 1.0
    @noinline c1(x) = c2(x) / 3.0
    top(x) = c1(x)

    StrictMode.clear_cache!()
    for g in (:noalloc, :noboxing)
        @test !StrictMode._failed(only(StrictMode.findings(top, (Float64,); guarantees = (g,))))
    end

    old = StrictMode._SCAN_BODY_BUDGET[]
    try
        StrictMode._SCAN_BODY_BUDGET[] = 2
        StrictMode.clear_cache!()
        for g in (:noalloc, :noboxing)
            f = only(StrictMode.findings(top, (Float64,); guarantees = (g,)))
            @test StrictMode._failed(f)
            @test f.code === :SM0207
            @test occursin("not established", f.reason)
        end
        @test occursin("scan could not read", StrictMode.explain(:SM0207))
    finally
        StrictMode._SCAN_BODY_BUDGET[] = old
        StrictMode.clear_cache!()
    end
end

@testitem "a Ref handed to a ccall through unsafe_convert stays on the stack" begin
    using StrictMode
    store!(x::Float64, p::Ptr{Float64}) = (unsafe_store!(p, x); nothing)
    const FP = Ref{Ptr{Cvoid}}(C_NULL)
    FP[] = @cfunction(store!, Cvoid, (Float64, Ptr{Float64}))
    const SINK = Ref{Ptr{Float64}}(C_NULL)

    function through_pointer(x::Float64)
        o = Ref(0.0)
        p = Base.unsafe_convert(Ptr{Float64}, o)
        GC.@preserve o ccall(FP[], Cvoid, (Float64, Ptr{Float64}), x, p)
        return o[]
    end
    function pointer_escapes(x::Float64)
        o = Ref(x)
        SINK[] = Base.unsafe_convert(Ptr{Float64}, o)
        return o[]
    end

    through_pointer(1.0); pointer_escapes(1.0)
    @test iszero(@allocated through_pointer(2.0))
    @test !StrictMode._alloc_signals(through_pointer, (Float64,)).alloc
    # A pointer kept past the call is a different shape, and the scan still reports the Ref.
    @test StrictMode._alloc_signals(pointer_escapes, (Float64,)).alloc
end

@testitem "an allocation-only scan agrees with the full scan on allocation and boxing" begin
    using StrictMode
    @noinline g3(x) = (v = Float64[]; push!(v, x); v)
    @noinline g2(x) = g3(x)
    alloc_top(x) = g2(x)
    @noinline k3(x) = x * 2.0
    @noinline k2(x) = k3(x) + 1.0
    clean_top(x) = k2(x)
    boxy(t, i) = t[i]
    for f in (alloc_top, clean_top)
        a = StrictMode._alloc_signals(f, (Float64,); mode = :alloc)
        b = StrictMode._alloc_signals(f, (Float64,))
        @test a.alloc == b.alloc
        @test a.boxing == b.boxing
    end
    @test StrictMode._alloc_signals(boxy, (Tuple{Int, Float64}, Int); mode = :alloc).boxing
end

@testitem "an allocation behind a registered barrier is excused at any depth" begin
    using StrictMode
    @noinline ws(::Type{T}) where {T} = Vector{T}(undef, 64)
    @noinline l3(x::Int) = length(ws(Float64)) + x
    @noinline l2(x::Int) = l3(x) + 1
    @noinline l1(x::Int) = l2(x) + 1
    top(x::Int) = l1(x) + 1
    try
        register_alloc_barrier!(ws)
        for g in (:noalloc, :noboxing)
            f = only(StrictMode.findings(top, (Int,); guarantees = (g,)))
            @test !StrictMode._failed(f)
        end
        @test StrictMode._alloc_signals(top, (Int,)).barrier
    finally
        empty!(StrictMode._ALLOC_BARRIERS)
        let st = StrictMode._store_for(Main, :__strict_barriers__)
            isnothing(st) || empty!(st)
        end
        StrictMode._BARRIER_GEN[] += 1
        StrictMode.clear_cache!()
    end
    # without the registration the same chain allocates
    @test StrictMode._failed(only(StrictMode.findings(top, (Int,); guarantees = (:noalloc,))))
end

@testitem "an allocation behind a registered barrier called with keywords is excused" begin
    using StrictMode
    @noinline ws_kw(::Type{T}; extra::Int = 0) where {T} = Vector{T}(undef, 64 + extra)
    @noinline l3(x::Int) = length(ws_kw(Float64; extra = x)) + x
    @noinline l2(x::Int) = l3(x) + 1
    @noinline l1(x::Int) = l2(x) + 1
    top(x::Int) = l1(x) + 1
    try
        register_alloc_barrier!(ws_kw)
        f = only(StrictMode.findings(top, (Int,); guarantees = (:noalloc,)))
        @test !StrictMode._failed(f)
    finally
        empty!(StrictMode._ALLOC_BARRIERS)
        let st = StrictMode._store_for(Main, :__strict_barriers__)
            isnothing(st) || empty!(st)
        end
        StrictMode._BARRIER_GEN[] += 1
        StrictMode.clear_cache!()
    end
end

@testitem "the precompile workload reports nothing and leaves nothing behind" begin
    using StrictMode
    W = StrictMode.PrecompileWorkload
    only = StrictMode._WORKLOAD_FUNCTIONS
    items = StrictMode._module_load_items(W, (:typestable, :noalloc); only)
    @test !isempty(items)
    # What the workload checks must pass, so that checking it prints nothing at any install.
    @test !any(StrictMode._failed, StrictMode._map_findings(StrictMode._scan_findings, items))
    @test_logs StrictMode._auto_check_module(W, (:typestable, :noalloc); only)
    StrictMode._precompile_workload()
    # The workload keeps its compiler specializations only while it runs.
    @test !StrictMode._KEEP_SCAN_SPECIALIZATIONS[]
    @test isempty(StrictMode._BODY_MEMO)
    @test isempty(StrictMode._TOP_SIGNAL_MEMO)
end

@testitem "a Ref read back after a ccall through a stored function pointer, behind an atomic counter" begin
    using StrictMode
    mutable struct Counter
        @atomic value::Int
    end
    const CALLS = Counter(0)
    function kern(out::Ptr{Float64}, x::Ptr{Float64}, y::Ptr{Float64}, n::Int)
        s = 0.0
        for i in 1:n
            s += unsafe_load(x, i) * unsafe_load(y, i)
        end
        unsafe_store!(out, s)
        return nothing
    end
    const ENTRY = Ref{Ptr{Cvoid}}(C_NULL)
    ENTRY[] = @cfunction(kern, Cvoid, (Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Int))
    function entry_dot(n::Int, x::Vector{Float64}, y::Vector{Float64})
        @atomic CALLS.value += 1
        nb = n ÷ 8
        o = Ref(0.0)
        GC.@preserve x y o begin
            ccall(
                ENTRY[], Cvoid, (Ptr{Float64}, Ptr{Float64}, Ptr{Float64}, Int),
                Base.unsafe_convert(Ptr{Float64}, o), pointer(x), pointer(y), nb
            )
        end
        s = o[]
        GC.@preserve x y begin
            for i in (8 * nb + 1):n
                s = muladd(unsafe_load(pointer(x), i), unsafe_load(pointer(y), i), s)
            end
        end
        return s
    end
    function plain_dot(x::Vector{Float64}, y::Vector{Float64})
        length(x) >= 65536 && return entry_dot(length(x), x, y)
        s = 0.0
        for i in eachindex(x, y)
            s += x[i] * y[i]
        end
        return s
    end
    x = ones(1000); y = ones(1000)
    entry_dot(1000, x, y)
    @test iszero(@allocated entry_dot(1000, x, y))
    @test !StrictMode._alloc_signals(entry_dot, (Int, Vector{Float64}, Vector{Float64})).alloc
    @test !StrictMode._alloc_signals(plain_dot, (Vector{Float64}, Vector{Float64})).alloc
end

@testitem "_signal_origin names the statement and the callee an allocation comes from" begin
    using StrictMode
    @noinline leaf(n::Int) = (a = Float64[]; push!(a, n); a)
    @noinline mid(n::Int) = length(leaf(n))
    top(n::Int) = mid(n) + 1
    o = StrictMode._signal_origin(top, (Int,))
    @test !isempty(o)
    @test any(x -> occursin("leaf", string(x.signature)), o)
    @test length(first(o).path) >= 0
    @test all(x -> !isempty(x.statements), o)
    @test isempty(StrictMode._signal_origin(mid, (Int,); mode = :boxing))
end

@testitem "barriers taking a type or a OncePerTask, behind positional-default chains, are stopped at" begin
    using StrictMode
    const GP = IdDict{Any, Any}()
    @noinline gpack(::Type{T}) where {T} = get!(() -> (T[], T[]), GP, T)::NTuple{2, Vector{T}}
    const OPT = Base.OncePerTask{Base.RefValue{Matrix{Float64}}}(() -> Ref(zeros(2, 2)))
    @noinline opt(o::Base.OncePerTask{Base.RefValue{Matrix{Float64}}, F}) where {F} = o()
    @noinline function drv(A::Vector{Float64}, a::Bool, b::Bool, c::Bool)
        w = gpack(Float64)
        m = opt(OPT)
        return length(w[1]) + length(m[]) + length(A) + (a & b & c)
    end
    drv(A::Vector{Float64}, a::Bool, b::Bool) = drv(A, a, b, false)
    drv(A::Vector{Float64}, a::Bool) = drv(A, a, false)
    drv(A::Vector{Float64}) = drv(A, true)
    @noinline mid(A::Vector{Float64}) = drv(A) + 1
    top(A::Vector{Float64}) = mid(A) + 1
    A = ones(4)
    try
        register_alloc_barrier!(gpack)
        register_alloc_barrier!(opt)
        f = only(StrictMode.findings(top, (Vector{Float64},); guarantees = (:noalloc,)))
        @test !StrictMode._failed(f)
        @test isempty(StrictMode._signal_origin(top, (Vector{Float64},)))
        stops = StrictMode._barrier_stops(top, (Vector{Float64},))
        @test any(s -> occursin("gpack", string(s)), stops)
        @test any(s -> occursin("opt", string(s)), stops)
    finally
        empty!(StrictMode._ALLOC_BARRIERS)
        let st = StrictMode._store_for(Main, :__strict_barriers__)
            isnothing(st) || empty!(st)
        end
        StrictMode._BARRIER_GEN[] += 1
        StrictMode.clear_cache!()
    end
    # not behind a barrier: the same chain allocates
    @test !isempty(StrictMode._signal_origin(top, (Vector{Float64},)))
end

@testitem "a registered barrier is also recorded in the package that owns it" begin
    using StrictMode
    @noinline ws(::Type{T}) where {T} = Vector{T}(undef, 8)
    try
        register_alloc_barrier!(ws)
        store = StrictMode._store_for(Base.moduleroot(parentmodule(ws)), :__strict_barriers__)
        @test !isnothing(store) && any(g -> g === ws, store)
        @test any(g -> g === ws, StrictMode._barrier_functions())
        # a second registration is not a second record
        register_alloc_barrier!(ws)
        @test count(g -> g === ws, store) == 1
    finally
        empty!(StrictMode._ALLOC_BARRIERS)
        let st = StrictMode._store_for(Main, :__strict_barriers__)
            isnothing(st) || empty!(st)
        end
        StrictMode._BARRIER_GEN[] += 1
        StrictMode._BARRIER_GEN[] += 1
        StrictMode.clear_cache!()
    end
end

@testitem "a barrier registered by a package excuses the allocation behind it at that package's own precompile" begin
    using StrictMode
    dir = mktempdir()
    mkpath(joinpath(dir, "FixPkg", "src"))
    function source(register)
        return """
        module FixPkg
        using StrictMode
        const GP = IdDict{Any, Any}()
        @noinline gpack(::Type{T}) where {T} = get!(() -> (T[], T[]), GP, T)::NTuple{2, Vector{T}}
        $(register ? "register_alloc_barrier!(gpack)" : "")
        @noinline function drv(A::Vector{Float64}, a::Bool, b::Bool)
            return length(gpack(Float64)[1]) + length(A) + (a & b)
        end
        drv(A::Vector{Float64}, a::Bool) = drv(A, a, false)
        drv(A::Vector{Float64}) = drv(A, true)
        @noinline mid(A::Vector{Float64}) = drv(A) + 1
        top(A::Vector{Float64}) = mid(A) + 1
        @strict_function topf(A::Vector{Float64}) = mid(A) + 1
        end
        """
    end
    # The child process sees this test's own environment (which holds StrictMode) and the package's directory.
    function precompile_output(register)
        write(joinpath(dir, "FixPkg", "src", "FixPkg.jl"), source(register))
        julia = Base.julia_cmd()
        out = IOBuffer()
        code = "using StrictMode; Base.compilecache(Base.identify_package(\"FixPkg\"))"
        env = Dict(
            "JULIA_LOAD_PATH" => join(["@", dir, "@stdlib"], Sys.iswindows() ? ";" : ":"),
            "JULIA_DEPOT_PATH" => join(Base.DEPOT_PATH, Sys.iswindows() ? ";" : ":")
        )
        cmd = setenv(`$julia --startup-file=no --project=$(Base.active_project()) -e $code`, merge(Dict(ENV), env))
        run(pipeline(cmd; stdout = out, stderr = out))
        return String(take!(out))
    end
    without = precompile_output(false)
    @test occursin("allocates / boxes", without)
    @test occursin("first at", without)
    with = precompile_output(true)
    @test !occursin("allocates / boxes", with)
end

@testitem "the scan's entry points do not compile a method per checked target" begin
    using StrictMode
    for k in 1:8
        @eval begin
            struct $(Symbol(:Tg, k))
                a::Float64
            end
            @noinline $(Symbol(:hh, k))(s::$(Symbol(:Tg, k)), i::Int) = s.a * i
            $(Symbol(:gg, k))(s::$(Symbol(:Tg, k)), n::Int) = $(Symbol(:hh, k))(s, n) + 1.0
        end
    end
    specs(f) = sum((length(collect(Base.specializations(m))) for m in methods(f)); init = 0)
    watched = (
        StrictMode._code_typed, StrictMode._code_typed_by_type, StrictMode._return_types,
        StrictMode._infer_effects, StrictMode._sigtype, StrictMode._typed_body,
    )
    check(g, T) = for gs in (:typestable, :noalloc, :noboxing, :owned, :inlined)
        StrictMode.findings(g, (T, Int); guarantees = (gs,))
    end
    check(gg1, Tg1); check(gg2, Tg2)
    before = sum(specs, watched)
    for (g, T) in ((gg3, Tg3), (gg4, Tg4), (gg5, Tg5), (gg6, Tg6), (gg7, Tg7), (gg8, Tg8))
        check(g, T)
    end
    @test sum(specs, watched) - before <= length(watched)
    # Outside a package precompile nothing is taken back.
    @test StrictMode._window_open() == -1
    @test isnothing(StrictMode._window_close(-1))
    @test isnothing(StrictMode._window_close(typemax(Int)))
end

@testitem "the scan's inference leaves nothing in method roots or backedges" begin
    using StrictMode
    # `h` is inlineable and inlines `m`, so its body names `g`'s CodeInstance without an edge to it:
    # the shape that a compressed body roots. The tuple destructure is constant-propagated.
    @noinline function g(v::Vector{Float64})
        s = 0.0
        for x in v
            s += x
        end
        return s
    end
    @inline m(v::Vector{Float64}) = g(v) + 1.0
    h(v::Vector{Float64}) = m(v) * 2.0
    top(v::Vector{Float64}) = ((a, b) = (h(v), 2.0); a + b + h(v))
    isscan(x) = x isa Core.CodeInstance && x.owner isa StrictMode._ScanCacheOwner
    bes(mi) = isdefined(mi, :backedges) && !isnothing(mi.backedges) ? mi.backedges : Any[]
    function scan_refs()
        n = 0
        Base.visit(Core.methodtable) do meth
            isdefined(meth, :roots) && !isnothing(meth.roots) && (n += count(isscan, meth.roots))
            for mi in Base.specializations(meth)
                n += count(isscan, bes(mi))
            end
        end
        return n
    end
    StrictMode.clear_cache!()
    for gs in (:typestable, :noalloc, :noboxing, :owned, :inlined)
        StrictMode.findings(top, (Vector{Float64},); guarantees = (gs,))
    end
    StrictMode._code_typed(top, (Vector{Float64},))
    @test !isempty(StrictMode._SCAN_CODE_CACHE.entries)
    @test iszero(scan_refs())
    # A cached result answers only in the world it was inferred in. `top` has never run, so the
    # compiler holds no record of it to answer in its place.
    w = StrictMode._SCAN_CODE_CACHE.world[]
    mi = StrictMode._sig_instance(Tuple{typeof(top), Vector{Float64}}, w)
    @test haskey(StrictMode._SCAN_CODE_CACHE.entries, mi)
    @test !isnothing(StrictMode._scan_cache_lookup(StrictMode._SCAN_CODE_CACHE, mi, (w, w)))
    @test isnothing(StrictMode._scan_cache_lookup(StrictMode._SCAN_CODE_CACHE, mi, (w + 1, w + 1)))
end

@testitem "the scan infers a body once and takes Base from the compiler's own cache" begin
    using StrictMode
    @noinline function leaf(v::Vector{Float64})
        s = 0.0
        for x in v
            s += sin(x)
        end
        return s
    end
    mid(v::Vector{Float64}) = leaf(v) + 1.0
    grow(n::Int) = (a = Float64[]; push!(a, n); a)
    # One block, so one world: a new global binding starts a new world, and the cache answers for one.
    let
        StrictMode.clear_cache!()
        world = Base.get_world_counter()
        leafsig = Tuple{typeof(leaf), Vector{Float64}}
        @test only(StrictMode._return_types(mid, (Vector{Float64},))) === Float64
        # Inferring `mid` inferred `leaf` as its callee, and the body of that inference was kept.
        kept = StrictMode._scan_source(StrictMode._sig_instance(leafsig, world), world)
        @test kept isa Core.CodeInfo
        @test StrictMode._typed_body(leafsig) === kept
        @test length(kept.code) == length(first(only(StrictMode._code_typed_by_type(leafsig))).code)
        # A body read first is inferred into the cache, so the return type asked next is a lookup.
        midsig = Tuple{typeof(mid), Vector{Float64}}
        StrictMode.clear_cache!()
        body = StrictMode._typed_body(midsig)
        @test body isa Core.CodeInfo
        @test haskey(StrictMode._SCAN_CODE_CACHE.entries, StrictMode._sig_instance(midsig, world))
        @test StrictMode._typed_body(midsig) === body
        # `sin(::Float64)` is in the system image: the scan uses the compiler's record of it.
        sinmi = StrictMode._sig_instance(Tuple{typeof(sin), Float64}, world)
        rec = StrictMode._scan_cache_lookup(StrictMode._SCAN_CODE_CACHE, sinmi, (world, world))
        @test rec isa Core.CodeInstance && isnothing(rec.owner)
        @test !haskey(StrictMode._SCAN_CODE_CACHE.entries, sinmi)
        # The walk that words a warning scans a body once, however many warnings pass through it.
        first_walk = StrictMode._signal_origin(grow, (Int,))
        @test !isempty(first_walk)
        @test !isempty(StrictMode._ORIGIN_MEMO)
        again = StrictMode._signal_origin(grow, (Int,))
        @test [o.signature for o in again] == [o.signature for o in first_walk]
        @test all(i -> again[i].statements === first_walk[i].statements, eachindex(again))
        StrictMode.clear_cache!()
        @test isempty(StrictMode._ORIGIN_MEMO)
        @test isempty(StrictMode._SCAN_CODE_CACHE.sources)
    end
    @test StrictMode._sig_string((Int, Vector{Float64})) == "(Int64, Vector{Float64})"
    @test StrictMode._sig_string((Int, Vector{Float64})) == "(" * join((Int, Vector{Float64}), ", ") * ")"
end

@testitem "a @ccallable entry checked at its package's precompile is inferred by the compiler, once" begin
    using StrictMode
    dir = mktempdir()
    mkpath(joinpath(dir, "CcPkg", "src"))
    # The image compiles `ccp_sum_64_` whether or not anything calls it; `plain_sum_64_` it does not.
    write(
        joinpath(dir, "CcPkg", "src", "CcPkg.jl"), """
        module CcPkg
        using StrictMode
        @noinline function helper(p::Ptr{T}, n::Int) where {T}
            s = zero(T)
            for i in 1:n
                s += unsafe_load(p, i)
            end
            return s
        end
        Base.@ccallable function ccp_sum_64_(n::Ptr{Int}, x::Ptr{Float64})::Float64
            return helper(x, unsafe_load(n))
        end
        plain_sum_64_(n::Ptr{Int}, x::Ptr{Float32})::Float32 = helper(x, unsafe_load(n))
        @strict_policy (:typestable, :noalloc) only = r"_64_\$"
        for f in (ccp_sum_64_, plain_sum_64_)
            world = Base.get_world_counter()
            mi = StrictMode._sig_instance(only(methods(f)).sig, world)
            native = !isnothing(StrictMode._record_of(mi, world))
            recorded = any(ci -> ci isa Core.CodeInstance && ci.def === mi, Base.newly_inferred)
            println(stderr, "CCP ", nameof(f), " native=", native, " recorded=", recorded)
        end
        println(stderr, "CCP depth=", StrictMode._WINDOW_DEPTH[], " kept=", length(StrictMode._IMAGE_RECORDS))
        end
        """
    )
    julia = Base.julia_cmd()
    out = IOBuffer()
    code = "using StrictMode; Base.compilecache(Base.identify_package(\"CcPkg\"))"
    env = Dict(
        "JULIA_LOAD_PATH" => join(["@", dir, "@stdlib"], Sys.iswindows() ? ";" : ":"),
        "JULIA_DEPOT_PATH" => join(Base.DEPOT_PATH, Sys.iswindows() ? ";" : ":")
    )
    cmd = setenv(`$julia --startup-file=no --project=$(Base.active_project()) -e $code`, merge(Dict(ENV), env))
    run(pipeline(cmd; stdout = out, stderr = out))
    log = String(take!(out))
    # The compiler's record of the entry exists after the check and is still listed for the image,
    # although the check ran inside a window that takes the scan's own records back.
    @test occursin("CCP ccp_sum_64_ native=true recorded=true", log)
    @test occursin("CCP plain_sum_64_ native=false recorded=false", log)
    @test occursin("CCP depth=0 kept=0", log)
    @test !occursin("Warning", log)
end

@testitem "a call that waits in the task scheduler is its own kind of :noalloc finding" begin
    using StrictMode
    @noinline join_pool() = yield()
    @noinline mid(x::Int) = (join_pool(); x + 1)
    top(x::Int) = mid(x) + 1
    plain_alloc(n::Int) = (a = Float64[]; push!(a, n); a)
    f = only(StrictMode.findings(top, (Int,); guarantees = (:noalloc,)))
    # `yield` can allocate (a task queue grows, a work queue is created on first use), however many
    # scheduler calls down Base's inlining leaves that allocation.
    @test StrictMode._failed(f)
    @test f.code === :SM0017
    @test occursin("blocks in the task scheduler", f.reason)
    @test occursin("join_pool", f.reason) || occursin("yield", f.reason)
    @test occursin("register_alloc_barrier!", f.suggestion) && occursin("@strict_exempt", f.suggestion)
    # scheduler code that allocates nothing passes: a `SpinLock` only spins
    spin(l::Threads.SpinLock) = (lock(l); unlock(l); nothing)
    @test !StrictMode._failed(only(StrictMode.findings(spin, (Threads.SpinLock,); guarantees = (:noalloc,))))
    @test occursin("scheduler", StrictMode.explain(:SM0017))
    # an allocation that is not in the scheduler stays an ordinary :noalloc finding
    g = only(StrictMode.findings(plain_alloc, (Int,); guarantees = (:noalloc,)))
    @test StrictMode._failed(g) && g.code === :SM0002
    # excusing the join by name takes it out of the verdict
    try
        register_alloc_barrier!(join_pool)
        @test !StrictMode._failed(only(StrictMode.findings(top, (Int,); guarantees = (:noalloc,))))
    finally
        empty!(StrictMode._ALLOC_BARRIERS)
        let st = StrictMode._store_for(Main, :__strict_barriers__)
            isnothing(st) || empty!(st)
        end
        StrictMode._BARRIER_GEN[] += 1
        StrictMode.clear_cache!()
    end
end

@testitem "unlocking a ReentrantLock is a scheduler finding in every scan mode" begin
    using StrictMode
    # `unlock` wakes a waiter: `schedule` stores the task's result through an abstract field before
    # it queues the task, and the queue can grow (`Base.Partr`).
    ul(l::ReentrantLock) = (unlock(l); nothing)
    trl(l::ReentrantLock) = (trylock(l) && unlock(l); nothing)
    T = (ReentrantLock,)
    for f in (ul, trl)
        @test StrictMode._alloc_signals(f, T; mode = :alloc).alloc
        @test StrictMode._alloc_signals(f, T; mode = :full).alloc
        r = only(StrictMode.findings(f, T; guarantees = (:noalloc,)))
        @test StrictMode._failed(r) && r.code === :SM0017
    end
    # below the Base depth (`depth = -1`) the scheduler is still followed, `Base.Partr` included:
    # `enq_work` allocates only in `Partr.multiq_insert` on some releases
    @test StrictMode._alloc_signals(Base.enq_work, (Task,); mode = :alloc, depth = -1).alloc
    # a lock that only spins still passes
    spin(l::Threads.SpinLock) = (lock(l); unlock(l); nothing)
    @test !StrictMode._failed(only(StrictMode.findings(spin, (Threads.SpinLock,); guarantees = (:noalloc,))))
end

@testitem "the function given to lock is the caller's code, whoever defined it" begin
    using StrictMode
    noalloc(f, T) = only(StrictMode.findings(f, T; guarantees = (:noalloc,)))
    noboxing(f, T) = only(StrictMode.findings(f, T; guarantees = (:noboxing,)))
    R = ReentrantLock
    # an allocation in the callable is the caller's, whether the callable's type is Base's or a closure
    fix_under_lock(l::ReentrantLock, n::Int) = lock(Base.Fix1(zeros, n), l)
    closure_under_lock(l::ReentrantLock, n::Int) = lock(() -> zeros(n), l)
    for f in (fix_under_lock, closure_under_lock)
        r = noalloc(f, (R, Int))
        @test StrictMode._failed(r) && r.code === :SM0002
    end
    # so is one several Base calls down from the callable
    sort_under_lock(l::ReentrantLock, v::Vector{Float64}) = lock(Base.Fix1(sort!, v), l)
    r = noalloc(sort_under_lock, (R, Vector{Float64}))
    @test StrictMode._failed(r) && r.code === :SM0002
    # boxing in the callable is the caller's boxing
    box_under_lock(l::ReentrantLock, v::Vector{Any}, x::Int) = (lock(() -> push!(v, x), l); nothing)
    @test StrictMode._failed(noboxing(box_under_lock, (R, Vector{Any}, Int)))
    # the lock's own wait is the scheduler's, and so is a wait the callable makes
    plain(l::ReentrantLock) = (lock(l); unlock(l); nothing)
    wait_under_lock(l::ReentrantLock, c::Threads.Condition) = lock(Base.Fix1(wait, c), l)
    @test noalloc(plain, (R,)).code === :SM0017
    @test noalloc(wait_under_lock, (R, Threads.Condition)).code === :SM0017
    # a keyword body is handed its own function as an argument; that is not a callable to run
    condwait(c::Threads.Condition) = (lock(c); try wait(c) finally unlock(c) end; nothing)
    chtake(ch::Channel{Int}) = take!(ch)
    @test noalloc(condwait, (Threads.Condition,)).code === :SM0017
    @test noalloc(chtake, (Channel{Int},)).code === :SM0017
    @test !StrictMode._failed(noboxing(plain, (R,)))
end

@testitem "a wait is SM0017 only when the call reaches no allocation outside the scheduler" begin
    using StrictMode
    @noinline join_pool() = yield()
    only_waits(x::Int) = (join_pool(); x + 1)
    wait_then_alloc(n::Int) = (join_pool(); zeros(n))
    # `sort!` allocates its scratch several Base calls down, past the depth the verdict reads to.
    wait_then_sort(v::Vector{Float64}) = (join_pool(); sort!(v))
    tv = (Vector{Float64},)
    @test isnothing(StrictMode._nonscheduler_origin(only_waits, (Int,)))
    @test occursin("Sort", string(StrictMode._nonscheduler_origin(wait_then_sort, tv).signature))
    g = only(StrictMode.findings(wait_then_alloc, (Int,); guarantees = (:noalloc,)))
    @test StrictMode._failed(g) && g.code === :SM0002
    # the package's code run by the lock is not the scheduler's, nor is what that code calls
    alloc_under_lock(l::ReentrantLock, n::Int) = lock(() -> zeros(n), l)
    h = only(StrictMode.findings(alloc_under_lock, (ReentrantLock, Int); guarantees = (:noalloc,)))
    @test StrictMode._failed(h) && h.code === :SM0002
    # Whether `yield` reaches an allocation depends on Base's implementation of it; the rest needs one.
    if StrictMode._alloc_signals(only_waits, (Int,)).alloc
        @test only(StrictMode.findings(only_waits, (Int,); guarantees = (:noalloc,))).code === :SM0017
        f = only(StrictMode.findings(wait_then_sort, tv; guarantees = (:noalloc,)))
        @test StrictMode._failed(f) && f.code === :SM0002
        @test !occursin("blocks in the task scheduler", f.reason)
        @test isnothing(StrictMode._scheduler_origin(wait_then_sort, tv))
        # the warning names the allocation, not the wait the walk met first
        msg = StrictMode._alloc_message(
            wait_then_sort, tv, StrictMode._alloc_signals(wait_then_sort, tv; mode = :alloc), "allocates / boxes"
        )
        @test startswith(msg, "SM0002") && occursin("Sort", msg)
        # a walk that cannot finish has not shown that the call only waits
        budget = StrictMode._SCAN_BODY_BUDGET[]
        try
            StrictMode._SCAN_BODY_BUDGET[] = 1
            @test ismissing(StrictMode._nonscheduler_origin(only_waits, (Int,)))
            @test isnothing(StrictMode._scheduler_origin(only_waits, (Int,)))
        finally
            StrictMode._SCAN_BODY_BUDGET[] = budget
        end
    end
end

@testitem "the call-site and load-time :noalloc warnings name a scheduler wait" begin
    using StrictMode
    @noinline join_pool() = yield()
    @noinline mid(x::Int) = (join_pool(); x + 1)
    top(x::Int) = mid(x) + 1
    # Where this Julia's `yield` reaches an allocation the scan reports it; where it does not, nothing to name.
    if StrictMode._alloc_signals(top, (Int,)).alloc
        so = StrictMode._scheduler_origin(top, (Int,))
        @test !isnothing(so)
        @test_logs (:warn, r"SM0017.*blocks in the task scheduler.*\. If the wait.*register_alloc_barrier!") StrictMode._strict_scan("t", top, (Int,))
        @test_logs (:warn, r"SM0017.*blocks in the task scheduler") StrictMode._assert_noalloc_scan("t", top, (Int,))
    end
    # an allocation elsewhere keeps the ordinary wording, with its own code
    grow(n::Int) = (a = Float64[]; push!(a, n); a)
    @test_logs (:warn, r"SM0002 allocates / boxes") StrictMode._assert_noalloc_scan("t", grow, (Int,))
end

@testitem "a boxing store is found in a followed callee and not in the scheduler's code" begin
    using StrictMode, StrictModeTest
    # Three of the package's own helpers down, below the depth the scan reads Base to.
    @noinline store3!(r, x) = (r[] = x; nothing)
    @noinline store2!(r, x) = (store3!(r, x); nothing)
    @noinline store1!(r, x) = (store2!(r, x); nothing)
    deep_store!(r::Base.RefValue{Any}, x::Float64) = store1!(r, x)
    deep_typed!(r::Base.RefValue{Float64}, x::Float64) = store1!(r, x)
    boxes(f, T; mode) = StrictMode._alloc_signals(f, T; mode).boxing
    for mode in (:boxing, :alloc, :full)
        @test boxes(deep_store!, (Base.RefValue{Any}, Float64); mode)
        @test !boxes(deep_typed!, (Base.RefValue{Float64}, Float64); mode)
    end
    @test StrictMode._failed(only(findings(deep_store!, (Base.RefValue{Any}, Float64); guarantees = (:noboxing,))))

    # `put!` hands an `Int` to a waiting task through `Task.result`, an `Any` field. The store is in
    # `schedule` (task.jl), which is the scheduler's code: neither tier counts it.
    hand_over(c::Channel{Int}, x::Int) = (put!(c, x); nothing)
    @test !StrictMode._failed(only(findings(hand_over, (Channel{Int}, Int); guarantees = (:noboxing,))))
    # A statement inlined from the scheduler's code is the scheduler's too. `t.result = x` inlines
    # `setproperty!(::Task, …)` from task.jl, so the proof reads its box as a scheduler site.
    own_result!(t::Task, x::Int) = (t.result = x; nothing)
    sig = Tuple{typeof(own_result!), Task, Int}
    ci = StrictMode._typed_body(sig)
    stores = [
        i for (i, st) in pairs(ci.code)
            if st isa Expr && StrictMode._boxing_store(ci, sig, st, StrictMode._static_callee(ci, st.args[1]))
    ]
    @test !isempty(stores) && all(i -> StrictMode._stmt_in_scheduler(ci, sig, i), stores)
    @test !StrictMode._failed(only(findings(own_result!, (Task, Int); guarantees = (:noboxing,))))
    @test !StrictMode._failed(only(proof_findings(own_result!, (Task, Int); guarantees = (:noboxing,))))
    sig3 = Tuple{typeof(store3!), Base.RefValue{Any}, Float64}
    ci = StrictMode._typed_body(sig3)
    @test !any(i -> StrictMode._stmt_in_scheduler(ci, sig3, i), eachindex(ci.code))
end
