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
end
