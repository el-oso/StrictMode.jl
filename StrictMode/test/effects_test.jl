@testitem "_alloc_signals heuristic matches allocation reality" begin
    using StrictMode
    clean(a, b) = a * b + 1.0
    buf(n) = (
        v = Vector{Float64}(undef, n); @inbounds for i in 1:n
            v[i] = i
        end; sum(v)
    )
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )

    cs = StrictMode._alloc_signals(clean, (Float64, Float64))
    @test !cs.alloc && !cs.boxing                       # clean kernel: no signal

    bs = StrictMode._alloc_signals(buf, (Int,))
    @test bs.alloc && !bs.boxing                        # explicit buffer alloc, no boxing

    xs = StrictMode._alloc_signals(boxy, (Tuple{Int, Float64, Float32},))
    @test xs.boxing                                     # runtime tuple index → boxing
end

@testitem "effects layer wraps Base.infer_effects" begin
    using StrictMode
    pure(x) = x * 2 + 1
    eff = StrictMode.effects(pure, (Int,))
    # The API returns a Bool per effect, and rejects unknown effects. (We don't assert specific
    # effect *values* — those are the compiler's call and vary across platforms.)
    @test StrictMode.effect_holds(eff, :nothrow) isa Bool
    @test StrictMode.effect_holds(eff, :effect_free) isa Bool
    @test_throws ArgumentError StrictMode.effect_holds(eff, :bogus)
    # A function that can `throw` is never `:nothrow` — robust everywhere.
    thrower(x) = x > 0 ? x : error("negative")
    @test StrictMode.effect_holds(StrictMode.effects(thrower, (Int,)), :nothrow) == false
end

@testitem "_findings_fast gives correct verdicts with no backend needed" begin
    using StrictMode
    clean(a, b) = a * b + 1.0
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )

    cf = StrictMode._findings_fast(clean, (Float64, Float64), (:typestable, :noalloc, :noboxing), :M, "clean", "()")
    @test all(f -> f.status === :pass, cf)

    bf = StrictMode._findings_fast(boxy, (Tuple{Int, Float64, Float32},), (:noalloc, :noboxing), :M, "boxy", "()")
    @test all(StrictMode._failed, bf)              # boxes → both noalloc and noboxing fail
end

@testitem "_alloc_signals catches an escaping non-isbits immutable :new (F38)" begin
    using StrictMode
    # `Some{Any}(x)` heap-allocates (it's not isbits) but is neither mutable nor an
    # Array/Memory/Box — the old :new rule (mutable || Array || Memory || Box) missed it
    # entirely. Verified against a real corpus (PureFFT.jl): the old rule false-negatived on
    # `apply_rfft!`/`pfft!`, which both build escaping non-isbits immutables.
    mkany(x::Int) = Some{Any}(x)
    sig = StrictMode._alloc_signals(mkany, (Int,))
    @test sig.alloc
end

@testitem "_alloc_signals doesn't flag union-split :invoke as boxing (F9)" begin
    using StrictMode
    @noinline g(x::Int) = x > 0 ? 1.0 : 1        # resolved call returning a small Union
    f(x::Int) = (y = g(x); y + 1.0)              # type-stable union-split use → no heap box
    f(2)                                          # warm
    sig = StrictMode._alloc_signals(f, (Int,))
    @test !sig.boxing && !sig.alloc              # not a false positive (was flagged before the fix)
    @test @allocated(f(2)) == 0                  # genuinely zero-alloc
end

@testitem "the callee walk stops on a saturated signal set, leaving `barrier` one-sided" begin
    using StrictMode
    # `barrier` is exhaustive only while the walk is still running: the `:invoke` recursion stops
    # once alloc, boxing and dictlookup are all set, so a barrier reachable only below that point
    # is never recorded. Pinned because it is load-bearing for every reader of `barrier` — acting
    # on it grants an allocation exemption (StrictModeTest's `_checked_allocs` skips AllocCheck),
    # and each reader first demands `!alloc && !boxing`, a state this one can never reach. Widening
    # the condition to keep walking for `barrier`'s sake would pay the recursion cost on exactly
    # the signal-saturated functions the stop exists for, and buy no verdict.
    _measure_sat() = length(rand(4))
    const _SAT_ONCE = Base.OncePerProcess{Int}(_measure_sat)
    @noinline _below(x::Int) = x + _SAT_ONCE()

    # Control: with nothing else flagged the walk reaches `_below` and does see the barrier one
    # level down. Without this, the assertion at the end would pass for the wrong reason.
    clean(x::Int) = _below(x)
    cs = StrictMode._alloc_signals(clean, (Int,))
    @test cs.barrier
    @test !cs.alloc && !cs.boxing && !cs.dictlookup

    const _SINK = Ref{Any}(nothing)
    const _WS = Dict{Symbol, Int}(:a => 1)
    function saturated(t::Tuple{Int, Float64, Float32})
        a = rand(4)             # alloc — escaped into a sink so no optimizer elides it
        _SINK[] = a
        s = 0.0
        for i in 1:3            # boxing — runtime index into a heterogeneous tuple
            s += t[i]
        end
        delete!(_WS, :a)        # dictlookup
        return s + _below(length(a))
    end

    ss = StrictMode._alloc_signals(saturated, (Tuple{Int, Float64, Float32},))
    @test ss.alloc && ss.boxing && ss.dictlookup   # the frontier really is saturated ...
    @test !ss.barrier                              # ... so the walk stopped short of the barrier
end

@testitem "issue #17: a non-escaping allocation LLVM elides is not flagged" begin
    using StrictMode
    # The scan reads typed IR, where an allocation LLVM later removes is still present. Escape
    # analysis on the same signature is the discriminator: `has_no_escape` on the frame's `:new`
    # statements separates "elided" from "real". Gating on it can only lose a FALSE positive —
    # every shape below that actually allocates is still flagged, which is what makes this safe for
    # an allocation guarantee.
    SINK = Ref{Any}(nothing)
    mkvec(n::Int) = length(Vector{Float64}(undef, n))                        # the issue's reproducer
    escapes(n::Int) = (v = Vector{Float64}(undef, n); SINK[] = v; length(v))
    big(n::Int) = (v = Vector{Float64}(undef, n); v[1] = 1.0; v[1])
    huge() = (v = Vector{Float64}(undef, 100_000); v[1] = 1.0; v[1])
    dictl(n::Int) = (d = Dict{Int, Int}(); d[n] = n; length(d))
    memonly(n::Int) = (m = Memory{Float64}(undef, n); m[1] = 1.0; m[1])
    grow(n::Int) = (
        v = Int[]; for i in 1:n
            push!(v, i)
        end; SINK[] = v; sum(v)
    )

    # Every case is measured, not assumed: the runtime byte count is the oracle, and a fixture that
    # stopped exhibiting its shape would fail here rather than silently agreeing with the scan.
    for (f, args) in (
            (mkvec, (7,)), (escapes, (7,)), (big, (7,)), (huge, ()),
            (dictl, (7,)), (memonly, (7,)), (grow, (7,)),
        )
        f(args...)                                   # compile before measuring
        allocated = @allocated f(args...)
        flagged = StrictMode._alloc_signals(f, map(typeof, args)).alloc
        # The direction that matters: nothing that really allocates may go unflagged.
        allocated > 0 && @test flagged
    end

    mkvec(7)
    @test iszero(@allocated(mkvec(7)))

    # The escape analysis is a compiler internal and so is the PASS NAME `code_ircode_by_type`
    # must stop at. An unrecognized name is an error rather than a no-op, so a rename does not
    # degrade this analysis, it removes it: every call throws, the conservative `false` comes back,
    # and the only symptom is allocations LLVM elides being reported as real. `_INLINING_PASS`
    # resolves the name from the compiler's own published list.
    #
    # The positive control comes first and is unconditional, because a check that can only ever
    # pass is not evidence that anything ran. `mkvec` measures zero bytes above, so the analysis
    # must clear it; if a future Julia moves this out of reach, that is a red build and a decision
    # to make, not something to absorb silently.
    @test StrictMode._all_news_nonescaping(Tuple{typeof(mkvec), Int})     # the analysis RUNS…
    @test !StrictMode._alloc_signals(mkvec, (Int,)).alloc                 # …and issue #17 stays shut

    # The other direction, which is what makes the gating safe: a value that really escapes is
    # never cleared, and a non-signature is never trusted.
    @test !StrictMode._all_news_nonescaping(Tuple{typeof(escapes), Int})
    @test !StrictMode._all_news_nonescaping(Nothing)
end

@testitem "a ccall's Ref argument is not an allocation; a Ref that outlives the call is" begin
    using StrictMode
    # The shape every BLAS/LAPACK wrapper compiles to: `Ref`s built for the call, one of them read
    # back afterwards the way `info[]` is. Typed IR still holds a `:new` for each; codegen puts them
    # on the stack. Flagging them reported every caller of `BLAS.symv!` or `LAPACK.potrs!` as
    # allocating while it measured 0 bytes.
    const REF_SINK = Ref{Any}(nothing)
    refarg(n::Int) = (
        src = Ref(n); dst = Ref(0);
        ccall(:memmove, Ptr{Cvoid}, (Ref{Int}, Ref{Int}, Csize_t), dst, src, sizeof(Int)); dst[]
    )
    refleak(n::Int) = (
        src = Ref(n); dst = Ref(0); REF_SINK[] = dst;
        ccall(:memmove, Ptr{Cvoid}, (Ref{Int}, Ref{Int}, Csize_t), dst, src, sizeof(Int)); dst[]
    )
    measure(f, n) = (f(n); @allocated f(n))
    refnew(f) = any(first(Base.code_typed(f, (Int,); optimize = true))[1].code) do st
        Meta.isexpr(st, :new) && st.args[1] isa Type && st.args[1] <: Base.RefValue
    end

    # Both fixtures must still exhibit the shape, or the verdicts below say nothing.
    @test refnew(refarg) && refnew(refleak)
    @test refarg(5) == 5

    @test iszero(measure(refarg, 5))
    @test !StrictMode._alloc_signals(refarg, (Int,)).alloc

    @test measure(refleak, 5) > 0
    @test StrictMode._alloc_signals(refleak, (Int,)).alloc
end

@testitem "an immutable wrapper allocates only where it is boxed" begin
    using StrictMode
    # `view`, `Diagonal`, `A'` are immutable structs holding heap references. Passed to a resolved
    # call or returned with a concrete type they stay on the stack; stored in an abstractly typed
    # slot or handed to a dynamic call they are boxed. Every fixture is measured, so one that stops
    # exhibiting its behavior fails here instead of quietly agreeing with the scan.
    const VIEW_SINK = Ref{Any}(nothing)
    const DYNAMIC = Any[sum]
    const View = SubArray{Float64, 1, Vector{Float64}, Tuple{UnitRange{Int}}, true}
    @noinline total(v::View) = sum(v)
    @noinline mkview(v::Vector{Float64}) = view(v, 1:2)
    passed(v::Vector{Float64}) = total(view(v, 1:2))
    returned(v::Vector{Float64}) = sum(mkview(v))
    stored(v::Vector{Float64}) = (VIEW_SINK[] = view(v, 1:2); nothing)
    dynamic(v::Vector{Float64}) = (DYNAMIC[1](view(v, 1:2)); nothing)

    x = [1.0, 2.0, 3.0]
    measure(f) = (f(x); @allocated f(x))
    T = (Vector{Float64},)
    viewnew(f) = any(first(Base.code_typed(f, T; optimize = true))[1].code) do st
        Meta.isexpr(st, :new) && st.args[1] <: SubArray
    end
    @test viewnew(passed) && viewnew(stored) && viewnew(dynamic)

    for f in (passed, returned, mkview)
        @test iszero(measure(f))
        @test !StrictMode._alloc_signals(f, T).alloc
    end
    for f in (stored, dynamic)
        @test measure(f) > 0
        @test StrictMode._alloc_signals(f, T).alloc
    end
end

@testitem "a :new whose type is a GlobalRef is judged by the type it names" begin
    using StrictMode
    # Complex division compiles to `%new(Base.ComplexF64, …)`: the type is a `GlobalRef`, not the
    # `DataType`. ComplexF64 is isbits, so it must not count as an allocation.
    cdiv(a::ComplexF64, b::ComplexF64) = a / b
    globalref_new = any(first(Base.code_typed(/, (ComplexF64, ComplexF64)))[1].code) do st
        Meta.isexpr(st, :new) && st.args[1] isa GlobalRef
    end
    @test globalref_new
    cdiv(1.0im, 2.0 + 0im)
    @test iszero(@allocated cdiv(1.0im, 2.0 + 0im))
    @test !StrictMode._alloc_signals(cdiv, (ComplexF64, ComplexF64)).alloc
end

@testitem "an immutable stored into a slot that holds it inline is not an allocation" begin
    using StrictMode
    # A concrete, `allocatedinline` destination — a concretely typed mutable field, or a
    # concretely typed array element — takes the value's fields by copy. Only a pointer slot (an
    # abstract or union-typed field, a `Vector{Any}` element) needs the value boxed first. Every
    # fixture is measured, so one that stops exhibiting its behavior fails here rather than
    # quietly agreeing with the scan.
    struct Wrap
        v::Vector{Float64}
        n::Int
    end
    mutable struct Tight
        f::Wrap
    end
    mutable struct Loose
        f::Any
    end
    mutable struct Maybe
        f::Union{Nothing, Wrap}
    end
    tight!(t::Tight, v::Vector{Float64}, n::Int) = (t.f = Wrap(v, n); nothing)
    loose!(l::Loose, v::Vector{Float64}, n::Int) = (l.f = Wrap(v, n); nothing)
    maybe!(m::Maybe, v::Vector{Float64}, n::Int) = (m.f = Wrap(v, n); nothing)
    anyelt!(a::Vector{Any}, v::Vector{Float64}, n::Int) = (a[1] = Wrap(v, n); nothing)
    wrapelt!(a::Vector{Wrap}, v::Vector{Float64}, n::Int) = (a[1] = Wrap(v, n); nothing)

    v = [1.0, 2.0, 3.0]
    measure(f, o) = (f(o, v, 2); @allocated f(o, v, 2))
    sig(f, o) = StrictMode._alloc_signals(f, (typeof(o), Vector{Float64}, Int))

    for (f, o) in ((tight!, Tight(Wrap(v, 1))), (wrapelt!, [Wrap(v, 1)]))
        @test iszero(measure(f, o))
        @test !sig(f, o).alloc
    end
    for (f, o) in ((loose!, Loose(Wrap(v, 1))), (maybe!, Maybe(nothing)), (anyelt!, Any[Wrap(v, 1)]))
        @test measure(f, o) > 0
        @test sig(f, o).alloc
    end
end

@testitem "issue #32: a guarded call site does not report StrictMode's own reflection" begin
    using StrictMode
    kernel(a::Vector{Float64}, b::Vector{Float64}) = @inbounds a[1] * b[1] + a[2] * b[2]
    guarded(a::Vector{Float64}, b::Vector{Float64}) = @strict kernel(a, b)
    a = rand(4)
    b = rand(4)
    guarded(a, b)
    tt = (Vector{Float64}, Vector{Float64})
    # The first `@allocated` compiles its own measuring closure, and that lands inside the measured
    # window (~157 kB, identical with and without `--check-bounds=yes`); every later call is 0. So one
    # measurement is discarded before the assertion, and both come before the `code_typed` below —
    # reflection on `guarded` makes the next call to it pay a recompilation cost as well.
    @allocated guarded(a, b)
    @test iszero(@allocated guarded(a, b))

    # With checks enabled the site leaves a live `:invoke` of `_strict_scan` behind its per-site flag.
    # Recursing into it reported the scan's own allocation, boxing, dict lookup and union phi against
    # the ENCLOSING function, which is how `@verify_strict`/`audit` flagged clean kernels.
    @test any(Base.code_typed(guarded, tt)[1][1].code) do st
        Meta.isexpr(st, :invoke) || return false
        mi = st.args[1] isa Core.CodeInstance ? st.args[1].def : st.args[1]
        mi isa Core.MethodInstance && mi.def isa Method && mi.def.name === :_strict_scan
    end
    for s in (StrictMode._alloc_signals(kernel, tt), StrictMode._alloc_signals(guarded, tt))
        @test !s.alloc
        @test !s.boxing
        @test !s.dictlookup
        @test !s.unionphi
        # Not a barrier either: `barrier = true` grants an allocation exemption elsewhere, and
        # StrictMode's presence in a body says nothing about the caller's own allocations.
        @test !s.barrier
    end
end

@testitem "issue #33: an error path is dead even when it is reached by a jump" begin
    using StrictMode
    # The shape the per-block mask missed: the `throw`'s message is built in a block that JUMPS to
    # the block holding the throw, so only the terminator block was marked and `print_to_string`
    # stayed live — the scan then reported allocation for text no successful call builds.
    code = Any[
        Expr(:call, GlobalRef(Base, :<), Core.Argument(2), 1),
        Core.GotoIfNot(Core.SSAValue(1), 6),
        Expr(:call, GlobalRef(Base, :getindex), Core.Argument(3), 1),
        Core.ReturnNode(Core.SSAValue(3)),        # the only normal return
        Core.GotoNode(6),
        Expr(:invoke, nothing, GlobalRef(Base, :print_to_string), Core.Argument(2)),
        Core.GotoNode(8),
        Expr(:call, GlobalRef(Core, :throw), Core.SSAValue(6)),
        Core.ReturnNode(),                        # unreachable
    ]
    dead = StrictMode._deadend_mask(code)
    @test findall(!, dead) == [1, 2, 3, 4]        # only the returning path is live
    @test dead[6]                                 # the message build
    @test dead[8]                                 # the throw itself
    @test !dead[4]

    # A loop is not an error path: every statement can still reach the return.
    loop = Any[
        Expr(:call, GlobalRef(Base, :+), Core.Argument(2), 1),
        Core.GotoIfNot(Core.SSAValue(1), 4),
        Core.GotoNode(1),
        Core.ReturnNode(Core.SSAValue(1)),
    ]
    @test !any(StrictMode._deadend_mask(loop))

    # A body that cannot return at all is entirely an error path.
    always = Any[Expr(:call, GlobalRef(Core, :throw), 1), Core.ReturnNode()]
    @test all(StrictMode._deadend_mask(always))
    @test isempty(StrictMode._deadend_mask(Any[]))
end

@testitem ":noescape reports a scoped handle that leaves the frame" begin
    using StrictMode

    mutable struct Handle            # mutable: really materializes, so there is something to track
        p::Int
    end
    SINK = Ref{Any}(nothing)

    stays(n::Int) = (h = Handle(n); h.p + 1)
    returns(n::Int) = (h = Handle(n); h)
    stores(n::Int) = (h = Handle(n); SINK[] = h; n)
    captures(n::Int) = (h = Handle(n); SINK[] = () -> h.p; n)
    nohandle(n::Int) = n + 1

    verdict(f) = !StrictMode._failed(only(findings(f, (Int,); guarantees = (:noescape,))))

    # Nothing is registered yet, so the guarantee has nothing to report. Asserting this first keeps
    # the later failures attributable to the registration rather than to the shape of the code.
    @test verdict(returns)

    register_scoped!(Handle)

    # The positive controls: a check that only ever reports failures proves nothing about the ones
    # it clears. `stays` keeps the handle, and `nohandle` never makes one.
    @test verdict(stays)
    @test verdict(nohandle)

    # The three ways out of a frame.
    @test !verdict(returns)
    @test !verdict(stores)
    @test !verdict(captures)

    # The type is named, so the finding says which handle it was.
    f = only(findings(returns, (Int,); guarantees = (:noescape,)))
    @test occursin("Handle", f.reason)

    # An isbits, pointer-backed handle is the shape this exists for — a borrow from an arena is a
    # `Ptr` plus dimensions, passed by value — so it gets its own cases rather than resting on the
    # mutable fixture above.
    struct PtrMat
        p::Ptr{Float64}
        m::Int
    end
    register_scoped!(PtrMat)
    @inline mkptr(n::Int) = PtrMat(Ptr{Float64}(0), n)
    retain(x) = (SINK[] = x; nothing)

    @test verdict((n::Int) -> (v = mkptr(n); v.m + 1))          # control: stays inside
    @test !verdict((n::Int) -> (retain(mkptr(n)); nothing))      # handed to a retaining callee
    @test !verdict((n::Int) -> (v = mkptr(n); SINK[] = v; n))
    @test !verdict((n::Int) -> (v = mkptr(n); () -> v))

    # A handle from a producer that did NOT inline arrives as a call result, and the escape state of
    # a call result comes from the conservative cache callback rather than from analysis. That is
    # not an escape and must not be reported as one; it is also not a pass. The frame fails with a
    # reason that says which, so "could not decide" never reads as "is fine".
    @noinline mkptr_ni(n::Int) = PtrMat(Ptr{Float64}(0), n)
    stays_ni = (n::Int) -> (v = mkptr_ni(n); v.m + 1)
    fu = only(findings(stays_ni, (Int,); guarantees = (:noescape,)))
    @test StrictMode._failed(fu)
    @test occursin("cannot decide", fu.reason)
    @test occursin("@inline", fu.suggestion)

    # The macro gates, and clears the case it should.
    @test (@assert_noescape stays(3)) == 4
    @test_throws StrictMode.StrictViolation (@assert_noescape returns(3))
    @test_throws "not provably confined" (@assert_noescape stores(3))

    empty!(StrictMode._SCOPED_TYPES)     # a global registry: leave it as it was found
    StrictMode.clear_cache!()
    @test verdict(returns)
end

@testitem ":noescape proves confinement, and says so where it cannot" begin
    using StrictMode

    struct PtrMat{T}       # the shape an arena borrow takes: isbits, Ptr-backed, passed by value
        p::Ptr{T}
        m::Int
    end
    SINK = Ref{Any}(nothing)
    register_scoped!(PtrMat)

    # A producer with a non-isbits fallback: the branch folds per specialization, so a concrete
    # element type yields either a handle or an ordinary heap array, never a union of the two.
    @inline function borrow(::Type{T}, n::Int) where {T}
        isbitstype(T) || return Matrix{T}(undef, n, n)
        return PtrMat{T}(Ptr{T}(0), n)
    end
    @test only(Base.return_types(borrow, (Type{Float64}, Int))) === PtrMat{Float64}
    @test only(Base.return_types(borrow, (Type{BigFloat}, Int))) === Matrix{BigFloat}

    verdict(f, ts) = only(findings(f, ts; guarantees = (:noescape,)))
    passes(f, ts) = !StrictMode._failed(verdict(f, ts))

    @test passes((n::Int) -> (v = borrow(Float64, n); v.m + 1), (Int,))
    @test !passes((n::Int) -> (v = borrow(Float64, n); SINK[] = v; n), (Int,))

    # The heap fallback is not a scoped type and cannot dangle — it is garbage-collected — so
    # neither using it nor leaking it is this guarantee's business.
    @test passes((n::Int) -> (v = borrow(BigFloat, n); size(v, 1)), (Int,))
    @test passes((n::Int) -> (v = borrow(BigFloat, n); SINK[] = v; n), (Int,))

    # `Union{}` types a statement whose only outcome is a throw. It is a subtype of every type, so
    # a bare subtype test reads it as carrying a handle and reports a frame that has none.
    @test !StrictMode._is_scoped_type(Union{})
    # A union carries a handle if any member does, so one hiding in a branch is not skipped.
    @test StrictMode._is_scoped_type(Union{PtrMat{Float64}, Vector{Float64}})

    # A handle from a producer that did not inline arrives as a call result. That is a structural
    # fact read from the IR, not a verdict from the analysis, so it is reported as its own case.
    @noinline borrow_ni(n::Int) = PtrMat{Float64}(Ptr{Float64}(0), n)
    f = verdict((n::Int) -> (v = borrow_ni(n); v.m + 1), (Int,))
    @test StrictMode._failed(f)
    @test occursin("cannot decide", f.reason)

    # What a failure claims is that confinement could not be PROVED, which is weaker than "it
    # escaped" and has to stay weaker: the escape state of a callee the analysis did not see is
    # assumed, so a handle passed to one is indistinguishable from one that left.
    g = verdict((n::Int) -> (v = borrow(Float64, n); SINK[] = v; n), (Int,))
    @test occursin("not provably confined", g.reason)
    @test !occursin("escapes the frame", g.reason)

    empty!(StrictMode._SCOPED_TYPES)
    StrictMode.clear_cache!()
end
