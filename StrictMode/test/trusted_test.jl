# `:trusted` — the payload of an `Untrusted` value may only be read inside a registered boundary.

@testmodule TrustedFixtures begin
    using StrictMode
    export Header, parse_header, forward, peek_length, raw_peek, core_peek, dot_peek, erased

    struct Header
        n::Int
    end

    function parse_header(u::Untrusted{Vector{UInt8}})
        b = unsafe_trust(u)
        length(b) >= 2 || throw(ArgumentError("short header"))
        return Header(Int(b[1]))
    end
    StrictMode.trust_boundary!(parse_header)

    # Passes the wrapped value along without reading it.
    forward(u::Untrusted{Vector{UInt8}}) = parse_header(u)

    # The three spellings of the escape hatch, none of them registered. `Core.getfield` lowers to a
    # call through an SSA value rather than a resolvable callee, so it only matches because
    # `_unopt_callee` reads the constant-folded SSA type.
    peek_length(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))
    raw_peek(u::Untrusted{Vector{UInt8}}) = length(getfield(u, :x))
    core_peek(u::Untrusted{Vector{UInt8}}) = length(Core.getfield(u, :x))
    dot_peek(u::Untrusted{Vector{UInt8}}) = u.x

    # Payload typed `Any`: dispatch has nothing to refuse, so the scan can only say it cannot rule
    # the read out.
    erased(v::Vector{Any}) = getfield(v[1], :x)

    # The same erased object, reading a field `Untrusted` does not have. This cannot be the payload,
    # which is what keeps the erased rule off every `getfield` on an `Any`.
    reads_other_field(v::Vector{Any}) = getfield(v[1], :n)
end

@testitem "Untrusted is free, and dispatch alone refuses the payload" setup = [TrustedFixtures] begin
    using StrictMode
    b = UInt8[1, 2, 3]
    u = Untrusted(b)

    @test isbitstype(Untrusted{Int})
    @test sizeof(Untrusted{Int}) == sizeof(Int)
    Untrusted(1)                                     # compile before measuring
    @test iszero(@allocated Untrusted(1))
    @test Untrusted(u) === u                         # wrapping twice is a no-op

    # The half that needs no checker at all, and survives into a build with checks off.
    @test_throws MethodError sum(u)
    @test_throws MethodError length(u)
    @test_throws ErrorException u.x
    @test unsafe_trust(u) === b
end

@testitem ":trusted passes a boundary and a forwarder, fails every escape hatch" setup = [TrustedFixtures] begin
    using StrictMode
    tt = (Untrusted{Vector{UInt8}},)
    only1(f) = only(findings(f, tt; guarantees = (:trusted,)))

    @test only1(TrustedFixtures.parse_header).status === :pass     # registered boundary
    @test only1(TrustedFixtures.forward).status === :pass          # passes it along, never reads

    for f in (
            TrustedFixtures.peek_length, TrustedFixtures.raw_peek,
            TrustedFixtures.core_peek, TrustedFixtures.dot_peek,
        )
        fi = only1(f)
        @test StrictMode._failed(fi)
        @test occursin("outside a trust boundary", fi.reason)
        @test !isempty(fi.suggestion)
    end
end

@testitem "@assert_trusted gates on the call, and is silent when clean" setup = [TrustedFixtures] begin
    using StrictMode
    u = Untrusted(UInt8[1, 2, 3])
    @test (@assert_trusted TrustedFixtures.parse_header(u)) == TrustedFixtures.Header(1)
    @test_throws StrictViolation (@assert_trusted TrustedFixtures.peek_length(u))
end

@testitem ":trusted reports what it could not check, and what it cannot see" setup = [TrustedFixtures] begin
    using StrictMode
    # "Could not check" must never render as "fine". A signature with no matching method has no
    # typed IR to read. (A registered boundary answers before the IR is fetched, so it is never
    # unevaluated — hence a non-boundary function here.)
    fi = only(findings(TrustedFixtures.peek_length, (Int,); guarantees = (:trusted,)))
    @test StrictMode._failed(fi)

    # An `Any`-typed payload carries no `Untrusted` for dispatch to refuse, so inference cannot
    # confirm the read — and a type the scan could not narrow is not a type it has cleared. The
    # verdict is therefore "cannot be ruled out", which is a failure and not a pass.
    fe = only(findings(TrustedFixtures.erased, (Vector{Any},); guarantees = (:trusted,)))
    @test StrictMode._failed(fe)
    @test occursin("inference lost the object's type", fe.reason)

    # What keeps that from firing on every `getfield` on an `Any`: the field read must be one
    # `Untrusted` actually has. Measured over StrictMode itself, which holds no `Untrusted` at all —
    # 130 derefs on an erased object, of which 2 touch this field. Without the narrowing the rule is
    # sound and useless: 51 of 340 methods, which buries the real findings.
    @test StrictMode._UNTRUSTED_FIELD === first(fieldnames(StrictMode.Untrusted))
    fo = only(findings(TrustedFixtures.reads_other_field, (Vector{Any},); guarantees = (:trusted,)))
    @test !StrictMode._failed(fo)
end

@testitem "registering a trust boundary drops the verdicts cached before it" begin
    using StrictMode

    late_boundary(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u))
    sig = (Untrusted{Vector{UInt8}},)
    late_boundary(Untrusted(UInt8[1]))

    before = only(findings(late_boundary, sig; guarantees = (:trusted,)))
    @test StrictMode._failed(before)
    StrictMode.trust_boundary!(late_boundary)
    after = only(findings(late_boundary, sig; guarantees = (:trusted,)))
    @test after.status === :pass
    delete!(StrictMode._TRUST_BOUNDARIES, late_boundary)
    StrictMode.clear_cache!()
end

@testitem "a callable trust boundary is registered by value, a callable barrier by type" begin
    using StrictMode

    struct MinLength
        min::Int
    end
    (v::MinLength)(u::Untrusted{Vector{UInt8}}) = length(unsafe_trust(u)) >= v.min
    sig = (Untrusted{Vector{UInt8}},)
    MinLength(3)(Untrusted(UInt8[1, 2, 3]))

    @test StrictMode._failed(only(findings(MinLength(3), sig; guarantees = (:trusted,))))
    # The object has no module of its own to ask for; it belongs to the module of its type.
    @test StrictMode._owner_module(MinLength(3)) === parentmodule(MinLength)
    @test StrictMode.trust_boundary!(MinLength(3)) === MinLength(3)
    @test only(findings(MinLength(3), sig; guarantees = (:trusted,))).status === :pass
    delete!(StrictMode._TRUST_BOUNDARIES, MinLength(3))
    StrictMode.clear_cache!()

    struct Tabulate
        n::Int
    end
    (t::Tabulate)() = zeros(t.n)
    @test isnothing(StrictMode.register_alloc_barrier!(Tabulate))
    @test any(g -> g === Tabulate, StrictMode._barrier_functions())
    # A scan that meets a keyword body compares it with every registered barrier by name, and
    # an object has none of its own.
    kwuser(x; scale = 2.0) = scale * x
    kwcaller(x) = kwuser(x; scale = 3.0)
    @test only(findings(kwcaller, (Float64,); guarantees = (:noalloc,))).status === :pass
    @test StrictMode._callable_name(Tabulate) === :Tabulate
    # The registration is taken back from the session and from the store a session write makes.
    delete!(StrictMode._ALLOC_BARRIERS, Tabulate)
    store = StrictMode._store_for(Base.moduleroot(parentmodule(Tabulate)), StrictMode._LOCAL_BARRIERS)
    isnothing(store) || filter!(g -> g !== Tabulate, store)
    StrictMode._BARRIER_GEN[] += 1
    StrictMode.clear_cache!()
    @test !any(g -> g === Tabulate, StrictMode._barrier_functions())
end

@testitem "a payload read into a local is a read" begin
    using StrictMode

    sig = (Untrusted{Vector{UInt8}},)
    status(f, s = sig) = only(findings(f, s; guarantees = (:trusted,)))

    # The read stored in a local, which is how most code is written.
    stored(u::Untrusted{Vector{UInt8}}) = (b = unsafe_trust(u); length(b))
    stored_field(u::Untrusted{Vector{UInt8}}) = (b = getfield(u, :x); length(b))
    function stored_block(u::Untrusted{Vector{UInt8}})
        b = unsafe_trust(u)
        n = 0
        for x in b
            n += x
        end
        return n
    end
    # The wrapped value itself passed through a local, then read.
    renamed(u::Untrusted{Vector{UInt8}}) = (v = u; length(unsafe_trust(v)))
    renamed_stored(u::Untrusted{Vector{UInt8}}) = (v = u; b = unsafe_trust(v); length(b))
    reassigned(u::Untrusted{Vector{UInt8}}, w::Untrusted{Vector{UInt8}}) = (v = u; v = w; b = unsafe_trust(v); length(b))
    for f in (stored, stored_field, stored_block, renamed, renamed_stored)
        x = status(f)
        @test StrictMode._failed(x)
        @test occursin("reads an `Untrusted` payload outside a trust boundary", x.reason)
    end
    @test StrictMode._failed(status(reassigned, (Untrusted{Vector{UInt8}}, Untrusted{Vector{UInt8}})))
    u = Untrusted(UInt8[1, 2])
    @test_throws "reads an `Untrusted` payload outside a trust boundary" @assert_trusted stored(u)

    # A boundary that stores the payload in a local is still the boundary, and a function that
    # stores the WRAPPED value in a local reads nothing.
    boundary(u::Untrusted{Vector{UInt8}}) = (b = unsafe_trust(u); length(b) >= 2 ? Int(b[1]) : 0)
    StrictMode.trust_boundary!(boundary)
    @test status(boundary).status === :pass
    @test (@assert_trusted boundary(u)) == 1
    carries(u::Untrusted{Vector{UInt8}}) = (v = u; boundary(v))
    keeps(u::Untrusted{Vector{UInt8}}) = (v = u; w = v; w)
    @test status(carries).status === :pass
    @test status(keeps).status === :pass
    # A loop over a loosely typed collection reads fields 1 and 2 of what `iterate` returned,
    # which an `Untrusted`, with its one field, cannot be.
    struct LooseBag
        v::AbstractVector
    end
    loose_sum(l::LooseBag) = (
        s = 0.0; for a in l.v
            s += a
        end; s
    )
    @test status(loose_sum, (LooseBag,)).status === :pass
    # A lone read of the first field of an untyped value is still one that cannot be ruled out.
    first_field(v::Vector{Any}) = (x = getfield(v[1], 1); x)
    @test StrictMode._failed(status(first_field, (Vector{Any},)))
    delete!(StrictMode._TRUST_BOUNDARIES, boundary)
    StrictMode.clear_cache!()
end

@testitem "a payload read on one path is not cleared by another field read on another" begin
    using StrictMode

    struct OtherPath
        b::Int
    end
    const U8 = Untrusted{Vector{UInt8}}
    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))

    # The two reads are of the same variable on different paths: where the payload is read, the
    # value is the `Untrusted`.
    e7(x::Union{U8, OtherPath}) = x isa OtherPath ? getfield(x, :b) : length(getfield(x, :x))
    function e8(x::Union{U8, OtherPath})
        x isa OtherPath && return getfield(x, :b)
        b = getfield(x, :x)
        return length(b)
    end
    e1(x) = x isa OtherPath ? getfield(x, :b) : length(getfield(x, :x))
    for (f, T) in ((e7, (Union{U8, OtherPath},)), (e8, (Union{U8, OtherPath},)), (e1, (Any,)))
        r = status(f, T)
        @test StrictMode._failed(r)
        @test occursin("may read an `Untrusted` payload", r.reason)
    end
    # A variable assigned again between the two reads holds another value at the second.
    function reassigned(x, y)
        n = getfield(x, 2)
        x = y
        return n + length(getfield(x, 1))
    end
    @test StrictMode._failed(status(reassigned, (Any, Any)))
    # A read inside a branch that falls through: the path that skips the branch reads the payload
    # of a value nothing was learned about.
    struct NoSuchField end
    function falls_through(x)
        n = 0
        x isa OtherPath && (n = getfield(x, :b))
        return n + length(getfield(x, :x))
    end
    @test StrictMode._failed(status(falls_through, (Any,)))
    throws_first(x) = x isa NoSuchField ? getfield(x, :b) : length(getfield(x, :x))
    @test StrictMode._failed(status(throws_first, (Any,)))

    # Two fields of one value read on one path: that value has two fields, and `Untrusted` has one.
    both(t) = getfield(t, 1) + getfield(t, 2)
    @test status(both, (Any,)).status === :pass
    destructure(t) = ((a, b) = t; a)
    @test status(destructure, (Any,)).status === :pass
    # Enough methods of `indexed_iterate` that inference types its result `Any`, as it does in a
    # session with many packages loaded.
    struct It1 end
    struct It2 end
    struct It3 end
    struct It4 end
    for T in (It1, It2, It3, It4)
        @eval Base.indexed_iterate(x::$T, i::Int, state = 1) = (i, i + 1)
    end
    destructure_any(t) = ((a, b) = t; a + b)
    @test status(destructure_any, (Any,)).status === :pass
end

@testitem "a field read by name on an untyped value is not a payload read" begin
    using StrictMode

    module UntypedProperty
    using StrictMode
    struct Pt
        x::Float64
        y::Float64
    end
    const D = Dict{Symbol, Any}(:a => Pt(1.0, 2.0))
    # `p.x` is `getproperty`, which raises on an `Untrusted` whatever the name. It cannot read a
    # payload, so on a value of unknown type it is an ordinary field read, stored or not.
    stored(k::Symbol) = (p = D[k]; abs(p.x))
    direct(k::Symbol) = abs(D[k].x)
    both(k::Symbol) = (p = D[k]; a = p.x; b = p.y; abs(a) + abs(b))
    # `getfield` and `unsafe_trust` do read one, so on an untyped value they cannot be ruled out.
    by_getfield(k::Symbol) = (p = D[k]; getfield(p, :x))
    by_unsafe_trust(k::Symbol) = (p = D[k]; unsafe_trust(p))
    # On a value typed as `Untrusted` the read is refused at check time, where it would raise.
    typed(u::Untrusted{Vector{UInt8}}) = length(u.x)
    end
    U = UntypedProperty
    status(f, T = (Symbol,)) = only(findings(f, T; guarantees = (:trusted,)))
    for f in (U.stored, U.direct, U.both)
        @test status(f).status === :pass
    end
    for f in (U.by_getfield, U.by_unsafe_trust)
        r = status(f)
        @test StrictMode._failed(r)
        @test occursin("may read an `Untrusted` payload", r.reason)
    end
    r = status(U.typed, (Untrusted{Vector{UInt8}},))
    @test StrictMode._failed(r) && occursin("getproperty", r.reason)

    # A module of such methods loads under a policy.
    @test Core.eval(@__MODULE__, Meta.parse("module UntypedPolicy; using StrictMode; struct Pt; x::Float64; end; const D = Dict{Symbol, Any}(:a => Pt(1.0)); norm1(k::Symbol) = (p = D[k]; abs(p.x)); @strict_policy :trusted; end")) isa Module
end

@testitem "an untyped field read is reported once a package reads the payload through getproperty" begin
    using StrictMode

    module OverrideCallers
    using StrictMode
    struct Pt
        x::Float64
    end
    struct MyT
        v::Int
    end
    const D = Dict{Symbol, Any}(:a => Pt(1.0), :u => Untrusted(MyT(7)))
    norm1(k::Symbol) = (p = D[k]; abs(p.x))
    erased_caller(k::Symbol) = (p = D[k]; p.x)
    other_name(k::Symbol) = (p = D[k]; p.v)
    any_name(k::Symbol, n::Symbol) = getproperty(D[k], n)
    ordered_name(k::Symbol) = getproperty(D[k], :v, :not_atomic)
    end
    O = OverrideCallers
    status(f, T = (Symbol,)) = only(findings(f, T; guarantees = (:trusted,)))

    # StrictMode's own method is the only one for an `Untrusted`, and it raises: `p.x` on an
    # untyped value reads no payload. Both callers are compiled first, so each verdict cached below
    # holds a compiled instance to watch, and the method defined later caps neither instance.
    @test O.norm1(:a) == 1.0
    @test_throws "payload" O.erased_caller(:u)
    @test !isempty(StrictMode._watch_instances(O.norm1, (Symbol,)))
    @test !StrictMode._untrusted_getproperty_overridden()
    @test status(O.norm1).status === :pass
    @test status(O.erased_caller).status === :pass
    @test status(O.other_name).status === :pass
    @test status(O.any_name, (Symbol, Symbol)).status === :pass
    @test status(O.ordered_name).status === :pass

    # A package gives its own wrapped type a `getproperty` that returns the payload. From then on
    # `p.x` on an untyped value can read one, and the verdicts above, which were cached, no longer hold.
    Core.eval(O, :(Base.getproperty(u::Untrusted{MyT}, s::Symbol) = getfield(u, :x)))
    @test StrictMode._untrusted_getproperty_overridden()
    @test Base.invokelatest(O.erased_caller, :u) === O.MyT(7)
    for f in (O.norm1, O.erased_caller)
        r = Base.invokelatest(status, f)
        @test StrictMode._failed(r)
        @test occursin("may read an `Untrusted` payload", r.reason)
    end
    # The method chooses its result whatever the name, so a read of any other name, or of a name
    # known only at run time, can return the payload too.
    @test Base.invokelatest(O.other_name, :u) === O.MyT(7)
    @test StrictMode._failed(Base.invokelatest(status, O.other_name))
    @test StrictMode._failed(Base.invokelatest(status, O.any_name, (Symbol, Symbol)))
    # At a call site it warns and does not raise: the scan did not see a read on a value typed
    # `Untrusted`, only one it cannot rule out.
    @test_logs (:warn, r"may read an `Untrusted` payload"s) match_mode = :any Base.invokelatest(() -> @assert_trusted O.erased_caller(:u))
    # The method that does the reading is a read on a typed value, and raises.
    u = Untrusted(O.MyT(7))
    @test_throws StrictViolation Base.invokelatest(() -> @assert_trusted getproperty(u, :x))

    # Taken back, the first answer returns.
    Base.delete_method(which(getproperty, (Untrusted{O.MyT}, Symbol)))
    @test !StrictMode._untrusted_getproperty_overridden()
    @test Base.invokelatest(status, O.norm1).status === :pass

    # The same holds for the form with a memory order, which a package overrides separately.
    Core.eval(O, :(Base.getproperty(u::Untrusted{MyT}, s::Symbol, o::Symbol) = getfield(u, :x)))
    @test Base.invokelatest(O.ordered_name, :u) === O.MyT(7)
    @test StrictMode._failed(Base.invokelatest(status, O.ordered_name))
    Base.delete_method(which(getproperty, (Untrusted{O.MyT}, Symbol, Symbol)))
    @test Base.invokelatest(status, O.ordered_name).status === :pass
end

@testitem "getproperty with a memory order on an untyped value may read the payload" begin
    using StrictMode

    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))
    @test getproperty(Untrusted(UInt8[1, 2]), :x, :not_atomic) == UInt8[1, 2]
    ordered(v::Vector{Any}) = getproperty(v[1], :x, :not_atomic)
    r = status(ordered, (Vector{Any},))
    @test StrictMode._failed(r)
    @test occursin("may read an `Untrusted` payload", r.reason)
    plain(v::Vector{Any}) = getproperty(v[1], :x)
    @test status(plain, (Vector{Any},)).status === :pass
end

@testitem "a field read after the payload escaped does not clear the payload read" begin
    using StrictMode

    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))
    const SINK = Any[]
    leak(t) = (v = getfield(t, 1); push!(SINK, v); getfield(t, 2))
    r = status(leak, (Any,))
    @test StrictMode._failed(r)
    @test occursin("may read an `Untrusted` payload", r.reason)
    # Read in the other order, the other field raises on an `Untrusted` before the first is read.
    other_first(t) = (n = getfield(t, 2); v = getfield(t, 1); push!(SINK, v); n)
    @test status(other_first, (Any,)).status === :pass
end

@testitem "the escape hatch is a read when it is passed as a value or invoked" begin
    using StrictMode

    const U8 = Untrusted{Vector{UInt8}}
    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))
    piped(u::U8) = length(u |> unsafe_trust)
    mapped(us::Vector{U8}) = map(unsafe_trust, us)
    dotted(us::Vector{U8}) = unsafe_trust.(us)
    invoked(u::U8) = invoke(getproperty, Tuple{Any, Symbol}, u, :x)
    for (f, T) in ((piped, (U8,)), (mapped, (Vector{U8},)), (dotted, (Vector{U8},)), (invoked, (U8,)))
        r = status(f, T)
        @test StrictMode._failed(r)
        @test occursin("reads an `Untrusted` payload outside a trust boundary", r.reason)
    end
    u = Untrusted(UInt8[1, 2])
    @test_throws StrictViolation @assert_trusted piped(u)

    # Comparing with the escape hatch reads nothing, and `invoke` of another function is that call.
    is_hatch(f) = f === unsafe_trust
    @test status(is_hatch, (Any,)).status === :pass
    # A tuple of the escape hatch used only in a membership test or a comparison applies nothing.
    is_reader(f) = f in (unsafe_trust, getfield)
    not_reader(f) = f ∉ (unsafe_trust, getfield)
    named_reader(f) = (t = (unsafe_trust, getfield); f in t)
    same_readers(fs) = fs == (unsafe_trust, getfield)
    @test is_reader(unsafe_trust) && !is_reader(length)
    for f in (is_reader, not_reader, named_reader, same_readers)
        @test status(f, (Any,)).status === :pass
    end
    # A tuple of it that is returned, indexed and called, or passed to any other call still hands it on.
    readers() = (unsafe_trust, getfield)
    called(u::U8) = length((unsafe_trust, identity)[1](u))
    named_called(u::U8) = (t = (unsafe_trust, identity); f = t[1]; length(f(u)))
    passed(f) = f in collect((unsafe_trust, getfield))
    @test called(u) == 2
    for (f, T) in ((readers, ()), (called, (U8,)), (named_called, (U8,)), (passed, (Any,)))
        r = status(f, T)
        @test StrictMode._failed(r)
        @test occursin("reads an `Untrusted` payload outside a trust boundary", r.reason)
    end
    invoked_clean(x::Vector{UInt8}) = invoke(length, Tuple{AbstractVector}, x)
    @test status(invoked_clean, (Vector{UInt8},)).status === :pass
end

@testitem "a keyword function is judged by its body, and a boundary's body is the boundary" begin
    using StrictMode

    const U8 = Untrusted{Vector{UInt8}}
    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))
    peek(u::U8; n::Int = 1) = unsafe_trust(u)[n]
    for (f, T) in ((peek, (U8,)), (Core.kwcall, (NamedTuple{(:n,), Tuple{Int}}, typeof(peek), U8)))
        r = status(f, T)
        @test StrictMode._failed(r)
        @test occursin("reads an `Untrusted` payload outside a trust boundary", r.reason)
    end
    u = Untrusted(UInt8[7])
    @test_throws StrictViolation @assert_trusted peek(u)
    @test_throws StrictViolation @assert_trusted peek(u; n = 1)

    parsekw(u::U8; strict::Bool = true) = length(unsafe_trust(u))
    StrictMode.trust_boundary!(parsekw)
    body = Base.bodyfunction(only(methods(parsekw)))
    @test status(body, (Bool, typeof(parsekw), U8)).status === :pass
    @test status(parsekw, (U8,)).status === :pass
    @test (@assert_trusted parsekw(u; strict = false)) == 1
    delete!(StrictMode._TRUST_BOUNDARIES, parsekw)
    StrictMode.clear_cache!()

    # A module whose boundary takes keywords loads under a policy.
    @test Core.eval(@__MODULE__, Meta.parse("module KwBoundaryPolicy; using StrictMode; const U8 = Untrusted{Vector{UInt8}}; parsekw(u::U8; strict::Bool = true) = length(unsafe_trust(u)); trust_boundary!(parsekw); @strict_policy :trusted; end")) isa Module
end

@testitem "reinterpret and printing do not reach the payload" begin
    using StrictMode
    u = Untrusted(UInt32(0xdeadbeef))
    v = Untrusted(UInt8[0x42, 0x43])

    # `reinterpret` raises as a field read does, naming the call that was tried.
    @test_throws "`Untrusted` data has no readable fields (tried `reinterpret`)" reinterpret(UInt32, u)
    @test_throws "trust_boundary!" reinterpret(Float32, u)
    @test_throws "`Untrusted` data has no readable fields (tried `.x`)" u.x
    @test reinterpret(Float32, 0x3f800000) === 1.0f0

    # Printing names the type and hides the payload, however it is asked for.
    for s in (repr(u), string(u), sprint(print, u), sprint(show, u), repr(MIME"text/plain"(), u))
        @test occursin("Untrusted{UInt32}", s)
        @test occursin("redacted", s)
        @test !occursin("deadbeef", s) && !occursin(string(0xdeadbeef), s)
    end
    for s in (repr(v), string(v), repr(MIME"text/plain"(), v), sprint(show, [v]))
        @test occursin("redacted", s)
        @test !occursin("0x42", s) && !occursin("66", s)
    end

    # The scan reports a `reinterpret` of an `Untrusted` as the payload read it attempts.
    fr(u::Untrusted{UInt32}) = reinterpret(UInt32, u) + 1
    fi = only(findings(fr, (Untrusted{UInt32},); guarantees = (:trusted,)))
    @test StrictMode._failed(fi)
    @test occursin("outside a trust boundary (reinterpret)", fi.reason)
    @test_throws "(tried `reinterpret`)" fr(u)              # and the call itself raises
    # A `reinterpret` of a plain value in the same function reads no payload.
    clean(u::Untrusted{UInt32}, x::Float32) = (u, reinterpret(UInt32, x))
    fc = only(findings(clean, (Untrusted{UInt32}, Float32); guarantees = (:trusted,)))
    @test !StrictMode._failed(fc)
end

@testitem "Untrusted does not compare, hash or dump its payload" begin
    using StrictMode
    u = Untrusted(UInt32(0xdeadbeef))
    w = Untrusted(UInt32(0xdeadbeef))

    # Comparing or hashing reads the payload, so each raises as a field read does.
    @test_throws "`Untrusted` data has no readable fields (tried `==`)" u == w
    @test_throws "(tried `==`)" u != w
    @test_throws "(tried `isequal`)" isequal(u, w)
    @test_throws "(tried `hash`)" hash(u)
    @test_throws "(tried `hash`)" hash(u, UInt(1))
    # A container compares and hashes its elements with the same functions.
    @test_throws "(tried `==`)" [u] == [w]
    @test_throws "(tried `isequal`)" isequal([u], [w])
    @test_throws "(tried `hash`)" hash([u])
    @test_throws "(tried `==`)" (u, 1) == (w, 1)
    @test_throws "(tried `hash`)" Dict(u => 1)
    @test_throws "(tried `hash`)" Set([u])
    # Controls: the payload type itself still compares and hashes.
    @test UInt32(0xdeadbeef) == UInt32(0xdeadbeef)
    @test hash([UInt32(1)]) == hash([UInt32(1)])
    # `===` is a builtin and compares bits; it cannot be overridden.
    @test u === w
    @test u !== Untrusted(UInt32(1))

    # `dump` redacts the payload, at the top level and inside another value.
    s = sprint(dump, u)
    @test occursin("Untrusted{UInt32}", s) && occursin("redacted", s)
    @test !occursin("deadbeef", s) && !occursin(string(0xdeadbeef), s)
    s = sprint(dump, (; a = 1, b = Untrusted(UInt8[0x42, 0x43])))
    @test occursin("b: Untrusted{Vector{UInt8}}(<redacted>)", s)
    @test !occursin("0x42", s) && !occursin("66", s)
    @test occursin("deadbeef", sprint(dump, (; b = UInt32(0xdeadbeef))))   # control

    # These methods read no payload, so neither check reports them. A method that always raises
    # gets the always-throws note (SM0208) in place of a pass.
    for (f, tt) in (
            (==, (Untrusted{UInt32}, Untrusted{UInt32})),
            (isequal, (Untrusted{UInt32}, Untrusted{UInt32})),
            (hash, (Untrusted{UInt32}, UInt)),
            (dump, (IOContext{IOBuffer}, Untrusted{UInt32}, Int, String)),
        )
        fi = only(findings(f, tt; guarantees = (:trusted,)))
        @test fi.status === :pass || fi.code === :SM0208
    end
    @test isempty(unsafe_report(StrictMode; only = [:(==), :isequal, :hash, :dump]))
end

@testitem "a field read inside a try does not clear a payload read" begin
    using StrictMode

    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))
    # The catch swallows the field-2 raise, and the payload stored before it is returned.
    function sneak(p)
        a = 0
        try
            a = getfield(p, 1)
            getfield(p, 2)
        catch
        end
        return a
    end
    @test sneak(Untrusted(42)) == 42
    r = status(sneak, (Any,))
    @test StrictMode._failed(r)
    @test occursin("may read an `Untrusted` payload", r.reason)
    # Control: outside a `try` the field-2 read raises on an `Untrusted` before the payload is used.
    straight(p) = (a = getfield(p, 1); getfield(p, 2); a)
    @test status(straight, (Any,)).status === :pass
    # A handler that rethrows on every path lets the field-2 raise through, as does a `finally`.
    function rethrown(p)
        try
            a = getfield(p, 1)
            getfield(p, 2)
            return a
        catch e
            rethrow()
        end
    end
    function fin(p)
        a = 0
        try
            a = getfield(p, 1)
            getfield(p, 2)
        finally
        end
        return a
    end
    @test_throws BoundsError rethrown(Untrusted(42))
    @test_throws BoundsError fin(Untrusted(42))
    @test status(rethrown, (Any,)).status === :pass
    @test status(fin, (Any,)).status === :pass
    # A handler that rethrows on one path and returns on the other still swallows.
    function sometimes(p, q::Bool)
        a = 0
        try
            a = getfield(p, 1)
            getfield(p, 2)
        catch e
            q && rethrow()
        end
        return a
    end
    @test sometimes(Untrusted(42), false) == 42
    @test StrictMode._failed(status(sometimes, (Any, Bool)))
    # A handler runs before it rethrows, so one that reads the local holding the payload hands it
    # on, whether it is a `catch` or a `finally`.
    SINK = Ref{Any}(nothing)
    function sneak_finally(p)
        local v
        try
            v = getfield(p, 1)
            getfield(p, 2)
        finally
            SINK[] = v
        end
        return nothing
    end
    function sneak_rethrow(p)
        local v
        try
            v = getfield(p, 1)
            getfield(p, 2)
        catch
            SINK[] = v
            rethrow()
        end
        return nothing
    end
    for f in (sneak_finally, sneak_rethrow)
        SINK[] = nothing
        @test_throws BoundsError f(Untrusted(42))
        @test SINK[] == 42
        res = status(f, (Any,))
        @test StrictMode._failed(res)
        @test occursin("may read an `Untrusted` payload", res.reason)
    end
    # A local copied from the payload local before the raise is the payload too.
    function sneak_copy(p)
        local w
        try
            v = getfield(p, 1)
            w = v
            getfield(p, 2)
        finally
            SINK[] = w
        end
        return nothing
    end
    SINK[] = nothing
    @test_throws BoundsError sneak_copy(Untrusted(42))
    @test SINK[] == 42
    @test StrictMode._failed(status(sneak_copy, (Any,)))
    # So is one copied through a chain of locals, and one the handler reads on only one branch.
    function sneak_two(p)
        local w
        try
            v = getfield(p, 1)
            u = v
            w = u
            getfield(p, 2)
        catch
            SINK[] = w
            rethrow()
        end
        return nothing
    end
    function sneak_branch(p, b::Bool)
        local v
        try
            v = getfield(p, 1)
            getfield(p, 2)
        catch
            b && (SINK[] = v)
            rethrow()
        end
        return nothing
    end
    SINK[] = nothing
    @test_throws BoundsError sneak_two(Untrusted(42))
    @test SINK[] == 42
    @test StrictMode._failed(status(sneak_two, (Any,)))
    SINK[] = nothing
    @test_throws BoundsError sneak_branch(Untrusted(42), true)
    @test SINK[] == 42
    @test StrictMode._failed(status(sneak_branch, (Any, Bool)))
    # A local assigned before the raise but never from the payload hands nothing on.
    function counter_only(p)
        local n
        try
            v = getfield(p, 1)
            n = 0
            getfield(p, 2)
        catch
            SINK[] = n
            rethrow()
        end
        return nothing
    end
    SINK[] = nothing
    @test_throws BoundsError counter_only(Untrusted(42))
    @test iszero(SINK[])
    @test status(counter_only, (Any,)).status === :pass
end

@testitem "getfield handed to another call as a value is a read" begin
    using StrictMode

    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))
    const UI = Untrusted{Int}
    dotted(u::UI) = only(getfield.([u], :x))
    dotted_ref(u::UI) = getfield.(Ref(u), :x)
    splatted(u::UI) = getfield((u, :x)...)
    fixed(u::UI) = Base.Fix2(getfield, :x)(u)
    mapped(u::UI) = only(map(getfield, [u], [:x]))
    for f in (dotted, dotted_ref, splatted, fixed, mapped)
        @test f(Untrusted(42)) == 42
        r = status(f, (UI,))
        @test StrictMode._failed(r)
        @test occursin("reads an `Untrusted` payload outside a trust boundary", r.reason)
    end
    @test_throws StrictViolation @assert_trusted dotted(Untrusted(42))
    # An untyped value handed with `getfield` cannot be ruled out.
    loose(v::Vector{Any}) = map(getfield, v, [:x])
    r = status(loose, (Vector{Any},))
    @test StrictMode._failed(r)
    @test occursin("may read an `Untrusted` payload", r.reason)

    # Controls: `getfield` applied to values that cannot be an `Untrusted` reads no payload.
    struct Pt
        a::Int
        b::Int
    end
    fields(p::Pt) = getfield.(Ref(p), (:a, :b))
    mapped_clean(ps::Vector{Pt}) = map(getfield, ps, fill(:a, length(ps)))
    fixed_clean(p::Pt) = Base.Fix2(getfield, :a)(p)
    # A membership test compares with the function and applies it to nothing.
    is_reader(f) = f in (getfield, getproperty)
    not_reader(f) = f ∉ (getfield, getproperty)
    @test status(fields, (Pt,)).status === :pass
    @test status(mapped_clean, (Vector{Pt},)).status === :pass
    @test status(fixed_clean, (Pt,)).status === :pass
    @test status(is_reader, (Any,)).status === :pass
    @test status(not_reader, (Any,)).status === :pass
end

@testitem "reinterpret of an array and write of a Ref read the payload bytes" begin
    using StrictMode

    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))
    const UI = Untrusted{Int}
    peek_array(u::UI) = reinterpret(Int, [u])[1]
    peek_write(u::UI) = (io = IOBuffer(); write(io, Ref(u)); reinterpret(Int, take!(io))[1])
    peek_write_array(u::UI) = (io = IOBuffer(); write(io, [u]); reinterpret(Int, take!(io))[1])
    for f in (peek_array, peek_write, peek_write_array)
        @test_throws "no readable fields" f(Untrusted(42))
        r = status(f, (UI,))
        @test StrictMode._failed(r)
        @test occursin("reads an `Untrusted` payload outside a trust boundary", r.reason)
    end
    # The call raises at run time; a caller that catches the raise is still reported.
    peek_caught(u::UI) = try
        reinterpret(Int, [u])[1]
    catch
        0
    end
    @test_throws StrictViolation @assert_trusted peek_caught(Untrusted(42))
    # Controls: the same calls on plain data, next to an `Untrusted` that is only passed along.
    clean_array(u::UI, x::Vector{Int}) = (u, reinterpret(UInt8, x))
    clean_write(u::UI, x::Int) = (io = IOBuffer(); write(io, Ref(x)); write(io, "s"); (u, take!(io)))
    @test status(clean_array, (UI, Vector{Int})).status === :pass
    @test status(clean_write, (UI, Int)).status === :pass
end

@testitem "a field read handed on by name is judged by that name" begin
    using StrictMode

    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))
    # Field `:a` and a two-argument `getproperty` raise on an `Untrusted`, whatever the name, so
    # neither can hand out the payload.
    gp_a(xs::Vector{Any}) = getproperty.(xs, :a)
    gp_x(xs::Vector{Any}) = getproperty.(xs, :x)
    gf_a(xs::Vector{Any}) = getfield.(xs, :a)
    @test_throws "no readable fields" gp_a(Any[Untrusted(1)])
    @test_throws "no readable fields" gp_x(Any[Untrusted(1)])
    @test_throws FieldError gf_a(Any[Untrusted(1)])
    for f in (gp_a, gp_x, gf_a)
        @test status(f, (Vector{Any},)).status === :pass
    end
    # The payload field, by name or by index, still cannot be ruled out.
    gf_x(xs::Vector{Any}) = getfield.(xs, :x)
    gf_1(xs::Vector{Any}) = getfield.(xs, 1)
    gp_x_order(xs::Vector{Any}) = getproperty.(xs, :x, :not_atomic)
    @test gf_x(Any[Untrusted(42)]) == [42]
    @test gf_1(Any[Untrusted(42)]) == [42]
    for f in (gf_x, gf_1, gp_x_order)
        r = status(f, (Vector{Any},))
        @test StrictMode._failed(r)
        @test occursin("may read an `Untrusted` payload", r.reason)
    end
end

@testitem "a byte copier is judged by the type it is handed" begin
    using StrictMode

    status(f, T) = only(StrictMode.findings(f, T; guarantees = (:trusted,)))
    # A concrete type is judged exactly: one with no `Untrusted` field hands none over.
    w_float(io::IO, x::Float64) = write(io, x)
    r_int64(x::Int64) = reinterpret(UInt64, x)
    @test status(w_float, (IOBuffer, Float64)).status === :pass
    @test status(r_int64, (Int64,)).status === :pass
    # Any package can subtype an abstract type with a struct holding an `Untrusted`, and its bits
    # copy out through the abstract signature.
    abstract type Msg end
    struct Raw <: Msg
        u::Untrusted{UInt64}
    end
    @test reinterpret(UInt64, Raw(Untrusted(UInt64(0xbeef)))) === UInt64(0xbeef)
    leak_abs(m::Msg) = reinterpret(UInt64, m)
    leak_conc(m::Raw) = reinterpret(UInt64, m)
    @test leak_abs(Raw(Untrusted(UInt64(0xbeef)))) === UInt64(0xbeef)
    # A type that can hold one is a copy that cannot be ruled out, and the reason names it.
    w_real(io::IO, x::Real) = write(io, x)
    w_str(io::IO, s::AbstractString) = write(io, s)
    w_io(io::IO, src::IO) = write(io, src)
    r_int(x::Integer) = reinterpret(UInt64, x)
    w_any(io::IO, x) = write(io, x)
    r_vany(v::Vector{Any}) = reinterpret(UInt8, v)
    w_dict(io::IO, d::AbstractDict{Int, Untrusted{Int}}) = write(io, d)
    for (f, T, nm) in (
            (leak_abs, (Msg,), "reinterpret of $(Msg)"),
            (leak_conc, (Raw,), "reinterpret of $(Raw)"),
            (w_real, (IOBuffer, Real), "write of Real"),
            (w_str, (IOBuffer, AbstractString), "write of AbstractString"),
            (w_io, (IOBuffer, IO), "write of IO"),
            (r_int, (Integer,), "reinterpret of Integer"),
            (w_any, (IOBuffer, Any), "write of Any"),
            (r_vany, (Vector{Any},), "reinterpret of Vector{Any}"),
            (w_dict, (IOBuffer, AbstractDict{Int, Untrusted{Int}}), "write of AbstractDict{Int64, Untrusted{Int64}}"),
        )
        r = status(f, T)
        @test StrictMode._failed(r)
        @test occursin("may read an `Untrusted` payload", r.reason)
        @test occursin(nm, r.reason)
        @test !occursin("inference lost", r.reason)
    end
end

@testitem "copying an Untrusted's bits out of an array or a Ref raises" begin
    using StrictMode, Test

    u = Untrusted(42)
    io = IOBuffer()
    @test_throws "(tried `reinterpret`)" reinterpret(Int, [u])
    @test_throws "(tried `reinterpret`)" reinterpret(Int, view([u, u], 1:2))
    @test_throws "(tried `reinterpret`)" reinterpret(reshape, Int, [u])
    @test_throws "(tried `write`)" write(io, Ref(u))
    @test_throws "(tried `write`)" write(io, [u])
    @test_throws "(tried `write`)" write(io, [u u])
    @test_throws "(tried `write`)" write(io, view([u, u], [2]))
    @test_throws "(tried `unsafe_write`)" unsafe_write(io, Ref(u), sizeof(Int))
    @test isempty(take!(io))
    # Controls: the same calls on plain `isbits` data still copy its bits.
    @test reinterpret(Int, reinterpret(UInt8, [5])) == [5]
    @test vec(reinterpret(reshape, UInt8, [1.0f0])) == [0x00, 0x00, 0x80, 0x3f]
    @test write(io, Ref(7)) == sizeof(Int)
    @test write(io, [1, 2]) == 2 * sizeof(Int)
    @test unsafe_write(io, Ref(3), sizeof(Int)) == sizeof(Int)
    @test reinterpret(Int, take!(io)) == [7, 1, 2, 3]
    # The methods that raise add no ambiguity with Base.
    @test isempty(filter(p -> any(m -> parentmodule(m) === StrictMode, p), Test.detect_ambiguities(Base, StrictMode)))
end
