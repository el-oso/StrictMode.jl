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

@testitem "foreign data is judged by the method that runs, and by whether it is an address or memory" begin
    using StrictMode
    module ForeignKinds
    struct Hdr; p::Ptr{Int}; end
    Base.length(h::Hdr) = unsafe_load(h.p)
    Base.getproperty(h::Hdr, s::Symbol) = s === :n ? unsafe_load(getfield(h, :p)) : getfield(h, s)
    struct Parsed; n::Int; Parsed(p::Ptr{Int}) = new(unsafe_load(p)); end
    (h::Hdr)(i) = unsafe_load(getfield(h, :p), i)
    apply(f) = f()
    a(p, n) = n == 0 ? p : b(p, n)
    b(p, n) = a(p, n - 1)
    # Reads, each through something the name of the call does not show.
    e_ctor(p::Ptr{Int}) = Parsed(p).n
    e_len(p::Ptr{Int}) = length(Hdr(p))
    e_prop(p::Ptr{Int}) = Hdr(p).n
    e_clos(p::Ptr{Int}) = (g = () -> unsafe_load(p); g())
    e_clos2(p::Ptr{Int}) = apply(() -> unsafe_load(p))
    e_functor(p::Ptr{Int}) = (h = Hdr(p); h(1))
    e_eq(p::Ptr{Int}, n) = unsafe_wrap(Array, p, n) == [1, 2, 3]
    e_str(p::Ptr{Int}, n) = string(unsafe_wrap(Array, p, n))
    e_copy(p::Ptr{Int}, n) = Vector{Int}(unsafe_wrap(Array, p, n))
    e_tuple(p::Ptr{Int}, n) = Tuple(unsafe_wrap(Array, p, n))
    e_ccall(p::Ptr{UInt8}, n) = ccall(:jl_pchar_to_string, Ref{String}, (Ptr{UInt8}, Int), p, n)
    e_memo(p::Ptr{Int}) = (x = a(p, 1); y = b(p, 2); unsafe_load(y))
    # Not reads: the address is checked, compared or carried, and a wrapped array is only measured.
    e_view(p::Ptr{Int}, n) = length(view(unsafe_wrap(Array, p, n), 1:2))
    e_align(p::Ptr{Int}) = UInt(p) % 8 == 0
    e_kw(p::Ptr{Int}, n) = length(unsafe_wrap(Array, p, n; own = false))
    e_null(p::Ptr{Int}) = p == C_NULL ? 0 : 1
    e_isnull(p::Ptr{Int}) = iszero(UInt(p))
    e_diff(p::Ptr{Int}, q::Ptr{Int}) = div(q - p, 8)
    e_ref(p::Ptr{Int}) = (r = Ref(p); r[] == C_NULL)
    e_isempty(p::Ptr{Int}, n) = isempty(unsafe_wrap(Array, p, n))
    end
    F = ForeignKinds
    reads(f, ts, pos = (1,)) = !isempty(first(StrictMode._foreign_sites(f, ts, pos)))
    P = (Ptr{Int},); PN = (Ptr{Int}, Int)
    for f in (F.e_ctor, F.e_len, F.e_prop, F.e_clos, F.e_clos2, F.e_functor, F.e_memo)
        @test reads(f, P)
    end
    for f in (F.e_eq, F.e_str, F.e_copy, F.e_tuple)
        @test reads(f, PN)
    end
    @test reads(F.e_ccall, (Ptr{UInt8}, Int))
    for f in (F.e_align, F.e_null, F.e_isnull, F.e_ref)
        @test !reads(f, P)
    end
    for f in (F.e_view, F.e_kw, F.e_isempty)
        @test !reads(f, PN)
    end
    @test !reads(F.e_diff, (Ptr{Int}, Ptr{Int}), (1, 2))
    # The chain names the package method that read it.
    @test occursin("getproperty", only(first(StrictMode._foreign_sites(F.e_prop, P, (1,)))))
end

@testitem "a read is found through Base, containers, keywords, C and recursion" begin
    using StrictMode
    module ForeignDeep
    mutable struct State; p::Ptr{Int}; State() = new(C_NULL); end
    struct It; p::Ptr{Int}; n::Int; end
    Base.iterate(it::It, i = 1) = i > it.n ? nothing : (unsafe_load(it.p, i), i + 1)
    Base.length(it::It) = it.n
    kwf(; ptr) = unsafe_load(ptr)
    r_rec(p, n) = n == 0 ? unsafe_wrap(Array, p, 4) : (a = r_rec(p, n - 1); a[1]; a)
    r_hof(p::Ptr{Int}, n) = sum(i -> unsafe_load(p, i), 1:n)
    r_gen(p::Ptr{Int}, n) = sum(unsafe_load(p, i) for i in 1:n)
    r_iter(p::Ptr{Int}, n) = collect(It(p, n))
    r_ref(p::Ptr{Int}, n) = (r = Ref{Ptr{Int}}(); r[] = p; unsafe_load(r[]))
    r_vec(p::Ptr{Int}, n) = (v = Ptr{Int}[]; push!(v, p); unsafe_load(v[1]))
    r_state(p::Ptr{Int}, n) = (s = State(); s.p = p; unsafe_load(s.p))
    r_box(p::Ptr{Int}, n) = (q = p; q = q + 8; g() = unsafe_load(q); g())
    r_kw(p::Ptr{Int}, n) = kwf(; ptr = p)
    r_memcpy(p::Ptr{Int}, n) = (b = zeros(Int, n); ccall(:memcpy, Ptr{Cvoid}, (Ptr{Int}, Ptr{Int}, Csize_t), b, p, 8n); b[1])
    r_write(p::Ptr{Int}, n) = unsafe_write(IOBuffer(), p, n)
    r_recur(p::Ptr{Int}, n) = length(r_rec(p, 2))
    n_ptrarith(p::Ptr{Int}, n) = (a = unsafe_wrap(Array, p, n); pointer(a) + 8 == C_NULL)
    n_lin(p::Ptr{Int}, n) = length(LinearIndices(unsafe_wrap(Array, p, n)))
    n_fill(p::Ptr{Int}, n) = (fill!(unsafe_wrap(Array, p, n), 0); nothing)
    n_throw(p::Ptr{Int}, n) = p == C_NULL ? throw(ArgumentError("null: $p")) : 1
    end
    F = ForeignDeep
    PN = (Ptr{Int}, Int)
    reads(f) = !isempty(first(StrictMode._foreign_sites(f, PN, (1,))))
    clear(f) = (r = StrictMode._foreign_sites(f, PN, (1,)); isempty(r[1]) && isempty(r[2]))
    for f in (F.r_hof, F.r_iter, F.r_ref, F.r_state, F.r_kw, F.r_write)
        @test reads(f)
    end
    # Reached only through a value the scan assumes is foreign — a Base splat it cannot resolve, a
    # buffer C may have filled, a recursive result not yet settled: reported, as uncertain.
    for f in (F.r_gen, F.r_vec, F.r_memcpy, F.r_recur)
        @test !clear(f)
    end
    # A reassigned captured variable lives in a `Core.Box`, typed `Any`: not resolvable, so not cleared.
    @test !clear(F.r_box)
    for f in (F.n_ptrarith, F.n_lin, F.n_fill, F.n_throw)
        @test clear(f)
    end
    # Bounded: functions that all call each other give an answer, uncertain past the body budget.
    m = Module(:AllCall)
    for i in 1:7
        calls = join(["(n > $j ? f$j(p + $j, n - 1) : 0)" for j in 1:7 if j != i], " + ")
        Core.eval(m, Meta.parse("f$i(p::Ptr{Int}, n::Int) = $calls"))
    end
    t = @elapsed r = StrictMode._foreign_sites(getfield(m, :f1), PN, (1,))
    @test isempty(r[1]) && t < 60
end

@testitem "overloads behind Base functions, aliases, and assumptions are judged correctly" begin
    using StrictMode
    module ForeignR3
    struct H; p::Ptr{UInt8}; end
    Base.show(io::IO, h::H) = print(io, unsafe_string(h.p))
    struct Peek <: Number; v::Float64; end
    Peek(x::UInt) = Peek(unsafe_load(Ptr{Float64}(x)))
    fp_print(p::Ptr{UInt8}, n) = (io = IOBuffer(); print(io, H(p)); 1)
    fp_string(p::Ptr{UInt8}, n) = string(H(p))
    fp_convert(p::Ptr{Float64}, n) = convert(Peek, UInt(p)).v
    fp_setmem(p::Ptr{Float64}, n) = (a = unsafe_wrap(Array, p, n); d = zeros(n); d[:] = a; d[1])
    fp_alias(p::Ptr{Float64}, n) = (r = Ref{Ptr{Float64}}(); v = r; v[] = p; unsafe_load(r[]))
    fp_cond(p::Ptr{Float64}, n) = (a = Ref{Ptr{Float64}}(); b = Ref{Ptr{Float64}}(); v = n > 0 ? a : b; v[] = p; unsafe_load(a[]))
    fp_nested2(p::Ptr{Float64}, n) = (d = Dict(1 => Ref{Ptr{Float64}}()); d[1][] = p; unsafe_load(d[1][]))
    ff_push(p::Ptr{Float64}, n) = (v = Ptr{Float64}[]; push!(v, p); length(v))
    ff_vect(p::Ptr{Float64}, n) = (v = [p]; length(v))
    ff_free(p::Ptr{Float64}, n) = (p == C_NULL && return 0; ccall(:memset, Ptr{Cvoid}, (Ptr{Cvoid}, Cint, Csize_t), p, 0, n); 1)
    ff_ntuple(p::Ptr{Float64}, n) = ntuple(i -> p + 8i, 3)
    ff_outcopy(p::Ptr{Float64}, n) = (src = zeros(n); unsafe_copyto!(p, pointer(src), n); 1)
    ff_refmem(p::Ptr{Float64}, n) = (a = unsafe_wrap(Array, p, n); r = Ref(a); 1)
    end
    F = ForeignR3
    sites(f, T) = StrictMode._foreign_sites(f, (Ptr{T}, Int), (1,))
    certain(f, T) = !isempty(first(sites(f, T)))
    cleared(f, T) = (r = sites(f, T); isempty(r[1]) && isempty(r[2]))
    @test certain(F.fp_print, UInt8)                  # Base `print` into a package `show`
    @test !cleared(F.fp_string, UInt8)                # the same through `string`: at least a warning
    @test certain(F.fp_convert, Float64)              # Base `convert` into a package constructor
    for f in (F.fp_setmem, F.fp_alias, F.fp_cond, F.fp_nested2)
        @test certain(f, Float64)
    end
    # No certain read: an assumed value, a C call on the address, a write into foreign memory.
    for f in (F.ff_push, F.ff_vect, F.ff_free, F.ff_ntuple, F.ff_outcopy, F.ff_refmem)
        @test !certain(f, Float64)
    end
end
