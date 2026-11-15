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

@testitem "foreign raw pointers are followed, and reading them needs a trust boundary" begin
    using StrictMode
    module Foreign
    struct View; p::Ptr{Float64}; n::Int; end
    validated_copy(p::Ptr{Float64}, n::Int) = (n < 0 && error("bad"); [unsafe_load(p, i) for i in 1:n])
    @noinline helper(p::Ptr{Float64}, n) = unsafe_load(p, n)
    @noinline pass_on(p::Ptr{Float64}, n) = (q = p + 8; helper(q, n))
    c_bad(p::Ptr{Float64}, n::Cint)::Float64 = unsafe_load(p, 1)
    c_wrap(p::Ptr{Float64}, n::Cint)::Float64 = (a = unsafe_wrap(Array, p, Int(n)); a[1])
    c_wraplen(p::Ptr{Float64}, n::Cint)::Int = (a = unsafe_wrap(Array, p, Int(n)); length(a))
    c_deep(p::Ptr{Float64}, n::Cint)::Float64 = pass_on(p, Int(n))
    c_struct(p::Ptr{Float64}, n::Cint)::Float64 = (v = View(p, Int(n)); unsafe_load(v.p))
    c_ok(p::Ptr{Float64}, n::Cint)::Float64 = (x = validated_copy(p, Int(n)); sum(x))
    c_cnull(p::Ptr{Float64}, n::Cint)::Int = p == C_NULL ? 0 : Int(n)
    end
    StrictMode.trust_boundary!(Foreign.validated_copy)
    sig = (Ptr{Float64}, Cint)
    reads(f) = !isempty(first(StrictMode._foreign_sites(f, sig, (1,))))
    @test reads(Foreign.c_bad)
    @test reads(Foreign.c_wrap)                  # indexing an unsafe_wrap'ped array
    @test reads(Foreign.c_deep)                  # through two package callees and pointer arithmetic
    @test reads(Foreign.c_struct)                # through a struct holding the pointer
    @test !reads(Foreign.c_wraplen)              # a length is not a read of the memory
    @test !reads(Foreign.c_ok)                   # read only inside the registered boundary
    @test !reads(Foreign.c_cnull)
    # With no position declared there is nothing to follow: a Ptr is not Untrusted by itself.
    @test isempty(first(StrictMode._foreign_sites(Foreign.c_bad, sig, ())))

    buf = [1.0, 2.0, 3.0]; p = pointer(buf)
    GC.@preserve buf begin
        @test_throws "c_deep → pass_on → helper" (@assert_trusted Foreign.c_deep(p, Cint(2)) foreign = (1,))
        @test (@assert_trusted Foreign.c_ok(p, Cint(2)) foreign = (1,)) == 3.0
    end
    # Declared once, it holds for every sweep.
    StrictMode.trust_foreign!(Foreign.c_wrap, (1,))
    @test StrictMode._failed(only(StrictMode.findings(Foreign.c_wrap, sig; guarantees = (:trusted,))))
    @test_throws ArgumentError StrictMode._foreign_sites(Foreign.c_bad, sig, (3,))
end
