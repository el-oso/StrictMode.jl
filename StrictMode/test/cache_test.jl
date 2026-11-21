@testitem "findings cache: hit on unchanged method, miss after redefinition" begin
    using StrictMode
    clear_cache!()
    g(x::Int) = x + 1
    findings(g, (Int,); guarantees = (:typestable,))    # miss → fills cache
    findings(g, (Int,); guarantees = (:typestable,))    # hit
    s = cache_stats()
    @test s.hits ≥ 1
    @test s.misses ≥ 1

    @eval g(x::Int) = x + 2                              # "edit" → fresh Method identity
    findings(g, (Int,); guarantees = (:typestable,))    # miss again (auto-invalidated)
    @test cache_stats().misses ≥ 2

    clear_cache!()
    @test cache_stats() == (; entries = 0, hits = 0, misses = 0)
end

@testitem "clear_cache! empties the cache" begin
    using StrictMode
    h(x::Int) = 2x
    findings(h, (Int,); guarantees = (:typestable,))
    @test cache_stats().entries ≥ 1
    clear_cache!()
    @test cache_stats().entries == 0
end

@testitem "a cached verdict is invalidated when a CALLEE changes" begin
    using StrictMode

    # The cache key names the checked method, which an edit one level down leaves identical: the
    # `Method` object and its `primary_world` are untouched. Before, that returned a stale `:pass`
    # for a caller whose callee had started allocating — a cache that lies in the quiet direction.
    cb_callee(x::Int) = x + 1
    cb_caller(x::Int) = cb_callee(x) * 2
    cb_caller(1)
    StrictMode.clear_cache!()

    @test only(StrictMode.findings(cb_caller, (Int,); guarantees = (:noalloc,))).status === :pass
    before = StrictMode.cache_stats()
    @test only(StrictMode.findings(cb_caller, (Int,); guarantees = (:noalloc,))).status === :pass
    @test StrictMode.cache_stats().hits == before.hits + 1      # caching still works

    @eval cb_callee(x::Int) = [x][1] + 1                        # only the callee changes
    Base.@invokelatest cb_caller(1)
    cached = only(Base.@invokelatest StrictMode.findings(cb_caller, (Int,); guarantees = (:noalloc,)))

    StrictMode.clear_cache!()
    fresh = only(Base.@invokelatest StrictMode.findings(cb_caller, (Int,); guarantees = (:noalloc,)))

    # The cached answer must agree with the uncached one. Asserting agreement rather than `:fail`
    # keeps the test honest if the scan's verdict for this shape ever changes.
    @test cached.status === fresh.status
    @test cached.status === :fail

    StrictMode.clear_cache!()
end

@testitem "a verdict follows a redefined method or callee, in both directions" begin
    using StrictMode

    const RD_SINK = Any[]
    rd_clean(x::Int) = x + 1
    rd_allocating(x::Int) = (push!(RD_SINK, x); x + 1)
    rd_stable(x::Int) = x + 1
    rd_generic(x) = x + 1
    @noinline rd_callee(x::Int) = x + 1
    rd_caller(x::Int) = rd_callee(x) + rd_callee(x)
    @noinline rd_callee_cold(x::Int) = x + 1
    rd_caller_cold(x::Int) = rd_callee_cold(x) + rd_callee_cold(x)
    # Everything but `rd_caller_cold` is compiled, so the compiler holds a record of it that
    # outlives the edit; `rd_caller_cold` is the method with no compiled code to watch.
    rd_clean(1); rd_allocating(1); rd_stable(1); rd_generic(1); rd_caller(1)
    status(f, g) = only(findings(f, (Int,); guarantees = (g,))).status

    @test status(rd_clean, :noalloc) === :pass
    @test status(rd_allocating, :noalloc) === :fail
    @test status(rd_stable, :typestable) === :pass
    @test status(rd_generic, :noalloc) === :pass
    @test status(rd_caller, :noalloc) === :pass
    @test status(rd_caller_cold, :noalloc) === :pass

    @eval rd_clean(x::Int) = (push!(RD_SINK, x); x + 1)
    @eval rd_allocating(x::Int) = x + 1
    @eval rd_stable(x::Int) = x > 0 ? 1 : "s"
    @eval rd_generic(x::Int) = (push!(RD_SINK, x); x + 1)      # a more specific method takes over
    @eval @noinline rd_callee(x::Int) = (push!(RD_SINK, x); x + 1)
    @eval @noinline rd_callee_cold(x::Int) = (push!(RD_SINK, x); x + 1)

    @test status(rd_clean, :noalloc) === :fail
    @test status(rd_allocating, :noalloc) === :pass
    @test status(rd_stable, :typestable) === :fail
    @test status(rd_generic, :noalloc) === :fail
    @test status(rd_caller, :noalloc) === :fail
    @test status(rd_caller_cold, :noalloc) === :fail

    @eval @noinline rd_callee(x::Int) = x + 1                  # and back
    @test status(rd_caller, :noalloc) === :pass
end

@testitem "a cached verdict follows a function called only inside a spawned task" begin
    using StrictMode
    # A task's body is reached through `jl_new_task`, not a call, so the checked method's compiled
    # code holds no edge to what the task calls and an edit there does not invalidate it.
    tk_helper!(v) = nothing
    tk_run(v::Vector{Int}) = (t = Threads.@spawn tk_helper!(v); wait(t); nothing)
    tk_run([1])
    StrictMode.clear_cache!()
    verdict() = only(findings(tk_run, (Vector{Int},); guarantees = (:concurrency_safe,)))
    @test !StrictMode._failed(verdict())
    @eval tk_helper!(v) = (v[1] = 0; nothing)
    Base.@invokelatest tk_run([1])
    @test StrictMode._failed(Base.@invokelatest verdict())
end

@testitem "a cached verdict follows a registration a loaded package holds" begin
    using StrictMode
    # A package that holds a scoped-type store registers nothing when it loads: the store is read
    # from its module. Loading it changes `:noescape` verdicts without a registration call.
    mutable struct LdHandle
        p::Ptr{Cvoid}
    end
    const LD_KEPT = Ref{Any}(nothing)
    ld_leak(p::Ptr{Cvoid}) = (LD_KEPT[] = LdHandle(p); nothing)
    ld_leak(C_NULL)
    StrictMode.clear_cache!()
    verdict() = only(findings(ld_leak, (Ptr{Cvoid},); guarantees = (:noescape,)))
    @test !StrictMode._failed(verdict())
    ldstore = mktempdir() do dir
        mkpath(joinpath(dir, "LdStore", "src"))
        write(
            joinpath(dir, "LdStore", "src", "LdStore.jl"),
            "__precompile__(false)\nmodule LdStore\nconst $(StrictMode._LOCAL_SCOPED) = Any[$(repr(LdHandle))]\nend\n"
        )
        oldload = copy(Base.LOAD_PATH)
        try
            push!(Base.LOAD_PATH, dir)
            Base.require(Main, :LdStore)
        finally
            empty!(Base.LOAD_PATH)
            append!(Base.LOAD_PATH, oldload)
        end
    end
    @test StrictMode._failed(Base.@invokelatest verdict())
    # A loaded package cannot be unloaded, and its store stays in every later reader's union: empty
    # it, and the memoized union read from it, so later items see the session's registrations only.
    empty!(getfield(ldstore, StrictMode._LOCAL_SCOPED))
    empty!(StrictMode._REGISTRATION_MEMO)
    @test !StrictMode._is_scoped_type(LdHandle)
end

@testitem "a cached verdict follows an exemption taken back" begin
    using StrictMode
    module ExTakenBack
    @noinline helper(n) = zeros(n)
    caller(n::Int) = sum(helper(n))
    end
    E = ExTakenBack
    E.caller(3)
    verdict() = only(findings(E.caller, (Int,); guarantees = (:noalloc,)))
    # Control: with no exemption the allocation is a failure.
    @test StrictMode._failed(verdict())
    StrictMode._exempt!(:helper; guarantees = (:noalloc,))
    @test verdict().status === :info
    empty!(StrictMode.exempt_strict())
    @test StrictMode._failed(verdict())
    # The same number of exemptions, but a different one: the content decides, not the count.
    push!(StrictMode.exempt_strict(), StrictMode.Exemption(:helper, nothing, (:noalloc,), "", "", 0, nothing))
    @test verdict().status === :info
    StrictMode.exempt_strict()[1] = StrictMode.Exemption(:other, nothing, (:noalloc,), "", "", 0, nothing)
    @test StrictMode._failed(verdict())
    # A module's own exemption, removed with `clear_declarations!`.
    StrictMode._exempt!(:helper, E; guarantees = (:noalloc,))
    @test verdict().status === :info
    StrictMode.clear_declarations!()
    @test StrictMode._failed(verdict())
end
