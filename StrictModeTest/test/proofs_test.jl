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
    # ... which is what the proof's warning about a guard counts
    all29 = StrictModeTest._raw_allocs_unfiltered(guarded29, (Vector{Float64}, Vector{Float64}))
    @test StrictModeTest._guard_unattributed(all29, kept29) == length(kept29)
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

@testitem "every guarantee in _GUARANTEES is answerable by the proof tier" begin
    using StrictMode, StrictModeTest

    # The two tiers ship in lockstep, and `proof_findings` dispatches on the guarantee by name:
    # anything `_GUARANTEES` gains and this chain does not reach falls through to an
    # `unknown guarantee` ArgumentError whose own message lists the guarantee as expected. That
    # makes the reporting tier stricter than the gating one, which is the failure this pins.
    kern(x::Float64) = x * 2.0 + 1.0
    kern(1.0)

    for g in StrictMode._GUARANTEES
        fs = try
            StrictModeTest.proof_findings(kern, (Float64,); guarantees = (g,))
        catch err
            err isa ArgumentError &&
                error(
                "proof_findings cannot answer :$g, which is in _GUARANTEES: " *
                    sprint(showerror, err)
            )
            rethrow()
        end
        @test length(fs) == 1
        @test fs[1].guarantee === g
        @test fs[1].tier === :proof
    end
end

@testitem "the threadid guarantee answers identically in both tiers" begin
    using StrictMode, StrictModeTest

    # One implementation serves both tiers through `_compiled_output_finding`, because no backend
    # has anything to say about a `Threads.threadid()`-indexed store. A second copy could only drift.
    tls = [0.0]
    dirty() = (i = Threads.threadid(); yield(); tls[i] += 1.0)   # held across a yield
    clean(x::Float64) = x + 1.0
    dirty(); clean(1.0)

    for (f, tt, want_fail) in ((dirty, (), true), (clean, (Float64,), false))
        rep = only(StrictMode.findings(f, tt; guarantees = (:no_threadid_state,)))
        prf = only(StrictModeTest.proof_findings(f, tt; guarantees = (:no_threadid_state,)))
        @test StrictMode._failed(rep) == want_fail
        @test StrictMode._failed(prf) == want_fail
        @test rep.reason == prf.reason
        @test rep.tier === :report
        @test prf.tier === :proof
    end

    # And the gating driver raises on it rather than refusing the guarantee's name.
    @test_throws StrictMode.StrictViolation StrictModeTest.test_signatures(
        [(dirty, ())]; guarantees = (:no_threadid_state,)
    )
end

@testitem "an exempt callee does not excuse its caller from the allocation proof" begin
    using StrictMode, StrictModeTest, Test
    module ExemptProof
    using StrictMode
    const BUF = Ref(Float64[])
    @noinline function xgrow_proof!(n::Int)
        length(BUF[]) < n && (BUF[] = zeros(n))
        return BUF[]
    end
    StrictMode._exempt!(:xgrow_proof!; guarantees = (:noalloc,), reason = "grows to a high-water mark")
    only_grows(n::Int) = (b = xgrow_proof!(n); b[1])
    end
    ExemptProof.only_grows(4)
    # The scan reports the caller as a note; the proof still sees the allocation, and its gate fails.
    @test only(StrictMode.findings(ExemptProof.only_grows, (Int,); guarantees = (:noalloc,))).status === :info
    @test_throws StrictViolation @test_noalloc ExemptProof.only_grows(4)
end

@testitem "a barrier excuses its own init, not a later growth through its accessor" begin
    using StrictMode, StrictModeTest
    module OnceGrow
    const OPT = Base.OncePerThread{Vector{Float64}}(() -> zeros(8))
    @noinline grow!(v, n) = (length(v) < n && resize!(v, n); v)
    grows(n::Int) = (v = grow!(OPT(), n); v[1] = 1.0; nothing)   # resizes the per-thread buffer
    reads(n::Int) = (v = OPT(); v[1] = Float64(n); nothing)       # its one-time init only
    end
    OnceGrow.grows(8); OnceGrow.reads(8)
    # The resize sits two calls below `grows`, deeper than the value-free scan walks, so only the
    # proof can see it; the barrier must not hand the call to the scan.
    @test_throws StrictMode.StrictViolation StrictModeTest._test_guarantee(
        :noalloc, (:noalloc,), "t", OnceGrow.grows, (Int,)
    )
    @test (StrictModeTest._test_guarantee(:noalloc, (:noalloc,), "t", OnceGrow.reads, (Int,)); true)
end

@testitem "the clock read behind time_ns is not an allocation" begin
    using StrictMode, StrictModeTest
    spin(n::Int) = (
        t0 = time_ns(); s = 0; for i in 1:n
            s += i
        end; time_ns() - t0 + s
    )
    spin_alloc(n::Int) = (t0 = time_ns(); v = zeros(n); time_ns() - t0 + length(v))
    spin(10); spin_alloc(10)
    @test only(proof_findings(spin, (Int,); guarantees = (:noalloc,))).status === :pass
    @test StrictMode._failed(only(proof_findings(spin_alloc, (Int,); guarantees = (:noalloc,))))
end

@testitem "the finalizer hook in Base's unlock is not the call's own allocation" begin
    using StrictMode, StrictModeTest
    # Base's `unlock` runs pending finalizers; that site is dropped, others are still judged.
    lk(l::ReentrantLock) = (lock(l); unlock(l); nothing)
    l = ReentrantLock(); lk(l)
    fin(a) = a isa StrictModeTest.AllocCheck.AllocatingRuntimeCall && Symbol(a.name) === :jl_gc_run_pending_finalizers
    raw = StrictModeTest._raw_allocs(lk, (ReentrantLock,))
    @test any(fin, raw)
    @test !any(fin, StrictModeTest._not_own_excused(lk, raw))
end

@testitem "a proof site in the task scheduler is reported as blocking, with the scan's code" begin
    using StrictMode, StrictModeTest
    @noinline join_pool() = yield()
    top(x::Int) = (join_pool(); x + 1)
    f = only(StrictModeTest._proof_findings(top, (Int,), (:noalloc,)))
    if StrictMode._failed(f)
        # The proof may find the scheduler's sites (the usual case) or none at all on an optimizer that
        # folds them away; when it does find them they carry the scan's kind.
        @test f.code === :SM0017
        @test occursin("blocks in the task scheduler", f.reason)
        @test f.tier === :proof
    else
        @test !StrictMode._failed(f)
    end
    # a site outside the scheduler makes it an ordinary allocation, as the scan reports it
    wait_then_alloc(n::Int) = (join_pool(); zeros(n))
    g = only(StrictModeTest._proof_findings(wait_then_alloc, (Int,), (:noalloc,)))
    @test StrictMode._failed(g) && g.code !== :SM0017
    @test !occursin("blocks in the task scheduler", g.reason)
    @test only(StrictMode.findings(wait_then_alloc, (Int,); guarantees = (:noalloc,))).code === :SM0002
    # an allocation in the package's code a lock runs is the package's, inlined into `lock` or not
    alloc_under_lock(l::ReentrantLock, n::Int) = lock(() -> zeros(n), l)
    h = only(StrictModeTest._proof_findings(alloc_under_lock, (ReentrantLock, Int), (:noalloc,)))
    @test StrictMode._failed(h) && h.code === :SM0002
    @test only(StrictMode.findings(alloc_under_lock, (ReentrantLock, Int); guarantees = (:noalloc,))).code === :SM0002
    # so is one in a callable whose type is Base's, and boxing there is the caller's boxing
    proof(f, T, g) = only(StrictModeTest._proof_findings(f, T, (g,)))
    scan(f, T, g) = only(StrictMode.findings(f, T; guarantees = (g,)))
    fix_under_lock(l::ReentrantLock, n::Int) = lock(Base.Fix1(zeros, n), l)
    sort_under_lock(l::ReentrantLock, v::Vector{Float64}) = lock(Base.Fix1(sort!, v), l)
    for (f, T) in ((fix_under_lock, (ReentrantLock, Int)), (sort_under_lock, (ReentrantLock, Vector{Float64})))
        p = proof(f, T, :noalloc)
        @test StrictMode._failed(p) && p.code === :SM0002
        @test scan(f, T, :noalloc).code === :SM0002
    end
    box_under_lock(l::ReentrantLock, v::Vector{Any}, x::Int) = (lock(() -> push!(v, x), l); nothing)
    BT = (ReentrantLock, Vector{Any}, Int)
    @test StrictMode._failed(proof(box_under_lock, BT, :noboxing)) && StrictMode._failed(scan(box_under_lock, BT, :noboxing))
    # the lock's own machinery is the scheduler's in both tiers
    plain(l::ReentrantLock) = (lock(l); unlock(l); nothing)
    ul(l::ReentrantLock) = (unlock(l); nothing)
    for f in (plain, ul)
        @test proof(f, (ReentrantLock,), :noalloc).code === scan(f, (ReentrantLock,), :noalloc).code === :SM0017
    end
    # so is a condition or channel wait, reached through a keyword body handed its own function
    condwait(c::Threads.Condition) = (lock(c); try wait(c) finally unlock(c) end; nothing)
    chtake(ch::Channel{Int}) = take!(ch)
    for (f, T) in ((condwait, (Threads.Condition,)), (chtake, (Channel{Int},)))
        @test proof(f, T, :noalloc).code === scan(f, T, :noalloc).code === :SM0017
    end
end

@testitem "the proof warns about a guard only for a body that has one" begin
    using StrictMode, StrictModeTest
    # A wait has no guard, and its unattributed sites are Base's: AllocCheck stops at a shared call
    # site in the scheduler. The proof drops other sites (a clock read), which is not a guard either.
    waits() = (yield(); nothing)
    all = StrictModeTest._raw_allocs_unfiltered(waits, ())
    kept = StrictModeTest._raw_allocs(waits, ())
    @test !any(StrictModeTest._is_guard_alloc, all)
    @test any(StrictModeTest._is_unattributed, kept)
    @test StrictModeTest._guard_unattributed(all, kept) == 0
end

@testitem "a C varargs call is not reported as dispatch" begin
    using StrictMode, StrictModeTest
    const AC = StrictModeTest.AllocCheck
    # AllocCheck lists a `ccall` with a required-argument count as a dispatch to an unknown target.
    c_varargs(x::Int32) = ccall(:jl_safe_printf, Cvoid, (Ptr{UInt8}, Int32...), "%d\n", x)
    raw = StrictModeTest._raw_allocs(c_varargs, (Int32,))
    @test any(a -> a isa AC.DynamicDispatch && isnothing(a.fname), raw)
    @test !any(StrictModeTest._is_boxing, raw)
    @test !StrictMode._failed(only(StrictModeTest._proof_findings(c_varargs, (Int32,), (:noboxing,))))

    # The same call next to a dispatch of the function's own stays a dispatch.
    const HOOK = Ref{Any}(identity)
    both(x::Int32) = (ccall(:jl_safe_printf, Cvoid, (Ptr{UInt8}, Int32...), "%d\n", x); HOOK[](x)::Int32)
    @test StrictMode._failed(only(StrictModeTest._proof_findings(both, (Int32,), (:noboxing,))))

    # A wait reaches `Base.trypoptask`, whose only such site is a `jl_safe_printf` of a warning: the
    # call allocates (it can switch tasks) and does not box. Both tiers agree on each.
    waits() = (yield(); nothing)
    for g in (:noalloc, :noboxing)
        proof = StrictMode._failed(only(StrictModeTest._proof_findings(waits, (), (g,))))
        scan = StrictMode._failed(only(findings(waits, (); guarantees = (g,))))
        @test proof == scan == (g === :noalloc)
    end
    # `string(::Int)` allocates through `jl_alloc_string`, called the same way.
    @test !StrictMode._failed(only(StrictModeTest._proof_findings(string, (Int,), (:noboxing,))))
end

@testitem "the scan and the proof agree on dispatch shapes" begin
    using StrictMode, StrictModeTest
    struct ByReference
        a::Vector{Float64}
        b::Vector{Int}
    end
    splat_vec(v::Vector{Float64}) = max(v...)
    by_reference(q::ByReference, s::Symbol) = getfield(q, s) === nothing
    runtime_index(t::Tuple{Int, Float64, Float32}, i::Int) = t[i] === nothing
    for (f, T, boxes) in (
            (splat_vec, (Vector{Float64},), true), (by_reference, (ByReference, Symbol), false),
            (runtime_index, (Tuple{Int, Float64, Float32}, Int), true),
        )
        @test StrictMode._failed(only(StrictModeTest._proof_findings(f, T, (:noboxing,)))) == boxes
        @test StrictMode._failed(only(findings(f, T; guarantees = (:noboxing,)))) == boxes
    end
end

@testitem "a value boxed to be handed over as a reference fails @test_noboxing" begin
    using StrictMode, StrictModeTest
    const AC = StrictModeTest.AllocCheck
    struct InlinePair
        a::Int
        b::Float64
    end
    push_any!(v::Vector{Any}, x::Float64) = (push!(v, x); nothing)
    push_typed!(v::Vector{Float64}, x::Float64) = (push!(v, x); nothing)
    runtime_field(p::InlinePair, s::Symbol) = getfield(p, s) === nothing

    # AllocCheck lists the box as an allocation of the boxed type; an isbits type on the heap is a box.
    raw = StrictModeTest._raw_allocs(push_any!, (Vector{Any}, Float64))
    @test any(a -> a isa AC.AllocationSite && a.type === Float64 && StrictModeTest._is_boxing(a), raw)
    raw = StrictModeTest._raw_allocs(runtime_field, (InlinePair, Symbol))
    @test any(a -> a isa AC.AllocationSite && a.type === InlinePair && StrictModeTest._is_boxing(a), raw)

    @test_throws "boxing / dynamic dispatch" @test_noboxing push_any!(Any[], 1.0)
    @test_throws "boxing / dynamic dispatch" @test_noboxing runtime_field(InlinePair(1, 2.0), :a)
    # Growing a `Vector{Float64}` allocates its memory and boxes nothing.
    @test !any(StrictModeTest._is_boxing, StrictModeTest._raw_allocs(push_typed!, (Vector{Float64}, Float64)))
    @test_noboxing push_typed!(Float64[], 1.0)

    # An `Int` handed to a waiting task is boxed inside Base's scheduler, which neither tier counts.
    hand_over(c::Channel{Int}, x::Int) = (put!(c, x); nothing)
    raw = StrictModeTest._raw_allocs(hand_over, (Channel{Int}, Int))
    @test any(a -> a isa AC.AllocationSite && a.type === Int && StrictModeTest._scheduler_site(a), raw)
    @test !StrictMode._failed(only(StrictModeTest._proof_findings(hand_over, (Channel{Int}, Int), (:noboxing,))))
    @test !StrictMode._failed(only(findings(hand_over, (Channel{Int}, Int); guarantees = (:noboxing,))))
end

@testitem "a dispatch in the code Julia compiles fails @test_noboxing" begin
    using StrictMode, StrictModeTest
    const AC = StrictModeTest.AllocCheck
    # `by` is passed along and never called here, so Julia compiles `pass_along!` once, for
    # `by::Function`, and that body looks `sort!`'s keyword method up at run time.
    @noinline pass_along!(v, by::Function) = (sort!(v; by); nothing)
    @noinline specialized!(v, by::F) where {F} = (sort!(v; by); nothing)
    sort_wide!(v::Vector{Float64}) = pass_along!(v, abs)
    sort_specialized!(v::Vector{Float64}) = specialized!(v, abs)
    T = (Vector{Float64},)

    # AllocCheck compiles `pass_along!` for `typeof(abs)` and finds no dispatch in either.
    @test !any(a -> a isa AC.DynamicDispatch, AC.check_allocs(sort_wide!, T))
    @test !isempty(StrictModeTest._native_dispatches(sort_wide!, T))
    @test isempty(StrictModeTest._native_dispatches(sort_specialized!, T))
    @test all(a -> a isa AC.DynamicDispatch && StrictModeTest._is_boxing(a), StrictModeTest._native_dispatches(sort_wide!, T))

    @test_throws "boxing / dynamic dispatch" @test_noboxing sort_wide!([2.0, -1.0])
    @test_noboxing sort_specialized!([2.0, -1.0])
    # The scan reads the same bodies and agrees on both.
    @test StrictMode._failed(only(findings(sort_wide!, T; guarantees = (:noboxing,))))
    @test !StrictMode._failed(only(findings(sort_specialized!, T; guarantees = (:noboxing,))))

    # The last branch of a union split takes an `Any`, which is not a signature Julia compiles: the
    # call stays dynamic.
    const HOOK = Ref{Any}(1.0)
    @noinline pick(y::Float64, x::Float64) = y + x
    @noinline pick(y, x::Float64) = x
    split_fallback(x::Float64) = pick(HOOK[], x)
    @test isempty(AC.check_allocs(split_fallback, (Float64,)))
    for g in (:noboxing, :noalloc)
        @test StrictMode._failed(only(StrictModeTest._proof_findings(split_fallback, (Float64,), (g,))))
    end

    # A dispatch in a `catch` that returns runs on a call that returns, so it is reported, though
    # AllocCheck skips everything a catch reaches.
    recover(x::Float64) = try
        x < 0 ? throw(DomainError(x)) : sqrt(x)
    catch
        HOOK[](x)::Float64
    end
    @test !isempty(StrictModeTest._native_dispatches(recover, (Float64,)))
    @test StrictModeTest._catch_only_mask(Any[Core.EnterNode(3), Core.ReturnNode(1), Core.ReturnNode(2)]) == [false, false, true]
end

@testitem "a proof's reads are kept while the code they were read from is unchanged" begin
    using StrictMode, StrictModeTest
    @noinline leaf(x::Float64) = x + 1.0
    entry(x::Float64) = leaf(x) * 2.0
    entry(1.0)   # compiled, so the compiler holds a record of the specialization
    T = (Float64,)
    sites = StrictModeTest._raw_allocs_unfiltered(entry, T)
    @test isempty(sites)
    @test StrictModeTest._raw_allocs_unfiltered(entry, T) === sites

    # A definition the signature does not depend on moves the world and ends nothing.
    @eval unrelated() = 1
    @test StrictModeTest._raw_allocs_unfiltered(entry, T) === sites

    # Redefining a callee ends the record, so the proof reads the new code.
    @eval @noinline leaf(x::Float64) = (push!(Any[], x); x + 1.0)
    @test !isempty(StrictModeTest._raw_allocs_unfiltered(entry, T))
    @eval @noinline leaf(x::Float64) = Base.inferencebarrier(x) + 1.0
    @test any(a -> a isa StrictModeTest.AllocCheck.DynamicDispatch, StrictModeTest._native_dispatches(entry, T))

    # A changed setting ends every kept read.
    kept = StrictModeTest._raw_allocs_unfiltered(entry, T)
    StrictMode.set_ignore_throw!(StrictMode.ignore_throw())
    @test StrictModeTest._raw_allocs_unfiltered(entry, T) !== kept
end

@testitem "an allocation proof follows a redefined method or callee, in both directions" begin
    using StrictMode, StrictModeTest

    const RP_SINK = Any[]
    rp_clean(x::Int) = x + 1
    rp_allocating(x::Int) = (push!(RP_SINK, x); x + 1)
    rp_generic(x) = x + 1
    @noinline rp_callee(x::Int) = x + 1
    rp_caller(x::Int) = rp_callee(x) + rp_callee(x)
    rp_clean(1); rp_allocating(1); rp_generic(1); rp_caller(1)
    failed(f) = StrictMode._failed(only(proof_findings(f, (Int,); guarantees = (:noalloc,))))

    @test !failed(rp_clean)
    @test failed(rp_allocating)
    @test !failed(rp_generic)
    @test !failed(rp_caller)

    @eval rp_clean(x::Int) = (push!(RP_SINK, x); x + 1)
    @eval rp_allocating(x::Int) = x + 1
    @eval rp_generic(x::Int) = (push!(RP_SINK, x); x + 1)      # a more specific method takes over
    @eval @noinline rp_callee(x::Int) = (push!(RP_SINK, x); x + 1)

    @test failed(rp_clean)
    @test !failed(rp_allocating)
    @test failed(rp_generic)
    @test failed(rp_caller)
end

@testitem "a caller that allocates only inside exempt functions is noted, not passed" begin
    using StrictMode, StrictModeTest, Test

    module ExemptOnly
    using StrictMode
    const POOL = Ref(Float64[])
    # A pool that grows to a high-water mark: exempt from `:noalloc`, with the reason.
    @noinline function grow!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    StrictMode._exempt!(:grow!, ExemptOnly; guarantees = (:noalloc,), reason = "pool grows to a high-water mark")
    const TABLE = Ref(Int[])
    @noinline function table!(n::Int)
        length(TABLE[]) < n && (TABLE[] = collect(1:n))
        return TABLE[]
    end
    StrictMode._exempt!(:table!, ExemptOnly; guarantees = (:noalloc,), reason = "index table built once per size")
    @inline function grow_inlined!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    StrictMode._exempt!(:grow_inlined!, ExemptOnly; guarantees = (:noalloc,), reason = "inlined growth")

    only_grows(n::Int) = (b = grow!(n); b[1])
    two_exempt(n::Int) = (b = grow!(n); t = table!(n); b[1] + t[1])
    # PureBLAS's control: one exempt growth and one allocation of the caller's own.
    grows_and_allocs(n::Int) = (b = grow!(n); sum(zeros(n)) + b[1])
    inlined(n::Int) = (b = grow_inlined!(n); b[1])
    clean(n::Int) = n + 1
    end
    # A function of the same name in another module is not the exempt one.
    module ExemptOther
    @noinline grow!(n::Int) = zeros(n)
    caller(n::Int) = (b = grow!(n); b[1])
    end
    E = ExemptOnly
    E.only_grows(4); E.two_exempt(4); E.grows_and_allocs(4); E.inlined(4); ExemptOther.caller(4)
    proof(f) = only(StrictModeTest.proof_findings(f, (Int,); guarantees = (:noalloc,)))

    r = proof(E.only_grows)
    @test r.status === :fail
    @test r.code === :SM0018
    @test r.exempt_by == ("grow!" => "pool grows to a high-water mark",)
    @test occursin("allocates only inside", r.reason) && occursin("`grow!`", r.reason)
    @test StrictMode._failed(r)
    two = proof(E.two_exempt)
    @test two.status === :fail && two.code === :SM0018
    @test Set(first.(two.exempt_by)) == Set(["grow!", "table!"])
    @test ("table!" => "index table built once per size") in two.exempt_by

    # Never a pass: every gate fails it, and says which functions it is exempt by.
    @test_throws StrictViolation @test_noalloc E.only_grows(4)
    @test_throws "pool grows to a high-water mark" @test_noalloc E.only_grows(4)
    @test_throws "allow_exempt = true" test_signatures([(E.only_grows, (Int,))]; guarantees = (:noalloc,))
    @test_throws StrictViolation test_compiled(E; guarantees = (:noalloc,), only = [:only_grows])
    # …unless the caller accepts the exemptions by name.
    @test (@test_noalloc allow_exempt = true E.only_grows(4)) == E.POOL[][1]
    ok = test_signatures([(E.only_grows, (Int,))]; guarantees = (:noalloc,), allow_exempt = true)
    @test only(ok).status === :info && only(ok).code === :SM0018
    @test test_compiled(E; guarantees = (:noalloc,), only = [:only_grows], allow_exempt = true) isa Vector

    # One site of the caller's own makes it an ordinary failure, with or without the opt-in.
    mixed = proof(E.grows_and_allocs)
    @test mixed.status === :fail && mixed.code !== :SM0018 && isempty(mixed.exempt_by)
    @test_throws StrictViolation @test_noalloc allow_exempt = true E.grows_and_allocs(4)
    @test_throws StrictViolation test_signatures([(E.grows_and_allocs, (Int,))]; guarantees = (:noalloc,), allow_exempt = true)

    # An exempt callee that was inlined leaves no frame of its own to match, so the allocation is
    # the caller's: an ordinary failure.
    inl = proof(E.inlined)
    @test inl.status === :fail && inl.code !== :SM0018
    @test_throws StrictViolation @test_noalloc allow_exempt = true E.inlined(4)

    # The exemption is the method's, not the name's.
    other = proof(ExemptOther.caller)
    @test other.status === :fail && other.code !== :SM0018

    # A clean call is a pass either way, and the code has a meaning.
    @test proof(E.clean).status === :pass
    @test occursin("exempt", StrictMode.explain(:SM0018))
end

@testitem "a session-wide exemption excuses no proof site" begin
    using StrictMode, StrictModeTest, Test

    module SessionExempt
    const POOL = Ref(Float64[])
    @noinline function sgrow!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    only_grows(n::Int) = (b = sgrow!(n); b[1])
    end
    # Declared with no module: it covers by name, in every module, so it does not name a method.
    StrictMode._exempt!(:sgrow!; guarantees = (:noalloc,), reason = "session-wide")
    SessionExempt.only_grows(4)

    r = only(StrictModeTest.proof_findings(SessionExempt.only_grows, (Int,); guarantees = (:noalloc,)))
    @test r.status === :fail
    @test r.code !== :SM0018
    @test isempty(r.exempt_by)
    @test_throws StrictViolation @test_noalloc allow_exempt = true SessionExempt.only_grows(4)
    @test_throws StrictViolation test_signatures([(SessionExempt.only_grows, (Int,))]; guarantees = (:noalloc,), allow_exempt = true)
    # The scan's own note is as it was: the session-wide exemption still excuses the callee there.
    @test only(StrictMode.findings(SessionExempt.only_grows, (Int,); guarantees = (:noalloc,))).status === :info

    # The same exemption declared in the module names the method, and counts.
    StrictMode._exempt!(:sgrow!, SessionExempt; guarantees = (:noalloc,), reason = "declared in the module")
    m = only(StrictModeTest.proof_findings(SessionExempt.only_grows, (Int,); guarantees = (:noalloc,)))
    @test m.status === :fail && m.code === :SM0018
    @test m.exempt_by == ("sgrow!" => "declared in the module",)

    # `@strict_exempt` written in a module's source is that form.
    module MacroExempt
    using StrictMode
    const POOL = Ref(Float64[])
    @noinline function mgrow!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    @strict_exempt :noalloc reason = "written in the source" mgrow!
    only_grows(n::Int) = (b = mgrow!(n); b[1])
    end
    MacroExempt.only_grows(4)
    w = only(StrictModeTest.proof_findings(MacroExempt.only_grows, (Int,); guarantees = (:noalloc,)))
    @test w.status === :fail && w.code === :SM0018
    @test w.exempt_by == ("mgrow!" => "written in the source",)
end

@testitem "an exempt-only result is not a pass to any reader" begin
    using StrictMode, StrictModeTest, Test

    module ExemptReaders
    using StrictMode
    const POOL = Ref(Float64[])
    @noinline function grow!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    @strict_exempt :noalloc reason = "pool" grow!
    typed_grows(n::Int) = (b = grow!(n); b[1])
    end
    E = ExemptReaders
    E.typed_grows(4)
    sig = (Int,)

    # The data API: counted as a failure, with the code and the exempt functions kept.
    fs = StrictModeTest.proof_findings(E.typed_grows, sig; guarantees = (:noalloc,))
    r = only(fs)
    @test StrictMode._failed(r)
    @test nfailures(fs) == 1
    @test r.code === :SM0018
    @test r.exempt_by == ("grow!" => "pool",)
    @test occursin("allow_exempt = true", r.suggestion)
    # Accepted by name, it is a note, and still not a pass.
    ok = only(StrictModeTest.proof_findings(E.typed_grows, sig; guarantees = (:noalloc,), allow_exempt = true))
    @test ok.status === :info && ok.code === :SM0018 && ok.exempt_by == r.exempt_by
    @test nfailures([ok]) == 0

    # Every entry point of the function: the positional one is not proven clean.
    entry = only(e for e in StrictModeTest.alloc_entry_report(E.typed_grows).entries if e.kind === :positional)
    @test entry.status === :fail
    @test occursin("exempt from :noalloc", entry.reason)
    accepted = only(e for e in StrictModeTest.alloc_entry_report(E.typed_grows; allow_exempt = true).entries if e.kind === :positional)
    @test accepted.status === :info
    @test occursin("exempt from :noalloc", accepted.reason) && occursin("grow!", accepted.reason)

    # The two engines say the same thing about this call, each in its own words: the scan notes the
    # exempt callee and the proof reports the exempt-only result. That is not a disagreement, and it
    # is not "the proof passes" either.
    d = divergence_report(E.typed_grows, sig; guarantees = (:noalloc,))
    @test isempty(d)
    @test !StrictMode._failed(only(StrictMode.findings(E.typed_grows, sig; guarantees = (:noalloc,))))

    # A sweep that reports, and one that gates.
    @test nfailures(StrictModeTest.proof_findings(E; guarantees = (:noalloc,), only = [:typed_grows])) == 1
    @test_throws StrictViolation test_compiled(E; guarantees = (:noalloc,), only = [:typed_grows])
    @test test_compiled(E; guarantees = (:noalloc,), only = [:typed_grows], allow_exempt = true) isa Vector
end

@testitem "an exempt function does not excuse a callback it was handed" begin
    using StrictMode, StrictModeTest, Test

    module ExemptCallback
    using StrictMode
    const POOL = Ref(Float64[])
    @noinline function grow!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    @strict_exempt :noalloc reason = "pool" grow!
    # Exempt, and it runs whatever it is given.
    @noinline withbuf(f::F, n) where {F} = f(grow!(n))
    @strict_exempt :noalloc reason = "borrows the pool" withbuf
    @noinline mk(n) = zeros(n)
    cb(n::Int) = withbuf(b -> sum(mk(n)) + b[1], n)
    cb_inline(n::Int) = withbuf(b -> sum(zeros(n)) + b[1], n)
    named_cb(b) = sum(zeros(length(b))) + b[1]
    cb_named(n::Int) = withbuf(named_cb, n)
    const BOXES = Any[1.0]
    cb_box(n::Int) = withbuf(b -> (BOXES[1] + b[1])::Float64, n)
    # The callback allocates nothing of its own: every site is the exempt functions' own code.
    cb_clean(n::Int) = withbuf(b -> b[1], n)
    plain(n::Int) = (b = grow!(n); b[1])
    # A callable struct with more than one call method.
    struct Cb2
        n::Int
    end
    (c::Cb2)(b::Vector{Float64}) = sum(zeros(c.n)) + b[1]
    (c::Cb2)(b::Vector{Float64}, k::Int) = b[k]
    cb_struct2(n::Int) = withbuf(Cb2(n), n)
    # Callbacks handed in inside an array, of one concrete type and of an abstract one.
    @noinline withbufs(fs::Vector{F}, n) where {F} = fs[1](grow!(n))
    @strict_exempt :noalloc reason = "vec" withbufs
    const FS = [b -> sum(zeros(length(b))) + b[1]]
    cb_vec(n::Int) = withbufs(FS, n)
    @noinline withhooks(hooks::Vector{Function}, n::Int) = (
        b = grow!(n); for h in hooks
            h(b)
        end; b[1]
    )
    @strict_exempt :noalloc reason = "runs hooks" withhooks
    const HOOKS = Function[b -> sum(zeros(length(b)))]
    cb_hooks(n::Int) = withhooks(HOOKS, n)
    # A callback held in a field declared `Function`, and one passed through `@nospecialize`.
    struct Hook
        f::Function
    end
    @noinline withhook(h::Hook, n::Int) = (b = grow!(n); h.f(b); b[1])
    @strict_exempt :noalloc reason = "runs a hook" withhook
    const HOOK = Hook(b -> sum(zeros(length(b))))
    cb_field(n::Int) = withhook(HOOK, n)
    @noinline withany(@nospecialize(f), n::Int) = (b = grow!(n); f(b); b[1])
    @strict_exempt :noalloc reason = "nospecialize" withany
    const ANYCB = Ref{Any}(b -> sum(zeros(length(b))))
    cb_any(n::Int) = withany(ANYCB[], n)
    end
    E = ExemptCallback
    E.cb(3); E.cb_inline(3); E.cb_named(3); E.cb_box(3); E.cb_clean(3); E.plain(3)
    E.cb_struct2(3); E.cb_vec(3); E.cb_hooks(3); E.cb_field(3); E.cb_any(3)
    proof(f; kw...) = only(StrictModeTest.proof_findings(f, (Int,); guarantees = (:noalloc,), kw...))

    # An allocation made by the caller's own closure, run inside the exempt function, is the
    # caller's: an ordinary failure, which no option accepts.
    for f in (E.cb, E.cb_inline, E.cb_named, E.cb_box, E.cb_struct2, E.cb_vec, E.cb_hooks, E.cb_field, E.cb_any)
        r = proof(f; allow_exempt = true)
        @test r.status === :fail
        @test r.code !== :SM0018
        @test isempty(r.exempt_by)
    end
    @test_throws StrictViolation @test_noalloc allow_exempt = true E.cb(3)

    # What the exempt functions allocate themselves is still theirs.
    @test proof(E.plain).code === :SM0018
    @test proof(E.plain; allow_exempt = true).status === :info
    clean = proof(E.cb_clean; allow_exempt = true)
    @test clean.status === :info && clean.code === :SM0018
end

@testitem "the proof honors a callable barrier registered as its type" begin
    using StrictMode, StrictModeTest, Test

    module ProofCallableBarrier
    struct Table
        n::Int
    end
    @noinline (t::Table)() = zeros(t.n)
    useany(t::Table) = t()[1]
    end
    P = ProofCallableBarrier
    proof() = only(StrictModeTest.proof_findings(P.useany, (P.Table,); guarantees = (:noalloc,)))
    @test StrictMode._failed(proof())
    register_alloc_barrier!(P.Table)
    @test !StrictMode._failed(proof())
    delete!(StrictMode._ALLOC_BARRIERS, P.Table)
    store = StrictMode._store_for(Base.moduleroot(parentmodule(P)), StrictMode._LOCAL_BARRIERS)
    isnothing(store) || filter!(g -> g !== P.Table, store)
    StrictMode._BARRIER_GEN[] += 1
    StrictMode.clear_cache!()
end

@testitem "a barrier excuses a helper it calls from several sites, unless the call reaches it too" begin
    using StrictMode, StrictModeTest, Test

    # A function called from more than one place is compiled once, and AllocCheck ends the backtrace
    # of its sites at a frame named "multiple call sites": the barrier is not in it.
    module MultiSite
    @noinline helper(n::Int; k::Int = 1) = (w = zeros(n + k); w[1] + length(w))
    @noinline sized(n::Int) = helper(n) + helper(n; k = 3)
    @noinline regrow!(n::Int) = sized(n)
    @noinline mid(n::Int) = helper(n; k = 5)
    only_barrier(n::Int) = regrow!(n) + 1
    also_direct(n::Int) = regrow!(n) + mid(n)
    end
    M = MultiSite
    M.only_barrier(3); M.also_direct(3)
    register_alloc_barrier!(M.regrow!)
    try
        proof(f) = only(StrictModeTest.proof_findings(f, (Int,); guarantees = (:noalloc,)))
        # Both calls reach the proof's barrier filter rather than the unfiltered proof.
        for f in (M.only_barrier, M.also_direct)
            sig = StrictMode._alloc_signals(f, (Int,))
            @test sig.barrier && !sig.alloc
        end
        raw = StrictModeTest._raw_allocs(M.only_barrier, (Int,))
        @test any(a -> any(fr -> fr.func === Symbol("multiple call sites"), a.backtrace), raw)
        @test !StrictMode._failed(proof(M.only_barrier))
        # `mid` reaches the helper without crossing the barrier, so its sites are the call's own.
        @test StrictMode._failed(proof(M.also_direct))
    finally
        delete!(StrictMode._ALLOC_BARRIERS, M.regrow!)
        store = StrictMode._store_for(Base.moduleroot(parentmodule(M)), StrictMode._LOCAL_BARRIERS)
        isnothing(store) || filter!(g -> g !== M.regrow!, store)
        StrictMode._BARRIER_GEN[] += 1
        StrictMode.clear_cache!()
    end
end

@testitem "proof_audit and proof_findings(mod) accept exemptions with allow_exempt" begin
    using StrictMode, StrictModeTest, Test

    module AuditExempt
    using StrictMode
    const POOL = Ref(Float64[])
    @noinline function grow!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    @strict_exempt :noalloc reason = "pool" grow!
    @noinline setup(n::Int) = zeros(n)
    @strict_function guarantees = (:noalloc,) use(n::Int) = (b = grow!(n); b[1])
    end
    A = AuditExempt
    A.use(4)
    register_alloc_barrier!(A.setup)
    try
        row(fs) = only(filter(f -> f.mod === :AuditExempt && f.guarantee === :noalloc, fs))
        r = row(proof_audit(:registered; allow_exempt = true))
        @test r.status === :info && r.code === :SM0018
        @test r.exempt_by == ("grow!" => "pool",)
        r = row(proof_audit(:registered))
        @test StrictMode._failed(r) && r.code === :SM0018
        @test r.exempt_by == ("grow!" => "pool",)

        # The declared scope and the sweep both list `use`.
        rs = filter(
            f -> f.guarantee === :noalloc,
            proof_audit(A; sweep = true, guarantees = (:noalloc,), only = [:use], allow_exempt = true)
        )
        @test length(rs) == 2
        @test all(r -> r.status === :info && r.exempt_by == ("grow!" => "pool",), rs)
        r = only(StrictModeTest.proof_findings(A; guarantees = (:noalloc,), only = [:use], allow_exempt = true))
        @test r.status === :info && r.code === :SM0018 && r.exempt_by == ("grow!" => "pool",)
        @test StrictMode._failed(only(StrictModeTest.proof_findings(A; guarantees = (:noalloc,), only = [:use])))
    finally
        delete!(StrictMode._ALLOC_BARRIERS, A.setup)
        store = StrictMode._store_for(Base.moduleroot(A), StrictMode._LOCAL_BARRIERS)
        isnothing(store) || filter!(g -> g !== A.setup, store)
        StrictMode._BARRIER_GEN[] += 1
        StrictMode.clear_cache!()
    end
end

@testitem "a declared signature keeps the exempt functions its result names" begin
    using StrictMode, StrictModeTest, Test

    module DeclaredExempt
    using StrictMode
    const POOL = Ref(Float64[])
    @noinline function grow!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    @strict_exempt :noalloc reason = "pool" grow!
    @strict_function guarantees = (:noalloc,) use(n::Int) = (b = grow!(n); b[1])
    end
    D = DeclaredExempt
    D.use(4)
    fs = test_signatures([(D.use, (Int,))]; guarantees = (:noalloc,), allow_exempt = true)
    r = only(fs)
    @test r.code === :SM0018 && r.policy != ""
    @test r.exempt_by == ("grow!" => "pool",)
    @test occursin("exempt by", sprint(io -> StrictMode.format_findings(io, fs; format = :text)))
    r = only(test_registered(; guarantees = (:noalloc,), modules = [D], allow_exempt = true))
    @test r.exempt_by == ("grow!" => "pool",)
end

@testitem "an allocation on the way to a throw a catch handles fails the proof" begin
    using StrictMode, StrictModeTest
    # The message is built and the exception boxed on every call, since the catch returns normally.
    @noinline function caught_message(n::Int)
        try
            throw(ArgumentError(string("x", n)))
        catch
        end
        return n
    end
    # Only the box of the thrown exception: 16 bytes a call.
    @noinline function caught_box(n::Int)
        try
            throw(ArgumentError("x"))
        catch
        end
        return n
    end
    # Passing controls: a throw nothing catches, a try that exits normally, a catch that rethrows.
    @noinline function uncaught(n::Int)
        n < 0 && throw(ArgumentError(string("negative: ", n)))
        return n + 1
    end
    @noinline function normal_exit(n::Int)
        try
            n += 1
        catch
        end
        return n
    end
    @noinline function rethrows(n::Int)
        try
            n < 0 && throw(ArgumentError(string("negative: ", n)))
        catch
            rethrow()
        end
        return n
    end
    tt = (Int,)
    proof(f) = only(StrictModeTest._proof_findings(f, tt, (:noalloc,)))
    scan(f) = only(findings(f, tt; guarantees = (:noalloc,)))
    for f in (caught_message, caught_box)
        f(3)
        # AllocCheck's own sites, not only the native walk's dispatches.
        @test any(a -> !(a isa StrictModeTest.AllocCheck.DynamicDispatch), StrictModeTest._raw_allocs(f, tt))
        @test StrictMode._failed(proof(f))
        @test StrictMode._failed(scan(f))
    end
    for f in (uncaught, normal_exit, rethrows)
        f(3)
        @test isempty(StrictModeTest._raw_allocs(f, tt))
        @test !StrictMode._failed(proof(f))
        @test !StrictMode._failed(scan(f))
    end
end

@testitem "code in a catch that returns normally fails the proof" begin
    using StrictMode, StrictModeTest
    # The throw is raised inside a callee, so the try body allocates nothing of its own; the handler
    # runs on every call and returns what it allocates.
    @noinline thrower(n::Int) = throw(ArgumentError("x"))
    @noinline function handler_only(n::Int)
        try
            thrower(n)
        catch
            return zeros(n)
        end
    end
    # A callee the handler calls runs on that normal return as well.
    @noinline make_zeros(n::Int) = zeros(n)
    @noinline handler_callee(n::Int) = try thrower(n) catch; make_zeros(n) end
    # Passing controls: a handler that allocates and then rethrows is an error path, and so is
    # everything a try with a normal exit does not reach.
    const SINK = Ref{Any}(nothing)
    @noinline function handler_rethrows(n::Int)
        try
            thrower(n)
        catch
            SINK[] = zeros(n)
            rethrow()
        end
    end
    @noinline function normal_exit(n::Int)
        try
            n += 1
        catch
        end
        return n
    end
    tt = (Int,)
    proof(f) = only(StrictModeTest._proof_findings(f, tt, (:noalloc,)))
    scan(f) = only(findings(f, tt; guarantees = (:noalloc,)))
    handler_only(3); handler_callee(3)
    for f in (handler_only, handler_callee)
        @test any(a -> !(a isa StrictModeTest.AllocCheck.DynamicDispatch), StrictModeTest._raw_allocs(f, tt))
        @test StrictMode._failed(proof(f))
        @test StrictMode._failed(scan(f))
        @test isempty(StrictModeTest.divergence_report(f, tt; guarantees = (:noalloc,)))
    end
    for f in (handler_rethrows, normal_exit)
        @test isempty(StrictModeTest._raw_allocs(f, tt))
        @test !StrictMode._failed(proof(f))
        @test !StrictMode._failed(scan(f))
    end
end

@testitem "a barrier excuses its sites on a path a catch handles" begin
    using StrictMode, StrictModeTest, Test
    # `refresh` throws inside its try body and returns false from the catch; the caller then calls
    # the registered barrier `regrow!`. The exception box is the call's own allocation, and the
    # barrier's buffer is not.
    module CaughtBarrier
    @noinline regrow!(n::Int) = zeros(n)
    @inline fits(n::Int) = (n > 4 && throw(ArgumentError("too big")); true)
    @noinline function refresh(n::Int)
        try
            return fits(n)
        catch
            return false
        end
    end
    step(n::Int) = (refresh(n) || regrow!(n); n)
    # Passing control: the same barrier behind a try that exits normally.
    @noinline function refresh_ok(n::Int)
        try
            n += 1
        catch
            return false
        end
        return n > 4
    end
    step_ok(n::Int) = (refresh_ok(n) || regrow!(n); n)
    end
    M = CaughtBarrier
    M.step(8); M.step_ok(8)
    register_alloc_barrier!(M.regrow!)
    try
        tt = (Int,)
        proof(f) = only(StrictModeTest.proof_findings(f, tt; guarantees = (:noalloc,)))
        kept, _ = StrictModeTest._checked_allocs(M.step, tt)
        @test !isempty(kept)
        @test !any(StrictModeTest._through_barrier, kept)
        @test StrictMode._failed(proof(M.step))
        @test !StrictMode._failed(proof(M.step_ok))
    finally
        delete!(StrictMode._ALLOC_BARRIERS, M.regrow!)
        store = StrictMode._store_for(Base.moduleroot(parentmodule(M)), StrictMode._LOCAL_BARRIERS)
        isnothing(store) || filter!(g -> g !== M.regrow!, store)
        StrictMode._BARRIER_GEN[] += 1
        StrictMode.clear_cache!()
    end
end

@testitem "a throw raised in a callee that a catch handles fails the proof" begin
    using StrictMode, StrictModeTest
    # A throw raised inside a callee the try body calls, inlined or not, lands in the catch, which
    # returns normally: the message and the exception are built on every call that throws.
    @noinline thrower(n::Int) = throw(ArgumentError(string("x", n)))
    @inline thrower_inl(n::Int) = throw(ArgumentError(string("x", n)))
    @noinline middle(n::Int) = (thrower(n); n)
    @noinline caught_callee(n::Int) = (try thrower(n) catch end; n)
    @noinline caught_inlined(n::Int) = (try thrower_inl(n) catch end; n)
    @noinline caught_deep(n::Int) = (try middle(n) catch end; n)
    # An out-of-bounds index builds a `BoundsError` inside `throw_boundserror`.
    @noinline caught_index(v::Vector{Int}, i::Int) = try v[i] catch; 0 end
    # Passing controls: the callee's throw is uncaught, the catch rethrows, the call sits outside
    # the try, and a try that exits normally.
    @noinline uncaught_callee(n::Int) = (n < 0 && thrower(n); n + 1)
    @noinline rethrows_callee(n::Int) = (try n < 0 && thrower(n) catch; rethrow() end; n)
    @noinline outside_try(n::Int) = (try n += 1 catch end; n < 0 && thrower(n); n)
    @noinline normal_exit(n::Int) = (try n += 1 catch end; n)
    # A callee the handler calls is outside the try: its own throw is uncaught, an error path.
    @noinline maybe_throws(n::Int) = (n < 0 && thrower(n); n)
    @noinline mightthrow(n::Int) = n > 100 ? throw(nothing) : n
    @noinline handler_calls(n::Int) = try mightthrow(n) catch; maybe_throws(n) end
    caught = ((caught_callee, (Int,)), (caught_inlined, (Int,)), (caught_deep, (Int,)),
        (caught_index, (Vector{Int}, Int)))
    clean = ((uncaught_callee, (Int,)), (rethrows_callee, (Int,)), (outside_try, (Int,)),
        (normal_exit, (Int,)), (handler_calls, (Int,)))
    caught_callee(1); caught_inlined(1); caught_deep(1); caught_index([1], 2)
    uncaught_callee(1); rethrows_callee(1); outside_try(1); normal_exit(1); handler_calls(1); handler_calls(200)
    proof(f, tt) = only(StrictModeTest._proof_findings(f, tt, (:noalloc,)))
    for (f, tt) in caught
        @test any(a -> !(a isa StrictModeTest.AllocCheck.DynamicDispatch), StrictModeTest._raw_allocs(f, tt))
        @test StrictMode._failed(proof(f, tt))
        @test isempty(StrictModeTest.divergence_report(f, tt; guarantees = (:noalloc,)))
    end
    for (f, tt) in clean
        @test isempty(StrictModeTest._raw_allocs(f, tt))
        @test !StrictMode._failed(proof(f, tt))
        @test isempty(StrictModeTest.divergence_report(f, tt; guarantees = (:noalloc,)))
    end
    @test isempty(StrictModeTest._raw_allocs(middle, (Int,)))
end

@testitem "an exempt callee's boxing is excused under :noalloc only" begin
    using StrictMode, StrictModeTest, Test

    module ExemptBoxProof
    using StrictMode
    const BOXES = Any[1]
    @noinline pb_box!(n::Int) = (BOXES[1] + n)::Int
    @strict_exempt :noalloc reason = "boxes" pb_box!
    calls_boxer(n::Int) = pb_box!(n) + 1
    end
    E = ExemptBoxProof
    E.calls_boxer(1)
    proof(g) = only(StrictModeTest.proof_findings(E.calls_boxer, (Int,); guarantees = (g,)))
    r = proof(:noalloc)
    @test r.status === :fail && r.code === :SM0018
    @test r.exempt_by == ("pb_box!" => "boxes",)
    @test StrictMode._failed(proof(:noboxing))
    # The scan gives the same answer: a note naming the exempt callee, and a :noboxing failure.
    s = only(StrictMode.findings(E.calls_boxer, (Int,); guarantees = (:noalloc,)))
    @test s.status === :info && occursin("pb_box!", s.reason)
    @test StrictMode._failed(only(StrictMode.findings(E.calls_boxer, (Int,); guarantees = (:noboxing,))))
end

@testitem "a throw a catch rethrows by its type is an error path" begin
    using StrictMode, StrictModeTest, Test

    module TypedCatch
    const NEG = ArgumentError("negative")
    # Throws an `ArgumentError` it does not build, or nothing.
    @noinline argcheck(i::Int) = (i < 0 && throw(NEG); i)
    # Builds the message of the `ArgumentError` it throws.
    @noinline argmsg(i::Int) = (i < 0 && throw(ArgumentError(string("negative: ", i))); i)
    # An out-of-bounds index builds a `BoundsError` inside `throw_boundserror`.
    @noinline bin!(v::Vector{Int}, i::Int) = (v[i] += 1; nothing)
    const FLAG = Ref(false)
    # The handler returns for an `ArgumentError` and rethrows anything else, so the `BoundsError`
    # path ends in a rethrow, called or inlined.
    @noinline function rethrows_bounds(v::Vector{Int}, i::Int)
        try
            argcheck(i)
            bin!(v, i)
        catch err
            err isa ArgumentError || rethrow()
            return false
        end
        return true
    end
    @noinline function rethrows_bounds_inline(v::Vector{Int}, i::Int)
        try
            argcheck(i)
            v[i] += 1
        catch err
            err isa ArgumentError || rethrow()
            return false
        end
        return true
    end
    # Failing controls: the thrown `ArgumentError` is one the handler returns for, and a handler
    # that rethrows depending on a value returns for a `BoundsError` too.
    @noinline function keeps_argument(v::Vector{Int}, i::Int)
        try
            argmsg(i)
            bin!(v, i)
        catch err
            err isa ArgumentError || rethrow()
            return false
        end
        return true
    end
    @noinline function rethrows_on_value(v::Vector{Int}, i::Int)
        try
            argcheck(i)
            bin!(v, i)
        catch err
            FLAG[] || rethrow()
            return false
        end
        return true
    end
    # A bounds-checked `memoryrefnew` throws its `BoundsError` itself, with no call to read:
    # `getindex` on a `Memory` on Julia 1.12, and one written out on every version.
    @noinline mget(m::Memory{Int}, i::Int) = m[i]
    @noinline mref(m::Memory{Int}, i::Int) =
        Core.memoryrefget(Core.memoryrefnew(Core.memoryrefnew(m), i, true), :not_atomic, false)
    @noinline function mem_rethrows(m::Memory{Int}, i::Int)
        try
            argcheck(i)
            mget(m, i)
        catch err
            err isa ArgumentError || rethrow()
            return false
        end
        return true
    end
    @noinline function mem_rethrows_inline(m::Memory{Int}, i::Int)
        try
            argcheck(i)
            m[i]
        catch err
            err isa ArgumentError || rethrow()
            return false
        end
        return true
    end
    @noinline function ref_rethrows(m::Memory{Int}, i::Int)
        try
            argcheck(i)
            mref(m, i)
        catch err
            err isa ArgumentError || rethrow()
            return false
        end
        return true
    end
    # Failing controls: an `ArgumentError` the handler returns for, and a handler that returns for a
    # `BoundsError` too.
    @noinline function mem_keeps_argument(m::Memory{Int}, i::Int)
        try
            argmsg(i)
            mget(m, i)
        catch err
            err isa ArgumentError || rethrow()
            return false
        end
        return true
    end
    @noinline function mem_on_value(m::Memory{Int}, i::Int)
        try
            argcheck(i)
            mget(m, i)
        catch err
            FLAG[] || rethrow()
            return false
        end
        return true
    end
    @noinline function ref_on_value(m::Memory{Int}, i::Int)
        try
            argcheck(i)
            mref(m, i)
        catch err
            FLAG[] || rethrow()
            return false
        end
        return true
    end
    # Failing controls: a handler that returns for exactly the `BoundsError`.
    @noinline function mem_keeps_bounds(m::Memory{Int}, i::Int)
        try
            argcheck(i)
            mget(m, i)
        catch err
            err isa BoundsError || rethrow()
            return false
        end
        return true
    end
    @noinline function ref_keeps_bounds(m::Memory{Int}, i::Int)
        try
            argcheck(i)
            mref(m, i)
        catch err
            err isa BoundsError || rethrow()
            return false
        end
        return true
    end
    end
    T = TypedCatch
    tt = (Vector{Int}, Int)
    for f in (T.rethrows_bounds, T.rethrows_bounds_inline, T.keeps_argument, T.rethrows_on_value)
        for i in (1, -1, 3)
            try
                f([1], i)
            catch
            end
        end
    end
    proof(f, g) = only(StrictModeTest._proof_findings(f, tt, (g,)))
    scan(f, g) = only(StrictMode.findings(f, tt; guarantees = (g,)))
    for g in (:noalloc, :noboxing)
        for f in (T.rethrows_bounds, T.rethrows_bounds_inline)
            @test !StrictMode._failed(scan(f, g))
            @test !StrictMode._failed(proof(f, g))
        end
        for f in (T.keeps_argument, T.rethrows_on_value)
            @test StrictMode._failed(scan(f, g))
            @test StrictMode._failed(proof(f, g))
        end
    end
    for f in (T.rethrows_bounds, T.rethrows_bounds_inline, T.keeps_argument, T.rethrows_on_value)
        @test isempty(StrictModeTest.divergence_report(f, tt; guarantees = (:noalloc,)))
    end
    mt = (Memory{Int}, Int)
    mclean = (T.mem_rethrows, T.mem_rethrows_inline, T.ref_rethrows)
    mcaught = (T.mem_keeps_argument, T.mem_on_value, T.ref_on_value, T.mem_keeps_bounds, T.ref_keeps_bounds)
    for f in (mclean..., mcaught...), i in (1, -1, 3)
        try
            f(Memory{Int}([1]), i)
        catch
        end
    end
    mproof(f) = only(StrictModeTest._proof_findings(f, mt, (:noalloc,)))
    mscan(f) = only(StrictMode.findings(f, mt; guarantees = (:noalloc,)))
    for f in mclean
        @test !StrictMode._failed(mscan(f))
        @test !StrictMode._failed(mproof(f))
    end
    for f in mcaught
        @test StrictMode._failed(mscan(f))
        @test StrictMode._failed(mproof(f))
    end
    for f in (mclean..., mcaught...)
        @test isempty(StrictModeTest.divergence_report(f, mt; guarantees = (:noalloc,)))
    end
end

@testitem "reading the caught exception is not an allocation" begin
    using StrictMode, StrictModeTest, Test

    module ReadsErr
    const NEG = ArgumentError("negative")
    const BIG = DomainError(0)
    # The handler returns, and reads the exception it caught: `jl_current_exception` loads it.
    @noinline function reads_err(i::Int)
        try
            i < 0 && throw(NEG)
            i > 100 && throw(BIG)
        catch err
            return err isa ArgumentError ? 0 : -1
        end
        return i
    end
    # Failing control: the handler that returns also builds a string from what it caught.
    @noinline function shows_err(i::Int)
        try
            i < 0 && throw(NEG)
            i > 100 && throw(BIG)
        catch err
            return length(sprint(showerror, err))
        end
        return i
    end
    end
    R = ReadsErr
    R.reads_err(1); R.reads_err(-1); R.shows_err(1); R.shows_err(-1)
    sites = StrictModeTest._raw_allocs_unfiltered(R.reads_err, (Int,))
    @test any(a -> a isa StrictModeTest.AllocCheck.AllocatingRuntimeCall && a.name == "jl_current_exception", sites)
    proof(f) = only(StrictModeTest._proof_findings(f, (Int,), (:noalloc,)))
    @test !StrictMode._failed(proof(R.reads_err))
    @test !StrictMode._failed(only(StrictMode.findings(R.reads_err, (Int,); guarantees = (:noalloc,))))
    @test StrictMode._failed(proof(R.shows_err))
end
