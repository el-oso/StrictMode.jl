@testitem "inline_suggestions flags a non-inlined callee called in a loop" begin
    using StrictMode

    @noinline cold_kernel(x) = x * x + 1.0          # NOT inlined → survives as :invoke
    function caller_loop(v::Vector{Float64})
        s = 0.0
        for x in v
            s += cold_kernel(x)                      # non-inlined call, inside a loop
        end
        return s
    end

    fs = inline_suggestions(caller_loop, (Vector{Float64},))
    @test !isempty(fs)
    f = only(filter(x -> occursin("cold_kernel", x.reason), fs))
    @test f.guarantee === :inline_suggestion
    @test f.status === :info
    @test nfailures(fs) == 0                          # informational, never a failure
    @test occursin("in a loop", f.reason)            # loop detection fired
    @test occursin("@inline", f.suggestion)
end

@testitem "inline_suggestions: an @inline callee produces no suggestion" begin
    using StrictMode

    @inline hot_kernel(x) = x * x + 1.0              # inlined → absorbed, no :invoke
    function caller_inlined(v::Vector{Float64})
        s = 0.0
        for x in v
            s += hot_kernel(x)
        end
        return s
    end

    fs = inline_suggestions(caller_inlined, (Vector{Float64},))
    @test isempty(filter(x -> occursin("hot_kernel", x.reason), fs))
end

@testitem "inline_suggestions flags a non-inlined @generated kernel in a loop (avx_colbf_prime shape)" begin
    using StrictMode

    # Mirror the PureFFT bug: a @generated codelet (NOT @inline) called in a runtime loop. The body
    # is O(N^2) so it deterministically exceeds the inliner's cost model and survives as an :invoke
    # (a tiny @generated body would be inlined anyway — the honest false-positive floor).
    @generated function colbf(t::NTuple{N, Float64}) where {N}
        ex = :(0.0)
        for i in 1:N, j in 1:N
            ex = :($ex + t[$i] * t[$j] * $(i * j) + muladd(t[$i], $(i + j), t[$j]))
        end
        return ex
    end
    function transform(cols::Vector{NTuple{16, Float64}})
        s = 0.0
        for c in cols
            s += colbf(c)                            # @generated, non-inlined, in a loop
        end
        return s
    end

    fs = inline_suggestions(transform, (Vector{NTuple{16, Float64}},))
    g = filter(x -> occursin("colbf", x.reason), fs)
    @test !isempty(g)
    f = first(g)
    @test occursin("@generated", f.reason)           # generated flag fired
    @test occursin("in a loop", f.reason)            # and loop flag
    @test f.status === :info
    # @generated-in-loop is top priority → sorted first when present.
    @test fs[1].status === :info
end

@testitem "inline_suggestions: only_flagged filters to @generated/in-loop callees" begin
    using StrictMode

    @noinline plain(x) = x + 1.0                     # non-inlined, but NOT in a loop, not @generated
    once(x::Float64) = plain(x)                      # single straight-line call

    all_fs = inline_suggestions(once, (Float64,); only_flagged = false)
    @test !isempty(filter(x -> occursin("plain", x.reason), all_fs))   # shown by default
    flagged = inline_suggestions(once, (Float64,); only_flagged = true)
    @test isempty(filter(x -> occursin("plain", x.reason), flagged))   # filtered out (unflagged)
end

@testitem "audit(Module; inline_suggest=true) surfaces suggestions without failing" begin
    using StrictMode

    module InlineDemo
    @noinline leaf(x) = x * x + 1.0
    function hot(v::Vector{Float64})
        s = 0.0
        for x in v
            s += leaf(x)
        end
        return s
    end
    end

    InlineDemo.hot([1.0, 2.0, 3.0])                  # warm a concrete specialization

    fs = audit(
        InlineDemo; inline_suggest = true, format = :text, io = devnull,
        only = r"hot|leaf"
    )
    @test any(x -> x.guarantee === :inline_suggestion && occursin("leaf", x.reason), fs)
    @test nfailures(fs) == 0                          # info findings never fail the audit
end
