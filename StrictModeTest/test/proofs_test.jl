# The proof primitives: AllocCheck, JET and TrimCheck as StrictModeTest drives them. StrictMode
# cannot test any of this, because it does not depend on those packages at all.

@testitem "loading requires checks to be enabled" begin
    using StrictMode, StrictModeTest
    # Anti-vacuity: with checks disabled every `@assert_*` is a bare call, nothing registers, and
    # `test_registered()` would sweep an empty registry and pass. `__init__` refuses to load in that
    # state, so reaching this line at all is the assertion — state it anyway.
    @test StrictMode.checks_enabled()
    @test StrictMode.proofs_loaded()
end

@testitem "the negative fixtures are still negative" setup = [Fixtures] begin
    using StrictMode
    # Every assertion elsewhere that says "the proof flags this" rests on these two fixtures
    # actually exhibiting the defect. An optimizer that elides `allocs`, or a `boxy` that stops
    # boxing, turns those assertions into tautologies while the suite stays green — the failure mode
    # that has recurred most often in this repo.
    Fixtures.allocs(4)
    Fixtures.boxy((1, 2.0, 3.0f0))
    @test @allocated(Fixtures.allocs(4)) > 0
    @test StrictMode._alloc_signals(Fixtures.boxy, Fixtures.THET).boxing
end

@testitem "the AllocCheck primitive finds real allocations and clears clean code" setup = [Fixtures] begin
    using StrictModeTest
    @test isempty(StrictModeTest._raw_allocs(Fixtures.clean, Fixtures.T3))
    @test !isempty(StrictModeTest._raw_allocs(Fixtures.allocs, (Int,)))
end

@testitem "_is_boxing separates boxing from a plain typed allocation" setup = [Fixtures] begin
    using StrictModeTest
    # Runtime-indexing a heterogeneous tuple boxes; allocating a Vector does not.
    boxing_insts = StrictModeTest._raw_allocs(Fixtures.boxy, Fixtures.THET)
    @test !isempty(boxing_insts)
    @test any(StrictModeTest._is_boxing, boxing_insts)
    @test !any(StrictModeTest._is_boxing, StrictModeTest._raw_allocs(Fixtures.allocs, (Int,)))
end

@testitem "the AllocCheck primitive honors ignore_throw" begin
    using StrictMode, StrictModeTest
    # A bounds-check throw branch is an allocation site AllocCheck can see; ignore_throw (the
    # default) must exclude it, since it is not on the hot path.
    sum_unchecked(a::Vector{Float64}, n::Int) = (
        s = 0.0; for i in 1:n
            s += a[i]
        end; s
    )
    A = rand(8)
    sum_unchecked(A, 8)
    old = StrictMode.ignore_throw()
    try
        StrictMode.set_ignore_throw!(true)
        @test isempty(StrictModeTest._raw_allocs(sum_unchecked, (Vector{Float64}, Int)))
        StrictMode.set_ignore_throw!(false)
        @test !isempty(StrictModeTest._raw_allocs(sum_unchecked, (Vector{Float64}, Int)))
    finally
        StrictMode.set_ignore_throw!(old)
        StrictMode.clear_cache!()
    end
end

@testitem "the JET primitive reports internal dispatch" setup = [Fixtures] begin
    using StrictModeTest
    @test isempty(StrictModeTest._opt_reports("clean", Fixtures.clean, Fixtures.T3))
    dispatchy(x) = (v = Any[1, 2.0]; sum(a -> a + x, v))
    dispatchy(1)
    @test !isempty(StrictModeTest._opt_reports("dispatchy", dispatchy, (Int,)))
end

@testitem "_trim_validate returns (passed, findings)" setup = [Fixtures] begin
    using StrictModeTest
    passed, findings = StrictModeTest._trim_validate(Fixtures.clean, Tuple{NTuple{3, Float64}, NTuple{3, Float64}})
    @test passed
    @test isempty(findings)
    # It also accepts a plain tuple of types, which is the other shape it is called with.
    p2, _ = StrictModeTest._trim_validate(Fixtures.clean, Fixtures.T3)
    @test p2 === passed
    # A non-inferrable signature is reported, not thrown.
    bad, why = StrictModeTest._trim_validate(identity, (Any,))
    @test bad isa Bool
    @test why isa Vector{String}
end

@testitem "issue #29: the guard frame is excluded from both proofs" begin
    using StrictMode, StrictModeTest
    dot29(a::Vector{Float64}, b::Vector{Float64}) = (
        s = 0.0; @inbounds @simd for i in eachindex(a, b)
            s += a[i] * b[i]
        end; s
    )
    guarded29(a::Vector{Float64}, b::Vector{Float64}) = @strict dot29(a, b)
    a = rand(8); b = rand(8)
    guarded29(a, b)

    # `@strict` keeps its checks on a cold branch, so the guarded call allocates nothing at runtime
    # — but the branch is still in the compiled call graph, and both proofs analyze every path. The
    # issue is about proving a guarded kernel clean, so the proofs must not trip over the guard.
    @test iszero(@allocated guarded29(a, b))
    @test_typestable guarded29(a, b)

    # An all-paths proof of a GUARDED signature cannot pass while checks are enabled, and the
    # contract is that it says so rather than quietly blaming the kernel. With checks on, the
    # guard's reporting path is in the compiled call graph, and every allocation left in it is
    # Base's string machinery — `takestring!`, `_string_n`, `StringMemory` — whose backtrace
    # truncates at a shared call site before reaching any StrictMode frame. Measured here: 919 of
    # 919 remaining instances are unattributable, so no filter on this side can tell them from the
    # kernel's own, and `ignore_barrier` does not apply (it covers one-time-init guards).
    #
    # Asserted rather than recorded as broken: if the attribution ever returns, `@test_noalloc`
    # stops raising and this fails loudly — the same tripwire, as a test that passes today.
    kept29 = StrictModeTest._raw_allocs(guarded29, (Vector{Float64}, Vector{Float64}))
    @test !isempty(kept29)
    @test all(StrictModeTest._is_unattributed, kept29)
    @test_throws StrictMode.StrictViolation (@test_noalloc guarded29(a, b))
    # What does hold on every version: the inner kernel is provably clean on its own, which is the
    # verdict to reach for while a guarded signature cannot be attributed.
    @test test_signatures(
        [(dot29, (Vector{Float64}, Vector{Float64}))];
        guarantees = (:noalloc,)
    ) isa Vector{StrictMode.StrictFinding}

    # The filter must be narrow: a guarded kernel that really allocates still fails. Without this,
    # excluding the guard frame could hide the user's own finding, which is worse than the bug.
    SINK29 = Ref{Any}(nothing)
    dirty29(n::Int) = (v = Vector{Float64}(undef, n); SINK29[] = v; length(v))
    gdirty29(n::Int) = @strict dirty29(n)
    gdirty29(4)
    @test_throws StrictViolation (@test_noalloc gdirty29(4))

    # An unguarded allocating call is unaffected either way.
    @test_throws StrictViolation (@test_noalloc dirty29(4))
end
