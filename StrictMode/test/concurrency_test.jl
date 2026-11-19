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
        i = threadid()
        yield()                          # the task may now run on another thread
        @inbounds buf[i] += 1           # task-migration hazard: `i` names a thread it may have left
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
    dirty() = (i = Threads.threadid(); yield(); tls[i] += 1.0)
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
    @test !isempty(StrictMode._threadid_writes(TidAtomics.rmw, ()))

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
    @test occursin("writes state that concurrent tasks share", sprint(showerror, err))

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
    scan(f) = StrictMode._threadid_writes(f, ())

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

    # A write inside an out-of-line callee is reported at the caller, which is the only place it can
    # be: the threadid taint is in the caller and the store is in the callee, and the callee alone has
    # no `threadid()` in it to taint anything.
    @test !isempty(scan(Slots.through_callee))
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

@testitem "a keyword body's leading arguments belong to the lowering, not to the author" begin
    using StrictMode

    module KwSweep
    struct Plan
        buf::Vector{Float64}
    end
    # `out` is the author's first argument. The lowered body receives `scale` and the function
    # object ahead of it, so position 1 there is a keyword value.
    function fill_out!(out::Vector{Float64}, src::Vector{Float64}; scale::Float64 = 1.0)
        for i in eachindex(out, src)
            out[i] = src[i] * scale
        end
        return out
    end
    # No `!`, and it writes a buffer the caller's plan can observe.
    function apply(p::Plan, x::Vector{Float64}; gain::Float64 = 1.0)
        for i in eachindex(x)
            p.buf[i] = x[i] * gain
        end
        return sum(p.buf)
    end
    end
    KwSweep.fill_out!(zeros(3), ones(3))
    KwSweep.apply(KwSweep.Plan(zeros(3)), ones(3))

    ms, _ = StrictMode.module_methods(KwSweep)
    lowered(nm) = only(
        m for m in ms
            if startswith(String(m.name), "#") && StrictMode._demangle(m.name) === nm
    )
    parts(m) = (m.sig.parameters[1].instance, Tuple(m.sig.parameters[2:end]))
    sweep(f, tt) = only(StrictMode.findings(f, tt; guarantees = (:concurrency_safe,)))

    f, tt = parts(lowered(:fill_out!))
    @test StrictMode._self_arg_position(f, tt) == 3
    @test tt[3] === Vector{Float64}
    # An ordinary method and a closure carry their own first argument at position 1: a closure's
    # captures live in the function object rather than in an argument.
    @test StrictMode._self_arg_position(KwSweep.fill_out!, (Vector{Float64}, Vector{Float64})) == 1
    @test StrictMode._self_arg_position(x -> x, (Int,)) == 1

    # Position 1 of the lowered body is `scale`, which is isbits and so reports nothing. Reading it
    # renders as `:pass` for a method whose output buffer was never examined, and the author's `!`
    # is unreadable through the mangling.
    bang = sweep(f, tt)
    @test bang.status === :info
    @test occursin("argument 3", bang.reason)

    # A write the caller's plan can observe is found in the lowered body as well as the wrapper.
    fa, ta = parts(lowered(:apply))
    @test StrictMode._self_arg_position(fa, ta) == 3
    @test StrictMode._failed(sweep(fa, ta))
end

@testitem "an undefined phi slot is skipped, not read" begin
    using StrictMode, LinearAlgebra

    # A `PhiNode` merging a variable that is not defined along every incoming edge leaves those
    # slots undefined. Reading one raises `UndefRefError`, which the scan reports as a signature it
    # could not read — and the raw `any` below is the shape that does it.
    p = Core.PhiNode(Int32[1, 2], Vector{Any}(undef, 2))
    @test !isassigned(p.values, 1)
    @test_throws UndefRefError any(_ -> false, p.values)
    @test StrictMode._any_phi_tainted(p, BitSet([1]), (1,)) === false

    # A defined slot among undefined ones is still seen, so the guard costs no recall.
    q = Core.PhiNode(Int32[1, 2], Vector{Any}(undef, 2))
    q.values[2] = Core.SSAValue(7)
    @test StrictMode._any_phi_tainted(q, BitSet([7]), ()) === true

    module PhiShape
    using LinearAlgebra
    struct Buffers{T}
        Z::Array{T, 3}
        Y::Array{T, 3}
    end
    # Two array fields of argument 1 handed to `mul!` inside a loop: the phi this builds has an
    # undefined slot.
    function channel_products!(buf::Buffers, M::AbstractArray, nf, nc, n)
        for c in axes(M, 3)
            mul!(view(buf.Y, 1:nc, c, 1:n), transpose(view(M, :, :, c)), view(buf.Z, 1:nf, c, 1:n))
        end
        return buf
    end
    end

    buf = PhiShape.Buffers(zeros(4, 2, 3), zeros(4, 2, 3))
    M = zeros(4, 4, 2)
    PhiShape.channel_products!(buf, M, 4, 4, 3)
    tt = (typeof(buf), typeof(M), Int, Int, Int)

    # The write through the struct's own field is found, rather than the signature being unreadable.
    vs = StrictMode.concurrency_findings(PhiShape.channel_products!, tt)
    @test !isempty(vs)
    @test any(v -> occursin("reachable from the plan", v.message), vs)
    f = only(StrictMode.findings(PhiShape.channel_products!, tt; guarantees = (:concurrency_safe,)))
    @test f.code !== :SM0203          # not "could not read this signature"
    @test f.status === :info           # a `!` name declares the write of argument 1
end

@testitem "a store through a raw pointer into the shared argument is a write to it" begin
    using StrictMode
    flagged(f) = try
        f()
        false
    catch e
        e isa StrictViolation
    end
    via_ptr!(out, plan) = (GC.@preserve plan unsafe_store!(pointer(plan), 0.0); out[1] = 1.0; nothing)
    via_offset!(out, plan) = (GC.@preserve plan unsafe_store!(pointer(plan) + 16, 0.0); out[1] = 1.0; nothing)
    # Writes `out`; the offset is read from the plan, which must not make `out` look like the plan.
    own_ptr!(out, plan) = (GC.@preserve out unsafe_store!(pointer(out) + 8 * length(plan), 0.0); nothing)
    out = zeros(32)
    plan = randn(4, 4)
    @test flagged(() -> @assert_concurrency_safe self = 2 via_ptr!(out, plan))
    @test flagged(() -> @assert_concurrency_safe self = 2 via_offset!(out, plan))
    @test !flagged(() -> @assert_concurrency_safe self = 2 own_ptr!(out, plan))
end

@testitem "a threadid-indexed buffer written through an out-of-line helper is reported" begin
    using StrictMode
    const OTX = Base.OncePerThread{Vector{Float64}}(() -> Float64[])
    @noinline grow_x!(v, n) = (length(v) < n && resize!(v, n); v)
    @noinline read_x(v) = isempty(v) ? 0.0 : v[1]
    @noinline copy_x(v) = (c = copy(v); isempty(c) ? push!(c, 0.0) : c)
    through_helper(n) = (grow_x!(OTX(), n)[1] = 1.0; nothing)
    reads_only(n) = read_x(OTX()) + n
    writes_a_copy(n) = (copy_x(OTX())[1] = 1.0; nothing)
    through_helper(4); reads_only(1); writes_a_copy(1)
    nf(f) = length(StrictMode._threadid_writes(f, (Int,)))
    # The threadid is in the caller and the write in the callee: neither alone shows it.
    @test nf(through_helper) >= 1
    @test nf(reads_only) == 0
    @test nf(writes_a_copy) == 0
end

@testitem "pool_balance_report does not count an event wait as an acquire" begin
    using StrictMode
    # A worker waits on an `Event` and a driver notifies it: a signal, not a resource held.
    ev_wait(e) = wait(e)
    ev_notify(e) = notify(e)
    @test pool_balance_report(ev_wait, (Threads.Event,)).balanced
    @test pool_balance_report(ev_notify, (Threads.Event,)).balanced
end

@testitem ":no_threadid_state flags per-thread state held across a suspension point, only" begin
    using StrictMode
    module HeldAcross
    const OPT = Base.OncePerThread{Vector{Float64}}(() -> zeros(8))
    held_yield(n::Int) = (v = OPT(); v[1] = Float64(n); yield(); v[2] = v[1]; nothing)
    no_suspend(n::Int) = (v = OPT(); v[1] = Float64(n); v[2] = v[1]; nothing)
    @noinline pause() = (yield(); nothing)
    held_callee(n::Int) = (v = OPT(); v[1] = Float64(n); pause(); v[2] = v[1]; nothing)
    refetched(n::Int) = (v = OPT(); v[1] = Float64(n); yield(); w = OPT(); w[2] = 1.0; nothing)
    @noinline grow!(v, n) = (length(v) < n && resize!(v, n); v)
    grow_use(n::Int) = (v = grow!(OPT(), n); v[1] = 1.0; nothing)
    grow_yield_use(n::Int) = (v = grow!(OPT(), n); pause(); v[1] = 1.0; nothing)
    const OPK = Base.OncePerTask{Vector{Float64}}(() -> zeros(8))
    # A per-thread or per-task buffer by a run-time choice: the per-thread one can reach the yield.
    merged(c::Bool) = (v = c ? OPT() : OPK(); v[1] = 1.0; pause(); v[2] = v[1]; nothing)
    end
    fs = (HeldAcross.held_yield, HeldAcross.no_suspend, HeldAcross.held_callee,
          HeldAcross.refetched, HeldAcross.grow_use, HeldAcross.grow_yield_use)
    foreach(f -> f(8), fs)
    flagged(f) = any(v -> v.certain, StrictMode.threadid_state_findings(f, (Int,)))
    # Tasks are not preempted: per-thread state is shared only if it is still in use after the task
    # could have been suspended.
    @test flagged(HeldAcross.held_yield)
    @test !flagged(HeldAcross.no_suspend)
    @test flagged(HeldAcross.held_callee)
    @test !flagged(HeldAcross.refetched)
    @test !flagged(HeldAcross.grow_use)
    @test flagged(HeldAcross.grow_yield_use)
    HeldAcross.merged(true); HeldAcross.merged(false)
    @test any(v -> v.certain, StrictMode.threadid_state_findings(HeldAcross.merged, (Bool,)))
end

@testitem "tasks spawned in a comprehension and writes to a global are read" begin
    using StrictMode
    module Spawned
    struct Pool; slots::Vector{Vector{Float64}}; end
    @noinline job!(plan::Vector{Float64}, buf::Vector{Float64}) = (buf[1] = plan[1]; nothing)
    # Every task writes slot 1 of the shared pool: a race, spawned inside a comprehension.
    racy(p::Pool, plan::Vector{Float64}) =
        (foreach(wait, [Threads.@spawn job!(plan, p.slots[1]) for _ in eachindex(p.slots)]); nothing)
    const SLOTS = [zeros(4) for _ in 1:8]
    const TABLE = [1.0, 2.0, 3.0]
    job_global(plan::Vector{Float64}, wi::Int) = (s = SLOTS[wi]; s[1] = plan[1]; nothing)
    reads_global(plan::Vector{Float64}, wi::Int) = plan[1] + TABLE[wi]
    end
    p = Spawned.Pool([zeros(4) for _ in 1:2])
    Spawned.racy(p, [1.0]); Spawned.job_global([1.0], 1); Spawned.reads_global([1.0], 1)
    certain(f, T) = any(v -> v.certain, StrictMode.concurrency_findings(f, T))
    @test certain(Spawned.racy, (Spawned.Pool, Vector{Float64}))
    @test certain(Spawned.job_global, (Vector{Float64}, Int))
    @test isempty(StrictMode.concurrency_findings(Spawned.reads_global, (Vector{Float64}, Int)))
    # A job that receives its own buffer writes nothing shared.
    @test isempty(StrictMode.concurrency_findings(Spawned.job!, (Vector{Float64}, Vector{Float64})))
end

@testitem "a pointer copied out of the plan inside a plain-data struct still writes the plan" begin
    using StrictMode
    module PtrCopy
    struct Job; Cp::Ptr{Float64}; n::Int; end
    mutable struct Pool; job::Job; end
    @noinline store!(j::Job, i) = (unsafe_store!(j.Cp, 1.0, i); nothing)
    direct(p::Pool) = (unsafe_store!(p.job.Cp, 1.0, 1); nothing)
    via_callee(p::Pool) = (j = p.job; store!(j, 1); nothing)
    reads(p::Pool) = unsafe_load(p.job.Cp, 1)
    end
    buf = zeros(4)
    GC.@preserve buf begin
        p = PtrCopy.Pool(PtrCopy.Job(pointer(buf), 4))
        PtrCopy.direct(p); PtrCopy.via_callee(p); PtrCopy.reads(p)
    end
    certain(f) = any(v -> v.certain, StrictMode.concurrency_findings(f, (PtrCopy.Pool,)))
    @test certain(PtrCopy.direct)
    @test certain(PtrCopy.via_callee)
    @test !certain(PtrCopy.reads)
end

@testitem "an atomic write to shared state warns; a plain store fails" begin
    using StrictMode, Test
    module SyncWrites
    mutable struct Sync; @atomic bar::Int; plain::Int; end
    mutable struct Pool; sync::Sync; end
    barrier(p::Pool) = (s = p.sync; @atomic s.bar += 1; nothing)
    plainbump(p::Pool) = (s = p.sync; s.plain += 1; nothing)
    struct Inner; p::Ptr{Float64}; end
    struct Outer; in::Inner; end
    mutable struct Holder; o::Outer; buf::Vector{Float64}; end
    nested(h::Holder) = (unsafe_store!(h.o.in.p, 1.0, 1); nothing)
    viaview(h::Holder) = (v = view(h.buf, 2:3); GC.@preserve v unsafe_store!(pointer(v), 1.0, 1); nothing)
    end
    p = SyncWrites.Pool(SyncWrites.Sync(0, 0)); SyncWrites.barrier(p); SyncWrites.plainbump(p)
    # Atomic writes cannot tear, but two independent calls sharing the object still race on what
    # they mean, and the scan cannot tell those from one cooperating call: reported, not raised.
    @test_logs (:warn,) match_mode = :any StrictMode._assert_concurrency_safe("t", SyncWrites.barrier, (SyncWrites.Pool,))
    @test only(StrictMode.findings(SyncWrites.barrier, (SyncWrites.Pool,); guarantees = (:concurrency_safe,))).status === :info
    @test_throws StrictMode.StrictViolation StrictMode._assert_concurrency_safe("t", SyncWrites.plainbump, (SyncWrites.Pool,))
    buf = zeros(4)
    GC.@preserve buf begin
        h = SyncWrites.Holder(SyncWrites.Outer(SyncWrites.Inner(pointer(buf))), zeros(4))
        SyncWrites.nested(h); SyncWrites.viaview(h)
    end
    certain(f) = any(v -> v.certain, StrictMode.concurrency_findings(f, (SyncWrites.Holder,)))
    @test certain(SyncWrites.nested)        # a pointer two plain-data structs deep
    @test certain(SyncWrites.viaview)       # a pointer taken through a view
end

@testitem "review of 0.5.13: atomics, globals, suspensions and closures read correctly" begin
    using StrictMode, Test
    module Rev
    using Base.Threads: threadid
    mutable struct Plan; w::Vector{Float64}; buf::Vector{Float64}; end
    mutable struct P1; n::Int; end
    bumpn(p::P1) = (for _ in 1:3; modifyfield!(p, :n, +, 1); end; nothing)          # plain: a race
    const LK = ReentrantLock(); const CNT = Threads.Atomic{Int}(0)
    withlock(p::Plan) = (@lock LK p.w[1])                                           # synchronization
    counted(p::Plan) = (Threads.atomic_add!(CNT, 1); p.w[1])                         # synchronization
    fresh_out(p::Plan) = (out = zeros(8); ts = map(i -> Threads.@spawn(out[i] = p.w[i]), 1:8); foreach(wait, ts); sum(out))
    struct Spawner; p::Plan; end
    (s::Spawner)(i) = Threads.@spawn (s.p.buf[1] = i)
    callable(p::Plan) = (ts = map(Spawner(p), 1:2); foreach(wait, ts); nothing)
    const BUF = zeros(Int, 64); const VB = [zeros(8) for _ in 1:64]
    struct CB; f::Function; end
    dyn(cb::CB) = (i = threadid(); cb.f(); BUF[i] += 1; nothing)                     # may suspend
    io_print() = (i = threadid(); println(devnull, "x"); BUF[i] += 1; nothing)       # devnull never blocks
    locked() = (i = threadid(); Base.lock(LK); Base.unlock(LK); BUF[i] += 1; nothing)  # a lock can block
    strbuild(x::Int) = (i = threadid(); s = "v=$x"; BUF[i] += length(s); nothing)    # an IOBuffer only
    latest_yield() = (i = threadid(); Base.invokelatest(yield); BUF[i] += 1; nothing)
    function refetch(n::Int)
        b = VB[threadid()]
        while n > 0
            b[1] += 1; n -= 1
            yield()
            b = VB[threadid()]                  # a fresh value after every yield
        end
    end
    @noinline g5(v) = (yield(); v[1] += 1; nothing)
    handed() = (g5(VB[threadid()]); nothing)                                          # held by the callee
    fresh(n::Int) = (for _ in 1:n; yield(); i = threadid(); BUF[i] += 1; end; nothing)  # new value each time
    const SL = Threads.SpinLock()
    spin() = (i = threadid(); Base.lock(SL); Base.unlock(SL); BUF[i] += 1; nothing)   # never yields
    end
    p = Rev.Plan(ones(8), zeros(2))
    Rev.bumpn(Rev.P1(0)); Rev.withlock(p); Rev.counted(p); Rev.fresh_out(p); Rev.callable(p)
    cb = Rev.CB(() -> nothing)
    Rev.dyn(cb); Rev.io_print(); Rev.handed(); Rev.fresh(2); Rev.spin()
    Rev.locked(); Rev.strbuild(1); Rev.latest_yield(); Rev.refetch(2)
    fails(f, T) = any(v -> v.certain && !v.deliberate, StrictMode.concurrency_findings(f, T))
    @test fails(Rev.bumpn, (Rev.P1,))                                  # a plain modifyfield! is not atomic
    @test isempty(StrictMode.concurrency_findings(Rev.withlock, (Rev.Plan,)))
    @test isempty(StrictMode.concurrency_findings(Rev.counted, (Rev.Plan,)))
    @test !fails(Rev.fresh_out, (Rev.Plan,))                           # writes only its own fresh buffer
    @test fails(Rev.callable, (Rev.Plan,))                             # a callable struct is read too
    tid(f, T) = (vs = StrictMode.threadid_state_findings(f, T); isempty(vs) ? :pass : any(v -> v.certain, vs) ? :fail : :maybe)
    @test tid(Rev.dyn, (Rev.CB,)) === :maybe
    @test tid(Rev.io_print, ()) === :pass
    @test tid(Rev.locked, ()) === :fail
    @test tid(Rev.strbuild, (Int,)) === :pass
    @test tid(Rev.latest_yield, ()) === :fail
    @test tid(Rev.refetch, (Int,)) === :pass
    @test tid(Rev.handed, ()) === :maybe          # whether the callee still holds it is not read
    @test tid(Rev.fresh, (Int,)) === :pass
    @test tid(Rev.spin, ()) === :pass
    # A suspension the scan could not read warns rather than raising.
    @test_logs (:warn,) match_mode = :any StrictMode._assert_no_threadid_state("t", Rev.dyn, (Rev.CB,))
end

@testitem "a plan value stored into a container, or a global's inner data, is followed" begin
    using StrictMode
    module Held
    mutable struct Plan; buf::Vector{Float64}; w::Vector{Float64}; end
    mutable struct Out; ref::Vector{Float64}; ok::Bool; end
    struct Guarded; l::ReentrantLock; v::Vector{Int}; end
    const GD = Guarded(ReentrantLock(), [1, 2, 3])
    function boxed(p::Plan)                       # a reassigned capture lives in a Core.Box
        out = zeros(2); out = p.buf
        t = Threads.@spawn (out[1] = 1.0); wait(t); nothing
    end
    lit(p::Plan) = (bs = [p.buf, zeros(2)]; t = Threads.@spawn (bs[1][1] = 1.0); wait(t); nothing)
    fresh_lit(p::Plan) = (bs = [zeros(2), zeros(2)]; t = Threads.@spawn (bs[1][1] = p.w[1]); wait(t); nothing)
    wrapper_ok(p::Plan) = (o = Out(zeros(1), false); o.ref = p.buf; o.ok = true; o.ok)
    wrapper_through(p::Plan) = (o = Out(zeros(1), false); o.ref = p.buf; o.ref[1] = 2.0; nothing)
    write_gd(p::Plan) = (GD.v[1] = 3; nothing)
    locked_gd(p::Plan) = (lock(GD.l); x = p.w[1]; unlock(GD.l); x)
    end
    p = Held.Plan(zeros(2), ones(2))
    fs = (Held.boxed, Held.lit, Held.fresh_lit, Held.wrapper_ok, Held.wrapper_through, Held.write_gd, Held.locked_gd)
    foreach(f -> f(p), fs)
    fails(f) = any(v -> v.certain && !v.deliberate, StrictMode.concurrency_findings(f, (Held.Plan,)))
    @test fails(Held.boxed)
    @test fails(Held.lit)
    @test !fails(Held.fresh_lit)
    @test !fails(Held.wrapper_ok)              # a field of the fresh struct, not the plan
    @test fails(Held.wrapper_through)
    @test fails(Held.write_gd)                 # a vector inside an immutable const global
    @test !fails(Held.locked_gd)               # its lock is synchronization
end

@testitem "an array holding plan values is not the plan, and its elements are" begin
    using StrictMode
    module Elems
    mutable struct Plan; buf::Vector{Float64}; w::Vector{Float64}; end
    mutable struct Work; slots::Vector{Vector{Float64}}; n::Int; end
    mkwork() = Work(Vector{Vector{Float64}}(undef, 2), 0)
    ro_lit(p::Plan) = (bs = [p.buf, p.w]; s = 0.0; for b in bs; s += sum(b); end; s)
    ro_undef(p::Plan) = (bs = Vector{Vector{Float64}}(undef, 2); bs[1] = p.buf; bs[2] = zeros(2); sum(bs[2]))
    ro_push(p::Plan) = (bs = [p.buf]; push!(bs, zeros(2)); length(bs))
    ro_work(p::Plan) = (w = mkwork(); w.slots[1] = p.buf; w.n = 1; w.n)
    wr_lit(p::Plan) = (bs = [p.buf, p.w]; for b in bs; b[1] = 0.0; end; nothing)
    wr_undef(p::Plan) = (bs = Vector{Vector{Float64}}(undef, 2); bs[1] = p.buf; bs[2] = zeros(2); bs[1][1] = 3.0; nothing)
    end
    p = Elems.Plan(zeros(2), ones(2))
    fs = (Elems.ro_lit, Elems.ro_undef, Elems.ro_push, Elems.ro_work, Elems.wr_lit, Elems.wr_undef)
    foreach(f -> f(p), fs)
    fails(f) = any(v -> v.certain && !v.deliberate, StrictMode.concurrency_findings(f, (Elems.Plan,)))
    @test !fails(Elems.ro_lit)
    @test !fails(Elems.ro_undef)
    @test !fails(Elems.ro_push)
    @test !fails(Elems.ro_work)
    @test fails(Elems.wr_lit)
    @test fails(Elems.wr_undef)
    @test (@assert_concurrency_safe Elems.ro_lit(p)) == Elems.ro_lit(p)
end

@testitem "building a string runs the show of a package type, which may suspend" begin
    using StrictMode
    module Shows
    using Base.Threads
    const BUF = zeros(Int, 64)
    struct Y end
    Base.show(io::IO, ::Y) = (yield(); print(io, "y"))
    struct Z; a::Int; end
    held(::Int) = (i = threadid(); s = string(Y()); BUF[i] += length(s); nothing)
    plain(x::Int) = (i = threadid(); s = string(x, "a", 2.0); BUF[i] += length(s); nothing)
    zplain(z::Z) = (i = threadid(); s = string(z); BUF[i] += length(s); nothing)
    end
    Shows.held(1); Shows.plain(1); Shows.zplain(Shows.Z(1))
    tid(f, t) = only(StrictMode.findings(f, t; guarantees = (:no_threadid_state,))).status
    # A yielding `show` is never cleared. On 1.13 `string` inlines to `print` and the yield is read
    # (:fail); on 1.12 `print_to_string` stays out of line and is not read in full (:info).
    @test tid(Shows.held, (Int,)) === (VERSION >= v"1.13-" ? :fail : :info)
    @test tid(Shows.plain, (Int,)) === :pass
    @test tid(Shows.zplain, (Shows.Z,)) === (VERSION >= v"1.13-" ? :pass : :info)
end

@testitem "per-thread state wrapped in a struct or tuple is still per-thread" begin
    using StrictMode
    module Wrapped
    mutable struct Ar; depth::Int; end
    struct Owner; a::Ar; end
    const A = Base.OncePerThread{Ar}(() -> Ar(0))
    @noinline body(o::Owner) = (o.a.depth += 1; yield(); o.a.depth -= 1; nothing)
    @noinline calm(o::Owner) = (o.a.depth += 1; o.a.depth -= 1; nothing)
    @noinline body2(t) = (t[1].depth += 1; yield(); nothing)
    root() = body(Owner(A()))
    root_calm() = calm(Owner(A()))
    tup() = body2((A(), 1))
    end
    Wrapped.root(); Wrapped.root_calm(); Wrapped.tup()
    tid(f) = only(StrictMode.findings(f, (); guarantees = (:no_threadid_state,))).status
    @test tid(Wrapped.root) === :info         # handed on in a wrapper to a callee that suspends
    @test tid(Wrapped.tup) === :info
    @test tid(Wrapped.root_calm) === :pass    # the callee cannot suspend
end

@testitem "a plan value handed to a callee the scan cannot read is recorded" begin
    using StrictMode

    struct UnreadPlan
        buf::Vector{Float64}
    end
    # A callable struct with a field is not a singleton, and the scan reads a callee through its
    # singleton, so this body is one it does not read.
    struct UnreadWriter
        k::Int
    end
    @noinline (w::UnreadWriter)(p::UnreadPlan) = (p.buf[w.k] = 1.0; nothing)
    through_callable(p::UnreadPlan, w::UnreadWriter) = w(p)
    reads_only(p::UnreadPlan) = p.buf[1]

    vs = StrictMode.concurrency_findings(through_callable, (UnreadPlan, UnreadWriter))
    @test length(vs) == 1
    # Not a write the scan read, so it reports and does not gate.
    @test !only(vs).certain
    @test occursin("could not be read", only(vs).message)
    @test isempty(StrictMode.concurrency_findings(reads_only, (UnreadPlan,)))
end
