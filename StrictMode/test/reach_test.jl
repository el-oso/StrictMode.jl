# Which functions a call reaches after optimization, and whether two entries reach the same ones.
# The model is a shared core with defaults: one entry chooses a route, the other takes the defaults.

@testmodule ReachModel begin
    module Routes
    @noinline serial(x) = sum(x)
    @noinline deep(x) = prod(x)
    @inline tune(x) = length(x) * 2
    @noinline threaded(x) = (t = Threads.@spawn deep(x); fetch(t) + tune(x))
    @noinline strassen(x) = sum(x) * 2
    @inline function core(x; workers::Int = 1, strassen_on::Bool = false)
        strassen_on && return strassen(x)
        return workers > 1 ? threaded(x) + tune(x) : serial(x)
    end
    @inline choose(x) = length(x) > 100 ? Threads.nthreads() : 1
    native(x) = core(x; workers = choose(x), strassen_on = length(x) > 1000)
    cabi(x) = core(x)
    kwentry(x; scale = 1.0) = core(x) * scale

    # A callee the scan cannot name.
    @noinline hidden(x) = x + 1
    viaref(r::Base.RefValue{Any}, x) = r[](x)
    leaf(x) = x
    end
    const V = (Vector{Float64},)
end

@testitem "reach_report reads the graph after optimization" setup = [ReachModel] begin
    using StrictMode
    R, V = ReachModel.Routes, ReachModel.V
    names(r) = Set(f.name for f in r.functions)

    # The entry that chooses a route reaches every branch, including the callee of a spawned task.
    rn = StrictMode.reach_report(R.native, V; mod = R)
    @test names(rn) == Set([:core, :choose, :tune, :serial, :threaded, :strassen, :deep])
    # `fetch` returns `Any`, and the `+` it feeds runs whatever method the task's value has, so the
    # graph is incomplete.
    @test rn.dynamic > 0
    @test !StrictMode.complete(rn)
    @test StrictMode.reaches(rn, R.threaded)

    # The entry that takes the defaults reaches the core and the one branch the defaults leave.
    # `core` is inlined, so it is read from the inlining edges rather than from a call.
    rc = StrictMode.reach_report(R.cabi, V; mod = R)
    @test names(rc) == Set([:core, :serial])
    @test !StrictMode.reaches(rc, R.threaded)
    @test !StrictMode.reaches(rc, R.tune)

    # A keyword entry is read through `Core.kwcall`, and its body function counts as the function.
    rk = StrictMode.reach_report(
        Core.kwcall, (@NamedTuple{scale::Float64}, typeof(R.kwentry), Vector{Float64}); mod = R
    )
    @test names(rk) == Set([:kwentry, :core, :serial])

    # `stop` records a function without entering it.
    rs = StrictMode.reach_report(R.native, V; mod = R, stop = (R.threaded,))
    @test StrictMode.reaches(rs, R.threaded)
    @test !StrictMode.reaches(rs, R.deep)

    # Without `mod` the walk's Base helpers are listed too.
    @test length(StrictMode.reach_report(R.native, V).functions) > length(rn.functions)

    # A callee that is a run-time value is counted, and the report says the list is a lower bound.
    rv = StrictMode.reach_report(R.viaref, (Base.RefValue{Any}, Int); mod = R)
    @test !StrictMode.reaches(rv, R.hidden)
    @test isone(rv.dynamic)
    @test !StrictMode.complete(rv)
    @test occursin("lower bound", sprint(show, rv))

    @test_throws "no method matches" StrictMode.reach_report(R.native, (Int, Int))
end

@testitem "route_parity names what only one entry reaches" setup = [ReachModel] begin
    using StrictMode
    R, V = ReachModel.Routes, ReachModel.V

    p = StrictMode.route_parity(R.native => V, R.cabi => V; mod = R)
    @test StrictMode.status(p) === :differ
    @test Set(f.name for f in p.only_a) == Set([:choose, :tune, :threaded, :strassen, :deep])
    @test isempty(p.only_b)
    # Nearest first: what the route decision calls comes before what lies behind it.
    @test last(p.only_a).name === :deep
    out = sprint(show, p)
    @test occursin("only native", out)
    @test occursin("threaded", out)
    @test !occursin("same route", out)

    # Two entries that take the defaults agree, and the entries themselves are not compared.
    q = StrictMode.route_parity(R.cabi => V, R.kwentry => V; mod = R)
    @test StrictMode.status(q) === :agree
    @test occursin("same route", sprint(show, q))

    # No difference in what was read is not agreement when a graph is empty or partly unread.
    u = StrictMode.route_parity(R.viaref => (Base.RefValue{Any}, Int), R.leaf => (Int,); mod = R)
    @test isempty(u.only_a) && isempty(u.only_b)
    @test StrictMode.status(u) === :incomplete
    @test occursin("not shown to agree", sprint(show, u))
    @test !occursin("same route", sprint(show, u))
    e = StrictMode.route_parity(R.leaf => (Int,), R.leaf => (Float64,); mod = R)
    @test StrictMode.status(e) === :incomplete
end

@testitem "@assert_reaches throws on a graph read in full and warns on one that was not" setup = [ReachModel] begin
    using StrictMode
    R = ReachModel.Routes
    x = rand(8)

    @test (@assert_reaches R.cabi(x) R.serial) == sum(x)
    @test (@assert_reaches R.native(x) R.threaded) == sum(x)
    @test (@assert_reaches R.kwentry(x; scale = 2.0) R.core) == 2 * sum(x)

    @test_throws "is not among" @assert_reaches R.cabi(x) R.threaded
    @test_throws StrictViolation @assert_reaches R.cabi(x) R.threaded

    # The target may sit behind the call the scan could not name, so this one is reported.
    r = Ref{Any}(R.hidden)
    @test_logs (:warn, r"unknown callee") match_mode = :any @assert_reaches R.viaref(r, 1) R.hidden
    # A route that fetches a task is incomplete, so an absent target warns there too.
    @test_logs (:warn, r"unknown callee") match_mode = :any @assert_reaches R.native(x) R.hidden

    @test StrictMode._code(:reaches) === :SM0015
end

@testitem "stop cuts a hub that was inlined into its caller" begin
    using StrictMode
    leaf_a(x) = x + 1
    leaf_b(x) = x + 2
    @noinline far_leaf(x) = x * 3
    @inline hub_in(k, x) = k == 1 ? leaf_a(x) : leaf_b(x)
    @inline hub_out(x) = far_leaf(x)          # inlined, with an out-of-line callee
    via_in(k, x) = hub_in(k, x)
    via_out(x) = hub_out(x)
    via_in(1, 1); via_out(1)
    R(f, t, s) = reach_report(f, t; stop = s)
    @test StrictMode.reaches(R(via_in, (Int, Int), ()), leaf_a)
    @test !StrictMode.reaches(R(via_in, (Int, Int), (hub_in,)), leaf_a)
    @test StrictMode.reaches(R(via_in, (Int, Int), (hub_in,)), hub_in)   # recorded, not entered
    @test StrictMode.reaches(R(via_out, (Int,), ()), far_leaf)
    @test !StrictMode.reaches(R(via_out, (Int,), (hub_out,)), far_leaf)
end

@testitem "reach enters a Base callee that runs a user type's methods" begin
    using StrictMode
    # `sum` stays an out-of-line call into Base, and reaches `hot` only through `getindex(::Lazy)`.
    abstract type AbstractLazy <: AbstractVector{Float64} end
    struct Lazy <: AbstractLazy
        v::Vector{Float64}
    end
    Base.size(l::Lazy) = size(l.v)
    @noinline hot(x) = 2x
    Base.getindex(l::Lazy, i::Int) = hot(l.v[i])
    entry(l::Lazy) = sum(l)
    @test entry(Lazy([1.0, 2.0])) == 6.0
    r = StrictMode.reach_report(entry, (Lazy,))
    @test StrictMode.reaches(r, hot)
    @test (@assert_reaches entry(Lazy([1.0])) hot) == 2.0
    @test StrictMode.reaches(StrictMode.reach_report(entry, (Lazy,); stop = (hot,)), hot)

    # A Base call left to run-time dispatch on a user type is followed, or counted.
    viaref(r::Base.RefValue{AbstractLazy}) = sum(r[])
    @test viaref(Ref{AbstractLazy}(Lazy([1.0]))) == 2.0
    rd = StrictMode.reach_report(viaref, (Base.RefValue{AbstractLazy},))
    @test StrictMode.reaches(rd, hot) || !StrictMode.complete(rd)
end

@testitem "a Base call on abstract argument types is counted as unread" begin
    using StrictMode
    # User code runs behind each of these Base calls at run time, through a value whose type the
    # signature leaves abstract. The walk does not enter Base, so it counts the call instead.
    @noinline hot(x) = 2x
    struct L <: AbstractVector{Float64}
        v::Vector{Float64}
    end
    Base.size(l::L) = size(l.v)
    Base.getindex(l::L, i::Int) = hot(l.v[i])
    struct N
        v::Float64
    end
    Base.:+(a::N, b::Float64) = hot(a.v) + b
    viaabs(r::Base.RefValue{AbstractVector{Float64}}) = sum(r[])
    viafetch(x::Float64) = (t = Threads.@spawn N(x); fetch(t) + x)
    viaany(r::Base.RefValue{Any}, x::Float64) = r[] + x
    @test viaabs(Ref{AbstractVector{Float64}}(L([1.0]))) == 2.0
    @test viafetch(1.0) == 3.0
    @test viaany(Ref{Any}(N(1.0)), 1.0) == 3.0
    for (f, T) in ((viaabs, (Base.RefValue{AbstractVector{Float64}},)), (viafetch, (Float64,)),
                   (viaany, (Base.RefValue{Any}, Float64)))
        r = StrictMode.reach_report(f, T)
        @test !StrictMode.reaches(r, hot)
        @test r.dynamic > 0
        @test !StrictMode.complete(r)
    end
    # The target may sit behind the abstract call, so its absence warns rather than throws.
    a = Ref{AbstractVector{Float64}}(L([1.0]))
    @test_logs (:warn, r"unknown callee") match_mode = :any @assert_reaches viaabs(a) hot

    # A Base function on concrete Base types stays in Base and is not counted.
    conc(x::Vector{Float64}) = sum(x)
    rc = StrictMode.reach_report(conc, (Vector{Float64},))
    @test StrictMode.complete(rc)
    @test_throws StrictViolation @assert_reaches conc([1.0]) hot
    @test !StrictMode._reach_open(Tuple{typeof(sum), Vector{Float64}})
    @test !StrictMode._reach_open(Tuple{typeof(convert), Type{Int}, Union{Nothing, Int}})
    @test StrictMode._reach_open(Tuple{typeof(sum), AbstractVector{Float64}})
    @test StrictMode._reach_open(Tuple{typeof(+), Any, Float64})
    @test StrictMode._reach_open(Tuple{typeof(print), Vararg{Any}})
    @test !StrictMode._reach_open(Tuple{typeof(Base._string), String, Vararg{String}})

    # An :invoke is judged by the types at the call site, not by the method instance, which a
    # `@nospecialize` widens: interpolating an `Int` into an error message stays in Base, and
    # interpolating an `Any` does not.
    chk(x::Int) = x > 0 ? x : throw(ArgumentError("bad $x"))
    @test StrictMode.complete(StrictMode.reach_report(chk, (Int,)))
    s2(r::Base.RefValue{Any}) = string("a", r[])
    @test !StrictMode.complete(StrictMode.reach_report(s2, (Base.RefValue{Any},)))
end

@testitem "a struct's default show is read at the struct's type" begin
    using StrictMode
    # `show` of a struct without its own method runs Base's `_show_default`, compiled for `Any` and
    # called through a compiler barrier. The value is the struct, so it is read at that type.
    @noinline hot(x) = 2x
    struct W; v::Int; end
    Base.show(io::IO, w::W) = print(io, hot(w.v))
    struct Plain; a::Int; end
    struct Holds; w::W; end
    viaplain(p::Plain) = string(p)
    viaholds(h::Holds) = string(h)
    @test endswith(viaplain(Plain(1)), "Plain(1)")
    @test endswith(viaholds(Holds(W(1))), "Holds(2)")
    rp = StrictMode.reach_report(viaplain, (Plain,))
    @test rp.dynamic == 0
    @test StrictMode.complete(rp)
    rh = StrictMode.reach_report(viaholds, (Holds,))
    @test StrictMode.reaches(rh, hot)
end

@testitem "a Base call on a container of abstract elements is counted as unread" begin
    using StrictMode
    # A concrete Base container whose type parameter is abstract holds values of any type, and the
    # Base method runs their methods: `sum` of a `Vector{Any}` runs the `+` of whatever it holds.
    @noinline hot(x) = 2x
    struct N
        v::Float64
    end
    Base.:+(a::N, b::N) = N(hot(a.v) + b.v)
    vany(v::Vector{Any}) = sum(v)
    vnest(v::Vector{Vector{Any}}) = sum(first(v))
    @test vany(Any[N(1.0), N(1.0)]).v == 3.0
    @test vnest([Any[N(1.0), N(1.0)]]).v == 3.0
    for (f, T) in ((vany, (Vector{Any},)), (vnest, (Vector{Vector{Any}},)))
        r = StrictMode.reach_report(f, T)
        @test !StrictMode.reaches(r, hot)
        @test r.dynamic > 0
        @test !StrictMode.complete(r)
    end
    @test_logs (:warn, r"unknown callee") match_mode = :any @assert_reaches vany(Any[N(1.0)]) hot

    # Parameters are judged at every depth, and a parameter that is not a type is not judged.
    for T in (Vector{Any}, Dict{Symbol, Any}, Base.RefValue{Any}, Vector{Vector{Any}},
              Tuple{Vector{Any}}, Vector{AbstractVector{Float64}}, Vector{Vector})
        @test StrictMode._reach_open(Tuple{typeof(sum), T})
    end
    for T in (Vector{Float64}, Vector{Vector{Float64}}, Dict{Symbol, Int},
              Vector{Union{Nothing, Int}}, Val{:a}, Array{Float64, 2}, Vector{Type{Int}})
        @test !StrictMode._reach_open(Tuple{typeof(sum), T})
    end
end

@testitem "an invoke of a less specific Base method is not read as complete" begin
    using StrictMode
    @noinline hot(x) = 2x
    struct In end
    Base.show(io::IO, ::In) = print(io, hot(1))
    struct Out; x::In; end
    Base.show(io::IO, ::Out) = print(io, "O")
    # `invoke` selects Base's default `show`, compiled for `Any`, though `Out` has its own method.
    @noinline dflt(io::IOBuffer, o::Out) = (@noinline invoke(show, Tuple{IO, Any}, io, o))
    io = IOBuffer(); dflt(io, Out(In()))
    @test endswith(String(take!(io)), "Out(2)")
    r = StrictMode.reach_report(dflt, (IOBuffer, Out))
    @test StrictMode.reaches(r, hot) || !StrictMode.complete(r)
end

@testitem "reach_report reads the method a wider invoke runs" begin
    using StrictMode
    const SINK = Ref{Any}(nothing)
    @noinline hot(x) = (SINK[] = x; 2x)
    @noinline to_hot(x::Int, n::Integer) = hot(x)
    @noinline to_hot(x::Int, n::Int) = x
    @noinline past_hot(x::Int, n::Integer) = x + n
    @noinline past_hot(x::Int, n::Int) = hot(x)
    # `invoke` runs the `Integer` method on an `Int`; `(Int, Int)` dispatches to the other one.
    reaches_it(x::Int, n::Int) = invoke(to_hot, Tuple{Int, Integer}, x, n)
    misses_it(x::Int, n::Int) = invoke(past_hot, Tuple{Int, Integer}, x, n)
    @test reaches_it(1, 1) == 2 && misses_it(1, 1) == 2
    r = StrictMode.reach_report(reaches_it, (Int, Int))
    @test StrictMode.reaches(r, hot) && StrictMode.complete(r)
    r = StrictMode.reach_report(misses_it, (Int, Int))
    @test !StrictMode.reaches(r, hot) && StrictMode.complete(r)
end
