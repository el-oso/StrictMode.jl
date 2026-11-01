# :concurrency_safe (+ Phase-2 :no_threadid_state / pool_balance). Value-free IR scans — these run
# with or without the AllocCheck/JET backend.

# Shared plan-like fixtures (a composite plan holding child plans with embedded scratch buffers).
@testitem "concurrency: PASS on a read-only immutable apply" begin
    using StrictMode
    mutable struct CBuf1
        data::Vector{Float64}
    end
    struct CPlan1
        scr::CBuf1; n::Int
    end
    # reads the plan, writes only x and the passed scratch → safe to share
    function apply_ro!(plan::CPlan1, x::Vector{Float64}, scr::Vector{Float64})
        @inbounds for i in eachindex(x)
            scr[i] = x[i] * plan.n
            x[i] = scr[i]
        end
        return x
    end
    p = CPlan1(CBuf1([0.0]), 3); x = ones(4); s = zeros(4)
    r = @assert_concurrency_safe apply_ro!(p, x, s)
    @test r === x
    @test isempty(StrictMode.concurrency_findings(apply_ro!, (CPlan1, Vector{Float64}, Vector{Float64})))
end

@testitem "concurrency: FAIL on writing a plan field (setfield! on self)" begin
    using StrictMode
    mutable struct MPlan2
        n::Int
    end
    function apply_setfield!(plan::MPlan2, x::Vector{Float64}, scr::Vector{Float64})
        plan.n = length(x)   # mutates the shared plan
        return x
    end
    @test_throws StrictViolation @assert_concurrency_safe apply_setfield!(MPlan2(1), ones(2), zeros(2))
end

@testitem "concurrency: FAIL on storing into a plan-reachable buffer" begin
    using StrictMode
    mutable struct CBuf3
        data::Vector{Float64}
    end
    struct CPlan3
        scr::CBuf3
    end
    function apply_bufstore!(plan::CPlan3, x::Vector{Float64}, scr::Vector{Float64})
        @inbounds plan.scr.data[1] = x[1]   # heap store reachable through the plan
        return x
    end
    p = CPlan3(CBuf3([0.0]))
    @test_throws StrictViolation @assert_concurrency_safe apply_bufstore!(p, ones(2), zeros(2))
end

@testitem "concurrency: FAIL on the composite convenience-path race (interprocedural)" begin
    using StrictMode
    mutable struct CBuf4
        data::Vector{Float64}
    end
    struct CChild4
        scr::CBuf4
    end
    struct CPlan4
        children::Vector{CChild4}
    end
    # a child's convenience path that mutates its OWN embedded scratch (the real race)
    @noinline function child_convenience!(c::CChild4, x::Vector{Float64})
        @inbounds c.scr.data[1] = x[1]
        return nothing
    end
    function apply_composite!(plan::CPlan4, x::Vector{Float64}, scr::Vector{Float64})
        child_convenience!(plan.children[1], x)   # plan-reachable child → mutated one frame down
        return x
    end
    p = CPlan4([CChild4(CBuf4([0.0]))])
    @test !isempty(StrictMode.concurrency_findings(apply_composite!, (CPlan4, Vector{Float64}, Vector{Float64})))
    @test_throws StrictViolation @assert_concurrency_safe apply_composite!(p, ones(2), zeros(2))
end

@testitem "concurrency: PASS when a child path writes only the passed-in output" begin
    using StrictMode
    mutable struct CBuf5
        data::Vector{Float64}
    end
    struct CChild5
        scr::CBuf5
    end
    struct CPlan5
        children::Vector{CChild5}
    end
    # reads the child, writes only x (the scratch-passing form) → safe
    @noinline function child_readonly!(c::CChild5, x::Vector{Float64})
        @inbounds x[1] = c.scr.data[1]
        return nothing
    end
    function apply_ok!(plan::CPlan5, x::Vector{Float64}, scr::Vector{Float64})
        child_readonly!(plan.children[1], x)
        return x
    end
    @test isempty(StrictMode.concurrency_findings(apply_ok!, (CPlan5, Vector{Float64}, Vector{Float64})))
    p = CPlan5([CChild5(CBuf5([1.0]))])
    @test (@assert_concurrency_safe apply_ok!(p, ones(2), zeros(2))) !== nothing
end

@testitem "concurrency: scalar plan field read (plan.n) does not taint arithmetic" begin
    using StrictMode
    struct SPlan6
        n::Int; scale::Float64
    end
    function apply_scalar!(plan::SPlan6, x::Vector{Float64}, scr::Vector{Float64})
        @inbounds for i in eachindex(x)
            x[i] = x[i] * plan.scale + plan.n   # scalar reads → copies → not a shared write
        end
        return x
    end
    @test isempty(StrictMode.concurrency_findings(apply_scalar!, (SPlan6, Vector{Float64}, Vector{Float64})))
end

@testitem "concurrency: FAIL on handing a plan-reachable buffer to a Base mutator (push!)" begin
    using StrictMode
    struct GPlan7
        children::Vector{Int}
    end
    function apply_push!(plan::GPlan7, x::Vector{Float64}, scr::Vector{Float64})
        push!(plan.children, length(x))   # mutates plan-reachable storage via Base
        return x
    end
    @test !isempty(StrictMode.concurrency_findings(apply_push!, (GPlan7, Vector{Float64}, Vector{Float64})))
end

@testitem "concurrency: disabled build expands to the bare call (zero cost)" begin
    # With checks enabled in the test project this still runs the check, but confirm the macro
    # returns the value and does not throw on safe code.
    using StrictMode
    struct DPlan8
        n::Int
    end
    f8(plan::DPlan8, x::Vector{Float64}) = (x[1] = plan.n; x)
    x = zeros(1)
    @test (@assert_concurrency_safe f8(DPlan8(5), x)) === x
    @test x[1] == 5.0
end

# ── Phase 2 ─────────────────────────────────────────────────────────────────────────────────

@testitem "no_threadid_state: FAIL on buffer indexed by threadid()" begin
    using StrictMode
    using Base.Threads: threadid
    function accum_tid!(buf::Vector{Int})
        @inbounds buf[threadid()] += 1   # task-migration hazard
        return buf
    end
    @test !isempty(StrictMode.threadid_state_findings(accum_tid!, (Vector{Int},)))
    @test_throws StrictViolation @assert_no_threadid_state accum_tid!(zeros(Int, 8))
end

@testitem "no_threadid_state: PASS on a per-index write with no threadid" begin
    using StrictMode
    function accum_plain!(buf::Vector{Int}, i::Int)
        @inbounds buf[i] += 1
        return buf
    end
    @test isempty(StrictMode.threadid_state_findings(accum_plain!, (Vector{Int}, Int)))
    @test (@assert_no_threadid_state accum_plain!(zeros(Int, 4), 1)) !== nothing
end

@testitem "pool_balance_report: balanced vs imbalanced take!/put!" begin
    using StrictMode
    function balanced!(ch::Channel{Int})
        v = take!(ch); put!(ch, v); return v
    end
    function leaky!(ch::Channel{Int})
        return take!(ch)   # no matching put!
    end
    @test pool_balance_report(balanced!, (Channel{Int},)).balanced
    @test !pool_balance_report(leaky!, (Channel{Int},)).balanced

    # A signature with no IR to read counts nothing, and a count of nothing balances — so a
    # returned verdict would be indistinguishable from a real one. "Nothing to count" and
    # "counted, and they match" must not render alike, so this raises, as the other two checks in
    # this file do.
    @test_throws StrictMode._UnanalyzableSignature pool_balance_report(balanced!, (String,))
    @test_throws "could not analyze" pool_balance_report(balanced!, (String,))
    @test_throws "UNKNOWN, not satisfied" pool_balance_report(balanced!, (String,))
end

@testitem "taint flows through a struct built from a shared argument" begin
    using StrictMode

    # `:new` builds every wrapper — a struct, and a closure's captures — and a scan reading only
    # `:call`/`:invoke` statements loses the shared object the moment it is wrapped.
    #
    # `@noinline` is what makes this bite, and it is the only shape that distinguishes the two
    # behaviors. An INLINABLE wrapper is caught either way: inlining rewrites the store to go
    # straight through the argument, so the wrapper never stands between them. Measured, findings
    # for the same write: inlinable 1 and 1, `@noinline` 0 without `:new` taint and 1 with it.
    struct Holder
        buf::Vector{Float64}
    end
    @noinline poke!(h::Holder) = (h.buf[1] += 1.0; h)
    wrapped!(buf::Vector{Float64}) = poke!(Holder(buf))
    direct!(buf::Vector{Float64}) = (buf[1] += 1.0; buf)
    readonly(buf::Vector{Float64}) = @inbounds buf[1] + 1.0

    wrapped!(zeros(2)); direct!(zeros(2)); readonly(zeros(2))

    # The `:invoke` of `poke!` carries `%new(Holder, _2)`, so the shared argument is only reachable
    # if the `:new` passed its taint on.
    @test !isempty(StrictMode.concurrency_findings(wrapped!, (Vector{Float64},)))
    @test !isempty(StrictMode.concurrency_findings(direct!, (Vector{Float64},)))
    # …and the wrapper does not make a read look like a write.
    @test isempty(StrictMode.concurrency_findings(readonly, (Vector{Float64},)))
end

@testitem "a task's write to a captured buffer is a write" begin
    using StrictMode

    # `Threads.@spawn` lowers to a closure built by `:new` and handed to `jl_new_task`. The body
    # runs as a method of its own, so a scan that follows only calls never enters it and the write
    # reads as no write at all — the plan looks read-only while a task is mutating it.
    function racy!(buf::Vector{Float64})
        t = Threads.@spawn (buf[1] += 1.0)
        wait(t)
        return buf
    end
    # Reading the capture is not writing it, and a task-local buffer is nobody else's business.
    reader(buf::Vector{Float64}) = fetch(Threads.@spawn sum(buf))
    function private!(buf::Vector{Float64})
        n = length(buf)
        return fetch(Threads.@spawn (local v = zeros(n); v[1] += 1.0; v[1]))
    end

    racy!(zeros(2)); reader(zeros(2)); private!(zeros(2))

    viols = StrictMode.concurrency_findings(racy!, (Vector{Float64},))
    @test !isempty(viols)
    # The report says HOW it got there, because a write inside a task is a different problem from
    # the same write in the caller's own body.
    @test any(v -> occursin("task closure", v.message), viols)

    @test isempty(StrictMode.concurrency_findings(reader, (Vector{Float64},)))
    @test isempty(StrictMode.concurrency_findings(private!, (Vector{Float64},)))
end

@testitem "the threadid guarantee is swept, with notaskstate as the fast clear" begin
    using StrictMode

    @test :no_threadid_state in StrictMode._GUARANTEES
    @test StrictMode._code(:no_threadid_state) === :SM0013

    tls = [0.0]
    dirty() = (tls[Threads.threadid()] += 1.0)
    cleankern(x) = x + 1.0
    gref = Ref(1.0)
    unprovable(x) = x + gref[]        # no task state, and the compiler cannot say so

    @test StrictMode.effect_holds(StrictMode.effects(cleankern, (Float64,)), :notaskstate)
    @test !StrictMode.effect_holds(StrictMode.effects(unprovable, (Float64,)), :notaskstate)

    one_finding(f, tt) = only(StrictMode.findings(f, tt; guarantees = (:no_threadid_state,)))
    @test StrictMode._failed(one_finding(dirty, ()))
    @test !StrictMode._failed(one_finding(cleankern, (Float64,)))
    # An unproven signature falls through to the taint scan and passes there; a missing proof is
    # not a finding.
    @test !StrictMode._failed(one_finding(unprovable, (Float64,)))
end

@testitem "the concurrency guarantee is swept, and its status follows certainty" begin
    using StrictMode

    @test :concurrency_safe in StrictMode._GUARANTEES
    @test StrictMode._code(:concurrency_safe) === :SM0014
    @test StrictMode._suggestion(:concurrency_safe) != ""

    # Absent from `:all`, which runs at a consumer's own precompile: a sweep reads argument 1, and
    # a `!` method writes argument 1 by convention, so this must not be able to stop a module load.
    @test !(:concurrency_safe in StrictMode.policy_sets()[:all])

    module Plans
    mutable struct Plan
        x::Int
    end
    writes(p::Plan) = (p.x = 1; nothing)        # a write the scan READS
    reads(p::Plan) = p.x + 1
    # The callback is `Any`-typed, so the call through it cannot be resolved at ANY call site.
    # A function passed as an argument would not do: the macro reads the argument's concrete type,
    # so `opaque(p, identity)` resolves to `identity` and leaves nothing uncertain.
    mutable struct Hooked
        x::Int
        cb::Any
    end
    opaque(h::Hooked) = (h.cb(h); nothing)
    end

    Plans.writes(Plans.Plan(0)); Plans.reads(Plans.Plan(0))
    Plans.opaque(Plans.Hooked(0, _ -> nothing))

    one_of(f, tt) = only(StrictMode.findings(f, tt; guarantees = (:concurrency_safe,)))

    # A write it read is a failure; a record it could not resolve is informational, not a failure.
    wf = one_of(Plans.writes, (Plans.Plan,))
    @test StrictMode._failed(wf)
    @test occursin("is written", wf.reason)

    of = one_of(Plans.opaque, (Plans.Hooked,))
    @test !StrictMode._failed(of)
    @test of.status === :info
    @test occursin("cannot prove", of.reason)

    @test !StrictMode._failed(one_of(Plans.reads, (Plans.Plan,)))

    # The macro decides per finding rather than per guarantee, so the uncertain shape warns and the
    # certain one still throws even though `_guarantee_gates(:concurrency_safe)` is false.
    @test !StrictMode._guarantee_gates(:concurrency_safe)
    @test_throws StrictMode.StrictViolation (@assert_concurrency_safe Plans.writes(Plans.Plan(0)))
    @test_logs (:warn,) match_mode = :any (
        @assert_concurrency_safe Plans.opaque(Plans.Hooked(0, _ -> nothing))
    )
end

@testitem "a write past max_depth warns, because the scan never read it" begin
    using StrictMode

    # The pin for the boundary the certainty rule moves: the scan follows a tainted value through
    # non-inlined frames up to `max_depth` and then stops. The write below is REAL, so this is not
    # a false positive being softened — it is the scan declining to claim what it did not see.
    module DeepW
    mutable struct P
        buf::Vector{Float64}
    end
    @noinline l5(b) = (b[1] = 1.0; nothing)
    @noinline l4(b) = l5(b)
    @noinline l3(b) = l4(b)
    @noinline l2(b) = l3(b)
    @noinline l1(b) = l2(b)
    deep!(p::P) = (l1(p.buf); nothing)
    near!(p::P) = (p.buf[1] = 1.0; nothing)
    end

    p = DeepW.P(zeros(2))
    DeepW.deep!(p); DeepW.near!(p)

    far = StrictMode.concurrency_findings(DeepW.deep!, (DeepW.P,))
    @test !isempty(far)
    @test !any(v -> v.certain, far)                  # recorded, but not as something it read
    @test occursin("max_depth", far[1].message)

    near = StrictMode.concurrency_findings(DeepW.near!, (DeepW.P,))
    @test any(v -> v.certain, near)

    # So the near write raises and the far one warns. Raising `max_depth` reaches it.
    @test_throws StrictMode.StrictViolation (@assert_concurrency_safe DeepW.near!(p))
    @test_logs (:warn,) match_mode = :any (@assert_concurrency_safe DeepW.deep!(p))
    @test any(
        v -> v.certain, StrictMode.concurrency_findings(DeepW.deep!, (DeepW.P,); max_depth = 8)
    )
end

@testitem "a findings vector renders the same however it is shown" begin
    using StrictMode

    module Shown
    kern(x::Float64) = x * 2.0
    end
    Shown.kern(1.0)

    fs = StrictMode.findings(Shown.kern, (Float64,); guarantees = (:typestable, :noalloc))
    two_arg = sprint(show, fs)
    mime = sprint(show, MIME"text/plain"(), fs)
    @test two_arg == mime                                  # no one-line array fallback
    @test occursin("-element Vector{StrictFinding}", two_arg)

    # An informational report expands rather than collapsing to a count: the reporting lints return
    # `:info` only, so a tally would render their whole result as a number.
    info = StrictMode.specialization_report(StrictMode; max_specializations = 1)
    @test !isempty(info)
    @test all(f -> f.status === :info, info)
    rendered = sprint(show, info)
    @test count(==('\n'), rendered) > 1
    @test occursin("informational", rendered)

    @test sprint(show, StrictMode.StrictFinding[]) == "0 StrictMode findings"
end
