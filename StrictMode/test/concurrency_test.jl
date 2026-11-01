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

@testitem "an atomic read-modify-write is a write, in both concurrency scans" begin
    using StrictMode

    # `@atomic x.f += v` lowers to `Expr(:invoke_modify, …)`, a third call head beside `:call` and
    # `:invoke`. A scan matching only the first two reads it as no call at all and reports a clean
    # pass on a plan an apply atomically increments — a false pass, which is what these scans exist
    # to prevent.
    module Atomics
    mutable struct Plan
        @atomic counter::Int
        buf::Vector{Int}
    end
    rmw(p::Plan) = (@atomic p.counter += 1; nothing)
    swap(p::Plan) = (@atomicswap p.counter = 2; nothing)
    store(p::Plan) = (@atomic p.counter = 1; nothing)
    readonly(p::Plan) = p.counter + 1
    end

    p = Atomics.Plan(0, [0])
    Atomics.rmw(p); Atomics.swap(p); Atomics.store(p); Atomics.readonly(p)

    for (name, f) in (("rmw", Atomics.rmw), ("swap", Atomics.swap), ("store", Atomics.store))
        vs = StrictMode.concurrency_findings(f, (Atomics.Plan,))
        @test !isempty(vs)
        @test any(v -> v.certain, vs)        # an atomic write is one the scan READ
    end
    @test isempty(StrictMode.concurrency_findings(Atomics.readonly, (Atomics.Plan,)))

    # The threadid scan shares the same filter, and that guarantee GATES.
    # Atomic indexing is defined on `GenericMemory`, not on `Array`, so the per-thread buffer is a
    # `Memory` here.
    module TidAtomics
    const FLAT = AtomicMemory{Int}(undef, Threads.maxthreadid())
    rmw() = (@atomic FLAT[Threads.threadid()] += 1; nothing)
    end
    for i in 1:Threads.maxthreadid()
        @atomic TidAtomics.FLAT[i] = 0
    end
    TidAtomics.rmw()
    @test !isempty(StrictMode.threadid_state_findings(TidAtomics.rmw, ()))

    # An atomic write that neither store table names must not be cleared as read-only either.
    for n in (:setglobal!, :swapglobal!, :atomic_pointerset, :atomic_pointermodify)
        m = isdefined(Core, n) ? Core : Core.Intrinsics
        @test !StrictMode._is_readonly_builtin(GlobalRef(m, n))
    end
    # …while a builtin that cannot mutate still is, whichever module resolved its binding.
    @test StrictMode._is_readonly_builtin(GlobalRef(StrictMode, :(===)))
end

@testitem "the warn path does not assert a mutation the scan never saw" begin
    using StrictMode

    module Headline
    mutable struct P
        buf::Vector{Float64}
    end
    @noinline d5(b) = (b[1] = 1.0; nothing)
    @noinline d4(b) = d5(b)
    @noinline d3(b) = d4(b)
    @noinline d2(b) = d3(b)
    @noinline d1(b) = d2(b)
    far!(p::P) = (d1(p.buf); nothing)
    near!(p::P) = (p.buf[1] = 1.0; nothing)
    end

    p = Headline.P(zeros(2))
    Headline.far!(p); Headline.near!(p)

    # The certain case states the mutation; the uncertain case must not.
    err = try
        @assert_concurrency_safe Headline.near!(p)
        nothing
    catch e
        e
    end
    @test err isa StrictMode.StrictViolation
    @test occursin("is mutated", sprint(showerror, err))

    # The uncertain case warns, and the warning says what the scan actually established.
    @test_logs (:warn, r"cannot establish that the plan argument is read-only") match_mode = :any (
        @assert_concurrency_safe Headline.far!(p)
    )
    @test_logs (:warn, r"unproven, not disproven") match_mode = :any (
        @assert_concurrency_safe Headline.far!(p)
    )
end

@testitem "a store through a value loaded from a threadid slot is threadid state" begin
    using StrictMode

    # The scan taints `threadid()` and the reference built from it. Without carrying that mark
    # through a PROJECTION, a store into the object loaded back out of the slot has a container in
    # no set at all — and this guarantee gates, so it was a silent pass on an array of per-thread
    # mutable cells, which is an ordinary way to write exactly this hazard.
    module Slots
    mutable struct Cell
        value::Int
    end
    mutable struct ACell
        @atomic value::Int
    end
    struct Wrap
        v::Vector{Int}
    end
    const FLAT = zeros(Int, 8)
    const PL = [Cell(0) for _ in 1:8]
    const AC = [ACell(0) for _ in 1:8]
    const NB = [[0] for _ in 1:8]
    const WR = [Wrap([0]) for _ in 1:8]
    const REFS = [Ref(0) for _ in 1:8]
    const ANYS = Any[Cell(0) for _ in 1:8]
    const OUT = zeros(Int, 8)
    const CELLS = Vector{Cell}(undef, 8)
    const STRS = ["a" for _ in 1:8]
    const LKS = [ReentrantLock() for _ in 1:8]
    tf() = Threads.threadid()

    direct() = (FLAT[tf()] = 1; nothing)
    field() = (PL[tf()].value = 1; nothing)
    atomic_field() = (@atomic AC[tf()].value += 1; nothing)
    nested() = (NB[tf()][1] = 2; nothing)
    through_immutable() = (WR[tf()].v[1] = 2; nothing)
    via_local() = (c = PL[tf()]; c.value = 1; nothing)
    ref_slot() = (REFS[tf()][] = 1; nothing)
    dynamic() = (setproperty!(ANYS[tf()], :value, 1); nothing)

    read_field() = PL[tf()].value
    copy_scalar() = (OUT[1] = PL[tf()].value; nothing)
    store_elsewhere() = (CELLS[1] = PL[tf()]; nothing)
    copy_int() = (x = FLAT[tf()]; OUT[1] = x; nothing)
    read_len() = length(STRS[tf()])
    read_atomic() = (@atomic AC[tf()].value)
    read_ref() = REFS[tf()][]

    striped_lock() = (lk = LKS[tf()]; lock(lk); OUT[1] = 1; unlock(lk); nothing)
    @noinline bump!(c::Cell) = (c.value = 1; nothing)
    through_callee() = (bump!(PL[tf()]); nothing)
    end

    for f in (
            Slots.direct, Slots.field, Slots.atomic_field, Slots.nested,
            Slots.through_immutable, Slots.via_local, Slots.ref_slot, Slots.dynamic,
            Slots.read_field, Slots.copy_scalar, Slots.store_elsewhere, Slots.copy_int,
            Slots.read_len, Slots.read_atomic, Slots.read_ref, Slots.striped_lock,
            Slots.through_callee,
        )
        f()
    end
    scan(f) = StrictMode.threadid_state_findings(f, ())

    # Every one of these writes state the running task may not own after a migration.
    for (name, f) in (
            ("direct", Slots.direct), ("field", Slots.field),
            ("atomic_field", Slots.atomic_field), ("nested", Slots.nested),
            ("through_immutable", Slots.through_immutable), ("via_local", Slots.via_local),
            ("ref_slot", Slots.ref_slot), ("dynamic", Slots.dynamic),
        )
        vs = scan(f)
        @test !isempty(vs)
        @test all(v -> v.certain, vs)          # the store and its container were both READ
    end

    # Reading from a per-thread slot is not the hazard, and neither is copying a value out of one.
    # `store_elsewhere` is the shape that decides where the mark goes: the loaded cell is in the
    # store's VALUE position, and only the container position is consulted.
    for (name, f) in (
            ("read_field", Slots.read_field), ("copy_scalar", Slots.copy_scalar),
            ("store_elsewhere", Slots.store_elsewhere), ("copy_int", Slots.copy_int),
            ("read_len", Slots.read_len), ("read_atomic", Slots.read_atomic),
            ("read_ref", Slots.read_ref),
        )
        @test isempty(scan(f))
    end

    # Two documented outcomes, pinned so a change in either is visible.
    #
    # A lock striped by thread is reported. It is not a data race — a `ReentrantLock` is owned by
    # the task, not the thread — but the inlined fast path writes a field of a lock selected by
    # `threadid()`, which is what this guarantee says. Striping locks that way is pointless under
    # migration anyway, so the report is a lead rather than noise.
    @test !isempty(scan(Slots.striped_lock))

    # A write inside a callee the scan does not enter stays missed: this scan reads one method's IR
    # and does not follow `:invoke`. There is no other signature that catches it either — the
    # threadid taint is in the caller and the store is in the callee, and the callee alone has no
    # `threadid()` in it to taint anything. Unlike `:concurrency_safe`, which recurses to
    # `max_depth`, this scan has no knob that reaches it.
    @test isempty(scan(Slots.through_callee))
    @test isempty(StrictMode.threadid_state_findings(Slots.bump!, (Slots.Cell,)))
end

@testitem "an isbits plan argument cannot be written, and a `!` name is not a violation" begin
    using StrictMode

    module Shapes
    mutable struct Plan
        x::Int
    end
    const OUT = zeros(Int, 4)

    # Argument 1 is an `Int`. The only stores go into arrays this method allocates itself, reached
    # through an inlined helper. An `Int` is a COPY, so nothing is reachable only through it and no
    # store the caller's value could observe exists — seeding it as shared taints every index
    # derived from it, which made a write to a fresh local buffer read as a write to the plan.
    @inline function link!(parent, ancestor, i, k)
        while i != 0
            nxt = ancestor[i]
            ancestor[i] = k
            parent[i] = k
            i = nxt
        end
        return nothing
    end
    function etree(n::Int, colptr::Vector{Int}, rowval::Vector{Int})
        parent = zeros(Int, n)
        ancestor = zeros(Int, n)
        for k in 1:n, p in colptr[k]:(colptr[k + 1] - 1)
            link!(parent, ancestor, rowval[p], k)
        end
        return parent
    end

    writes(p::Plan) = (p.x = 1; nothing)
    reads(p::Plan) = p.x + 1
    fill_out!(out::Vector{Int}, p::Plan) = (out[1] = p.x; nothing)
    at_two(n::Int, p::Plan) = (p.x = n; nothing)
    end

    Shapes.etree(2, [1, 1, 1], Int[])
    Shapes.writes(Shapes.Plan(0))
    Shapes.reads(Shapes.Plan(0))
    Shapes.fill_out!(Shapes.OUT, Shapes.Plan(1))
    Shapes.at_two(1, Shapes.Plan(0))

    # An isbits plan argument reports nothing at all: the guarantee holds trivially.
    @test isempty(StrictMode.concurrency_findings(Shapes.etree, (Int, Vector{Int}, Vector{Int})))
    @test isempty(StrictMode.concurrency_findings(Shapes.at_two, (Int, Shapes.Plan); self_arg = 1))
    # Naming the argument that really is shared still works.
    @test !isempty(StrictMode.concurrency_findings(Shapes.at_two, (Int, Shapes.Plan); self_arg = 2))
    # And a reference-holding plan is unaffected.
    @test !isempty(StrictMode.concurrency_findings(Shapes.writes, (Shapes.Plan,)))

    one_of(f, tt) = only(StrictMode.findings(f, tt; guarantees = (:concurrency_safe,)))

    # The swept verdicts. A `!` name declares that argument 1 is written, so the sweep says it
    # cannot ask the question rather than failing — and must not say `:pass` either.
    bang = one_of(Shapes.fill_out!, (Vector{Int}, Shapes.Plan))
    @test bang.status === :info
    @test !StrictMode._failed(bang)
    @test occursin("`!` name declares", bang.reason)
    @test occursin("self=", bang.suggestion)

    @test StrictMode._failed(one_of(Shapes.writes, (Shapes.Plan,)))
    @test !StrictMode._failed(one_of(Shapes.reads, (Shapes.Plan,)))
    @test !StrictMode._failed(one_of(Shapes.etree, (Int, Vector{Int}, Vector{Int})))

    # Only the real violation counts as a failure.
    @test StrictMode.nfailures(
        [
            one_of(Shapes.writes, (Shapes.Plan,)),
            one_of(Shapes.fill_out!, (Vector{Int}, Shapes.Plan)),
            one_of(Shapes.reads, (Shapes.Plan,)),
            one_of(Shapes.etree, (Int, Vector{Int}, Vector{Int})),
        ]
    ) == 1
end

@testitem "a keyword call names the function written, and an unreadable signature has a location" begin
    using StrictMode

    module KwShapes
    mutable struct Plan
        x::Int
    end
    mutable struct Holder
        f::Any
    end
    @noinline target(p::Plan; scale::Int = 1) = p.x * scale
    const H = Holder(target)
    # The callee is `Any`-typed, so the keyword call cannot resolve and is recorded conservatively.
    dyn(p::Plan) = H.f(p; scale = 2)
    end
    KwShapes.dyn(KwShapes.Plan(3))

    # `kwcall` is Julia's keyword lowering, not a function anyone wrote, so naming it told a reader
    # nothing about what to look at.
    vs = StrictMode.concurrency_findings(KwShapes.dyn, (KwShapes.Plan,))
    @test !isempty(vs)
    @test !any(v -> v.certain, vs)                  # conservative, so the sweep reports `:info`
    @test !occursin("`kwcall`", vs[1].message)
    @test occursin("keyword call", vs[1].message)
    @test !StrictMode._failed(
        only(StrictMode.findings(KwShapes.dyn, (KwShapes.Plan,); guarantees = (:concurrency_safe,)))
    )

    # A finding a reader cannot navigate to was reported at `:0`. Where the method resolves, the
    # location is now the method's own.
    file, line = StrictMode._method_loc(KwShapes.dyn, (KwShapes.Plan,))
    @test !isempty(file)
    @test line > 0
    # With no method at all there is genuinely nothing to point at, and it still fails rather than
    # passing: "could not check" is not "is fine".
    nometh(x::Float64) = x
    u = only(StrictMode.findings(nometh, (String,); guarantees = (:concurrency_safe,)))
    @test StrictMode._failed(u)
    @test u.code === :SM0203
end

@testitem "an object built around the plan is not the plan" begin
    using StrictMode

    # The scan has two taint levels because "is the plan" and "holds a reference to the plan" are
    # different facts. A factorization points at its symbolic analysis; the analysis does not point
    # back. With one level the fresh factor either WAS the plan — so every field it initialized
    # reported, which failed four passing assertions in a consumer across three releases — or was
    # invisible, which loses a store through the factor into the plan's own arrays.
    #
    # What makes it exact rather than a guess: `:new` records WHICH field positions received a plan
    # value, so reading that field back is direct and reading a freshly-built sibling is not.
    module Factor
    struct Sym
        n::Int
        colptr::Vector{Int}
    end
    mutable struct Stats
        nnz::Int
    end
    mutable struct Fac
        sym::Sym
        ok::Bool
        stats::Stats
        buf::Vector{Float64}
    end
    struct Wrap
        buf::Vector{Int}
    end

    # Writes only state this method allocated itself. The factor holds the plan at field 1.
    @noinline function fill!(f::Fac, x::Vector{Float64})
        f.ok = true
        f.stats.nnz = 1
        f.buf[1] = x[1]
        return nothing
    end
    function build(s::Sym, x::Vector{Float64})
        f = Fac(s, false, Stats(0), zeros(Float64, 2))
        fill!(f, x)
        return f
    end

    # Reaches the PLAN's own array, through the fresh factor.
    @noinline poke!(f::Fac) = (f.sym.colptr[1] = 9; nothing)
    reach_plan(s::Sym) = (poke!(Fac(s, false, Stats(0), zeros(2))); nothing)

    # A `@noinline` wrapper around a value read OUT of the plan: that is the plan's memory.
    @noinline wstore!(w::Wrap) = (w.buf[1] = 9; nothing)
    via_wrapper(s::Sym) = (wstore!(Wrap(s.colptr)); nothing)

    # A task closure is a container of its captures, so it must be followed at that level.
    function spawn_projection(s::Sym)
        buf = s.colptr
        wait(Threads.@spawn (buf[1] = 7; nothing))
        return nothing
    end
    function spawn_plan(s::Sym)
        wait(Threads.@spawn (s.colptr[1] = 7; nothing))
        return nothing
    end
    end

    s = Factor.Sym(2, [1, 2])
    Factor.build(s, [1.0, 2.0])
    Factor.reach_plan(Factor.Sym(2, [1, 2]))
    Factor.via_wrapper(Factor.Sym(2, [1, 2]))
    Factor.spawn_projection(Factor.Sym(2, [1, 2]))
    Factor.spawn_plan(Factor.Sym(2, [1, 2]))

    scan(f, tt) = StrictMode.concurrency_findings(f, tt)

    # Initializing one's own fresh state is not writing the plan, even several frames down.
    @test isempty(scan(Factor.build, (Factor.Sym, Vector{Float64})))

    # Everything that really does reach the plan still reports. Each of these was lost by the first
    # rule I tried, which simply stopped tainting through `:new`.
    @test !isempty(scan(Factor.reach_plan, (Factor.Sym,)))
    @test !isempty(scan(Factor.via_wrapper, (Factor.Sym,)))
    @test !isempty(scan(Factor.spawn_projection, (Factor.Sym,)))
    @test !isempty(scan(Factor.spawn_plan, (Factor.Sym,)))

    # The field map is what separates them: position 1 holds the plan, 3 and 4 hold fresh objects.
    @test StrictMode._proj_field_index([nothing, QuoteNode(:sym)], 1, Factor.Fac) == 1
    @test StrictMode._proj_field_index([nothing, QuoteNode(:stats)], 1, Factor.Fac) == 3
    @test isnothing(StrictMode._proj_field_index([nothing], 1, Factor.Fac))

    # And the whole assertion a consumer runs: a factorization over an immutable plan passes.
    @test (@assert_concurrency_safe Factor.build(s, [1.0, 2.0]); true)
    @test_throws StrictMode.StrictViolation (
        @assert_concurrency_safe Factor.reach_plan(Factor.Sym(2, [1, 2]))
    )
end
