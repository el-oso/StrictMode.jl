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
    loose_sum(l::LooseBag) = (s = 0.0; for a in l.v; s += a; end; s)
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
