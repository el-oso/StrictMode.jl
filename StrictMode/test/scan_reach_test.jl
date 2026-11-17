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
