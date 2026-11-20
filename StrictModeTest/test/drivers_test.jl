# The drivers that gate a whole scope, and the data half that reports without throwing.

@testitem "the drivers collect every failure and raise once" setup = [Fixtures] begin
    using StrictMode, StrictModeTest
    err = try
        test_signatures(
            [(Fixtures.clean, Fixtures.T3), (Fixtures.allocs, (Int,)), (Fixtures.boxy, Fixtures.THET)];
            guarantees = (:noalloc,)
        )
        nothing
    catch e
        e
    end
    @test err isa StrictViolation
    # Both failing signatures must appear: a gate that stops at the first bad method leaves the rest
    # unevaluated, which is how a sweep reports less than it checked.
    @test occursin("allocs", err.details)
    @test occursin("boxy", err.details)
end

@testitem "test_registered reports its count and re-proves the registry" setup = [Fixtures] begin
    using StrictMode, StrictModeTest
    old = copy(StrictMode.STRICT_REGISTRY)
    try
        empty!(StrictMode.STRICT_REGISTRY)
        StrictMode.register_strict!(Fixtures.clean, Fixtures.T3; guarantees = (:noalloc,))
        @test_logs (:info,) match_mode = :any test_registered()
        StrictMode.register_strict!(Fixtures.allocs, (Int,); guarantees = (:noalloc,))
        @test_throws StrictViolation test_registered()
    finally
        empty!(StrictMode.STRICT_REGISTRY)
        merge!(StrictMode.STRICT_REGISTRY, old)
    end
end

@testmodule ProofAuditDemo begin
    hot(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    cold(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
end

@testitem "proof_findings / proof_audit return proved verdicts as DATA" setup = [ProofAuditDemo] begin
    using StrictMode, StrictModeTest
    ProofAuditDemo.hot((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
    ProofAuditDemo.cold((1, 2.0, 3.0f0))

    # `test_compiled` throws on this module, so it cannot hand back findings for it — which is
    # exactly the case an agent wants them in. `proof_findings`/`proof_audit` are the data half.
    @test_throws StrictViolation test_compiled(ProofAuditDemo; guarantees = (:noboxing,))

    fs = proof_findings(ProofAuditDemo; guarantees = (:noboxing,))
    @test fs isa Vector{StrictMode.StrictFinding}
    @test any(f -> f.func == "cold" && StrictMode._failed(f), fs)
    @test any(f -> f.func == "hot" && f.status === :pass, fs)

    fa = proof_audit(ProofAuditDemo; sweep = true, guarantees = (:noboxing,))
    @test fa isa Vector{StrictMode.StrictFinding}
    @test StrictMode.nfailures(fa) >= 1
    @test occursin("\"status\":\"fail\"", format_findings(fa; format = :json))
end

@testitem "proof_audit really is the PROOF, not the scan" begin
    using StrictMode, StrictModeTest
    # A finding says which engine reached it, so a `proof_findings` that had quietly fallen back to
    # the scan would carry the scan's tier. The two agree on the verdict here: a `Float64` stored
    # into a `Ref{Any}` is boxed.
    store!(r::Base.RefValue{Any}, x::Float64) = (r[] = x; nothing)
    T = (Base.RefValue{Any}, Float64)
    scan = only(StrictMode.findings(store!, T; guarantees = (:noboxing,)))
    proof = only(proof_findings(store!, T; guarantees = (:noboxing,)))
    @test StrictMode._failed(scan) && scan.tier === :report
    @test proof.status === :fail && proof.tier === :proof
end

@testitem "test_coverage gates on undeclared methods" begin
    using StrictMode, StrictModeTest

    module CovGate
    kernel(x::Int) = x + 1
    helper(x::Int) = x * 2
    end

    StrictMode.clear_declarations!()

    # Undeclared: the gate raises and names what is missing.
    err = try
        test_coverage(CovGate)
        nothing
    catch e
        e
    end
    @test err isa StrictMode.StrictViolation
    @test occursin("kernel", err.details) && occursin("helper", err.details)

    # Declared and exempted: the gate passes.
    StrictMode.register_strict!(CovGate.kernel, (Int,); guarantees = (:typestable,))
    StrictMode._exempt!(:helper)
    fs = test_coverage(CovGate)
    @test isempty(filter(StrictMode._failed, fs))

    @test_throws ArgumentError test_coverage(CovGate; require = :exported)

    StrictMode.clear_declarations!()
end

@testitem "test_exemptions reports an opt-out the proofs no longer need" begin
    using StrictMode, StrictModeTest

    module RetireEx
    using StrictMode
    clean(x::Float64) = x * 2.0          # satisfies :noalloc and :typestable
    dirty(n::Int) = collect(1:n)         # really does allocate
    end

    StrictMode.clear_declarations!()
    RetireEx.clean(1.0)
    RetireEx.dirty(2)

    # Both marked cold. One of them did not need to be.
    StrictMode._exempt!(:clean; reason = "assumed hot-path-irrelevant")
    StrictMode._exempt!(:dirty; reason = "allocates on purpose")

    fs = test_exemptions(RetireEx)
    names = Set(f.func for f in fs)
    @test "clean" in names            # the proofs pass, so the opt-out hides nothing
    @test !("dirty" in names)         # still needed, so not reported

    # Advice, never a failure: tidy-up work must not be able to fail a build.
    @test all(f -> f.status === :info, fs)
    @test StrictMode.nfailures(fs) == 0
    @test all(f -> f.tier === :proof, fs)   # only a proof may say this

    StrictMode.clear_declarations!()
end

@testitem "test_coverage says so when nothing is in scope" begin
    using StrictMode, StrictModeTest, Test
    module NoExports
    helper(x::Int) = x * 2
    end
    # No exported function: `require = :public` judges nothing, which must not read as covered.
    @test_logs (:warn, r"0 checks") match_mode = :any test_coverage(NoExports; require = :public)
end

@testitem "test_coverage stays quiet when every method in scope is declared" begin
    using StrictMode, StrictModeTest, Test
    module FullCov
    hid(x::Int) = x + 1
    end
    FullCov.hid(1)
    StrictMode.register_strict!(FullCov.hid, (Int,); mod = FullCov)
    @test_logs StrictModeTest.test_coverage(FullCov)
end

@testitem "test_waits_yield fails a wait that never yields, and passes one that does" begin
    using StrictMode, StrictModeTest
    module Waits
    const FLAG = Threads.Atomic{Bool}(false)
    @noinline function spin_worker()                    # pause() only: no other task can run here
        for _ in 1:(1 << 20)
            FLAG[] && return nothing
            ccall(:jl_cpu_pause, Cvoid, ())
        end
        nothing
    end
    @noinline polite_worker() = (while !FLAG[]; yield(); end; nothing)
    spin_start() = (t = Threads.@spawn spin_worker(); FLAG[] = true; wait(t); FLAG[] = false; nothing)
    polite_start() = (FLAG[] = true; t = Threads.@spawn polite_worker(); wait(t); FLAG[] = false; nothing)
    async_spin() = (t = @async spin_worker(); FLAG[] = true; wait(t); FLAG[] = false; nothing)
    no_spawn() = 1 + 1
    end
    Waits.spin_start(); Waits.polite_start(); Waits.async_spin(); Waits.no_spawn()
    @test_throws "never yields" StrictModeTest.test_waits_yield(Waits.spin_start, ())
    @test StrictModeTest.test_waits_yield(Waits.polite_start, ()) isa StrictMode.SpinWaitReport
    # What the scan did not judge fails too: a bound task, and a call that spawns no task at all.
    @test_throws "bound task" StrictModeTest.test_waits_yield(Waits.async_spin, ())
    @test_throws "spawns no task" StrictModeTest.test_waits_yield(Waits.no_spawn, ())
end

@testitem "test_history_invariant fails a result that moves with process history" begin
    using StrictMode, StrictModeTest
    module HistGate
    const FLOOR = Threads.Atomic{Int}(1000)
    @noinline mt_work() = FLOOR[]
    mysum(x::Vector{Float64}) = length(x) < mt_work() ? foldl(+, x) : foldr(+, x)
    bigcall() = (FLOOR[] = 1; nothing)
    end
    x = [1.0e8, 1.0, -1.0e8, 1.0e-8, 3.0, 1.0e-3]
    try
        @test_throws "depends on what ran before" StrictModeTest.test_history_invariant(
            HistGate.mysum, x; movers = (HistGate.bigcall,)
        )
    finally
        HistGate.FLOOR[] = 1000
    end
    @test_throws "movers` is empty" StrictModeTest.test_history_invariant(HistGate.mysum, x; movers = ())
end

@testitem "test_waits_yield judges the tasks of a Threads.@threads loop" begin
    using StrictMode, StrictModeTest
    module ThreadsWait
    const FLAG = Threads.Atomic{Bool}(true)
    spin(v::Vector{Float64}) =
        (Threads.@threads for i in eachindex(v); while !FLAG[]; ccall(:jl_cpu_pause, Cvoid, ()); end; v[i] = i; end; nothing)
    plain(v::Vector{Float64}) = (Threads.@threads for i in eachindex(v); v[i] = i; end; nothing)
    end
    ThreadsWait.spin(zeros(4)); ThreadsWait.plain(zeros(4))
    @test_throws "never yields" StrictModeTest.test_waits_yield(ThreadsWait.spin, (Vector{Float64},))
    @test StrictModeTest.test_waits_yield(ThreadsWait.plain, (Vector{Float64},)) isa StrictMode.SpinWaitReport
end

@testitem "an exemption covers only the module that declared it" begin
    using StrictMode, StrictModeTest
    module LeakA
    using StrictMode
    @strict_exempt build_q(n::Int) = collect(1:n)
    end
    module LeakB
    using StrictMode
    build_q(n::Int) = collect(1:n)              # same name, not exempted here
    end
    LeakA.build_q(3); LeakB.build_q(3)
    @test StrictMode._is_exempt(LeakA.build_q)
    @test !StrictMode._is_exempt(LeakB.build_q)
    @test StrictMode._is_exempt(LeakA.build_q, (Int,), :noalloc)
    @test !StrictMode._is_exempt(LeakB.build_q, (Int,), :noalloc)
    @test_throws StrictViolation test_compiled(LeakB; guarantees = (:noalloc,))
end

@testitem "test_signatures fails a signature that always throws; a sweep notes it" begin
    using StrictMode, StrictModeTest

    module ProofAlwaysThrows
    bad(x::Int) = x + "a"                               # no `+(::Int, ::String)`
    kwreq(x::Int; n::Int) = x + n                       # `n` is required
    wrongsig(v::AbstractVector, k) = v[k] = "s"         # a `String` into a `Vector{Float64}`
    need(::Nothing, f::Symbol) = throw(ArgumentError("no $f"))
    ok(x::Int) = x + 1
    end
    A = ProofAlwaysThrows
    gs = (:typestable, :noalloc, :noboxing, :trim_compatible)

    for (f, types) in ((A.bad, (Int,)), (A.kwreq, (Int,)), (A.wrongsig, (Vector{Float64}, Int)))
        fs = proof_findings(f, types; guarantees = gs)
        @test all(x -> x.status === :info && x.code === :SM0208 && x.tier === :proof, fs)
        @test_throws StrictViolation test_signatures([(f, types)]; guarantees = gs)
        @test_throws "always throws" test_signatures([(f, types)]; guarantees = gs)
    end
    @test length(test_signatures([(A.ok, (Int,))]; guarantees = gs)) == 4

    # A module's error helper is not a defect, so the sweep carries the note and passes.
    try
        A.need(nothing, :a)
    catch
    end
    A.ok(1)
    swept = test_compiled(A; guarantees = (:typestable, :noalloc))
    @test any(x -> x.func == "need" && x.code === :SM0208, swept)
    @test_throws MethodError @test_noalloc A.bad(1)
end

@testitem "test_compiled covers a method added to another module's function" begin
    using StrictMode, StrictModeTest, Test

    module ForeignGate
    using StrictMode
    struct MyT
        v::Int
    end
    Base.getproperty(u::Untrusted{MyT}, s::Symbol) = getfield(u, :x)
    own(x::Int) = x + 1
    end
    Untrusted(ForeignGate.MyT(7)).x; ForeignGate.own(1)
    @test_throws "getproperty" test_compiled(ForeignGate; guarantees = (:trusted,))
    @test test_compiled(ForeignGate; guarantees = (:trusted,), exempt = (:getproperty,)) isa Vector
    Base.delete_method(which(getproperty, (Untrusted{ForeignGate.MyT}, Symbol)))
end
