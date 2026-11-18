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
    # The scan reports the caller as a note; the proof still sees the allocation.
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

    # A dispatch that only a `catch` reaches is skipped, as AllocCheck skips it.
    recover(x::Float64) = try
        x < 0 ? throw(DomainError(x)) : sqrt(x)
    catch
        HOOK[](x)::Float64
    end
    @test isempty(StrictModeTest._native_dispatches(recover, (Float64,)))
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
