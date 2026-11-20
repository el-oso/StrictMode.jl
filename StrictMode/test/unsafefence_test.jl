@testitem "unsafe_report names every construct that leaves the language" begin
    using StrictMode

    module FenceKernels
    raw(x::Int) = ccall(:abs, Cint, (Cint,), x)
    load(v::Vector{Float64}) = unsafe_load(pointer(v), 1)
    wrap(p::Ptr{Float64}) = unsafe_wrap(Array, p, 4)
    clean(v::Vector{Float64}) = sum(v)
    end

    fs = unsafe_report(FenceKernels)
    by = Dict(f.func => f for f in fs)
    @test Set(keys(by)) == Set(["raw", "load", "wrap"])     # `clean` is not reported
    @test all(f -> f.guarantee === :unsafe && f.code === :SM0206, fs)

    @test occursin("`ccall`", by["raw"].reason)
    @test occursin("`pointer`", by["load"].reason) && occursin("`unsafe_load`", by["load"].reason)
    @test occursin("`unsafe_wrap`", by["wrap"].reason)
    @test occursin("allow = (:ccall,)", by["raw"].suggestion)

    # A `ccall` lowers its arguments through `cconvert` and `unsafe_convert`. Those are the ccall,
    # not two more things to fix, so they must not appear beside it.
    @test !occursin("unsafe_convert", by["raw"].reason)
    @test !occursin("cconvert", by["raw"].reason)
end

@testitem "unsafe_report blames the method that wrote the unsafe call" begin
    using StrictMode

    module FenceInlined
    @inline peek(v::Vector{Float64}) = unsafe_load(pointer(v), 1)
    innocent(v::Vector{Float64}) = peek(v) + 1.0
    end

    # This is why the scan reads UNOPTIMIZED IR. Under optimization the helper inlines and its
    # pointer load appears in the caller's body, so an optimized scan would report a method that
    # contains no unsafe code of its own while letting the one that does look clean.
    flagged = Set(f.func for f in unsafe_report(FenceInlined))
    @test flagged == Set(["peek"])

    ci = first(Base.code_typed(FenceInlined.innocent, (Vector{Float64},); optimize = true))[1]
    @test any(st -> occursin("pointerref", string(st)) || occursin("unsafe_load", string(st)), ci.code)
end

@testitem "unsafe_report excuses only what allow names" begin
    using StrictMode

    module FenceAllow
    raw(x::Int) = ccall(:abs, Cint, (Cint,), x)
    load(v::Vector{Float64}) = unsafe_load(pointer(v), 1)
    end

    @test length(unsafe_report(FenceAllow)) == 2
    # Excusing the pointer read leaves the `ccall` held: the exception is per construct, not a
    # blanket opt-out for the module.
    one_left = unsafe_report(FenceAllow; allow = (:unsafe_load, :pointer))
    @test only(one_left).func == "raw"
    @test isempty(unsafe_report(FenceAllow; allow = (:ccall, :unsafe_load, :pointer)))
    # …and the name filters work as they do on every other sweep.
    @test_throws "matches no function" unsafe_report(FenceAllow; only = r"^nothing_matches$")
    @test only(unsafe_report(FenceAllow; exempt = (:load,))).func == "raw"
end

@testitem "unsafe_report covers @inbounds, read from the statement flags" begin
    using StrictMode

    module FenceInbounds
    Base.@propagate_inbounds prop(a::Vector{Float64}, i::Int) = a[i]
    elided(v::Vector{Float64}) = @inbounds v[1]
    block(v::Vector{Float64}) = (
        s = 0.0; @inbounds for i in eachindex(v)
            s += v[i]
        end; s
    )
    viacaller(a::Vector{Float64}, i::Int) = @inbounds prop(a, i)
    clean(v::Vector{Float64}) = sum(v)
    simd(v::Vector{Float64}) = (
        s = 0.0; @simd for i in eachindex(v)
            s += v[i]
        end; s
    )
    end
    F = FenceInbounds
    F.prop([1.0], 1); F.elided([1.0]); F.block([1.0]); F.viacaller([1.0], 1); F.clean([1.0]); F.simd([1.0])

    # The three methods that wrote `@inbounds`, and only those. A `@propagate_inbounds` method makes
    # no claim of its own, so the finding belongs to the caller that did; `@simd` sets no flag.
    @test Set(f.func for f in unsafe_report(F)) == Set(["elided", "block", "viacaller"])
    @test all(f -> f.status === :fail, unsafe_report(F))
    @test occursin("`@inbounds`", only(filter(f -> f.func == "elided", unsafe_report(F))).reason)
    @test isempty(unsafe_report(F; allow = (:inbounds,)))

    # Why it is read from `ssaflags`: no statement survives to match on. This is the fact the scan
    # depends on, and it is also what makes an optimized read useless here.
    tt = (Vector{Float64},)
    lowered = first(Base.code_lowered(F.elided, tt))
    @test !any(st -> st isa Expr && st.head in (:inbounds, :boundscheck), lowered.code)

    # `IR_FLAG_INBOUNDS` is a compiler internal, so its identity is pinned rather than assumed.
    flags(ci) = findall(fl -> !iszero(fl & StrictMode._IR_FLAG_INBOUNDS), ci.ssaflags)
    @test StrictMode._IR_FLAG_INBOUNDS === UInt32(1)
    @test !isempty(flags(Base.code_typed(F.elided, tt; optimize = false)[1][1]))
    @test isempty(flags(Base.code_typed(F.clean, tt; optimize = false)[1][1]))
    # Inlining consumes the flag, which is why the scan must stay on unoptimized IR.
    @test isempty(flags(Base.code_typed(F.elided, tt; optimize = true)[1][1]))
end

@testitem "unsafe_report charges a construct to the method that wrote it" begin
    using StrictMode
    # The generic method's declared signature also matches the specific one. Read through inference,
    # that returned both bodies, and the generic method was charged with its sibling's `@inbounds`.
    module Siblings
    first_of(x::AbstractVector) = first(x)
    first_of(x::Vector{Float64}) = @inbounds x[1]
    end
    fs = unsafe_report(Siblings)
    @test length(fs) == 1
    @test occursin("Vector{Float64}", only(fs).signature)
end

@testitem "unsafe_report sees an unsafe call whose result is assigned" begin
    using StrictMode
    module Assigned
    slotassign(a) = (p = pointer(a); x = unsafe_load(p); x)
    cc(n) = (r = ccall(:jl_cpu_threads, Cint, ()); r + n)
    gf(p::Ptr{Float64}) = getfield(Base, :unsafe_load)(p)
    end
    uc(f) = StrictMode._unsafe_constructs(only(methods(f)))
    @test uc(Assigned.slotassign) == [:pointer, :unsafe_load]
    @test uc(Assigned.cc) == [:ccall]
    @test uc(Assigned.gf) == [:unsafe_load]
end

@testitem "unsafe_report fails a method whose code it could not read" begin
    using StrictMode

    module UnreadUnsafe
    @generated raises(x) = error("the generator raised")
    @generated loads(p::Ptr{T}) where {T} = :(unsafe_load(p))
    @generated clean(x::NTuple{N, T}) where {N, T} = :(x[1])
    end

    # A generator that raises leaves no code to read, which is not the same as code with no unsafe
    # construct in it: the first is `nothing`, the second an empty list.
    @test isnothing(StrictMode._unsafe_constructs(only(methods(UnreadUnsafe.raises))))
    @test isempty(StrictMode._unsafe_constructs(only(methods(UnreadUnsafe.clean))))
    @test StrictMode._unsafe_constructs(only(methods(UnreadUnsafe.loads))) == [:unsafe_load]

    fs = unsafe_report(UnreadUnsafe)
    unread = only(filter(x -> x.func == "raises", fs))
    @test StrictMode._failed(unread)
    @test unread.code === :SM0203
    @test occursin("could not be read", unread.reason)
    @test only(filter(x -> x.func == "loads", fs)).code === :SM0206
    @test !any(x -> x.func == "clean", fs)
end

@testitem "unsafe_report catches every spelling of an unsafe construct" begin
    using StrictMode

    # One method per spelling. Each must be reported, with the construct named.
    module FenceSpellings
    plain(p) = unsafe_load(p)
    kwcall(p) = unsafe_wrap(Array, p, 2; own = false)
    broadcasted(ps) = unsafe_load.(ps)
    mapped(ps) = map(unsafe_load, ps)
    splatted(args) = unsafe_load(args...)
    aliased(p) = (f = unsafe_load; f(p))
    returned() = unsafe_load
    qualified(p) = Base.unsafe_load(p)
    qualified_mapped(ps) = map(Base.unsafe_load, ps)
    composed(p) = (identity ∘ unsafe_load)(p)
    closure(p) = map(q -> unsafe_load(q), [p])
    doblock(p) = open(devnull) do io
        unsafe_load(p)
    end
    intrinsic_ref(p) = Core.Intrinsics.pointerref(p, 1, 1)
    intrinsic_set(p) = Core.Intrinsics.pointerset(p, 0.0, 1, 1)
    llvm(x) = Base.llvmcall("ret i64 %0", Int, Tuple{Int}, x)
    cglob() = cglobal(:jl_options)
    cfun() = @cfunction(sin, Float64, (Float64,))
    malloc() = Libc.malloc(8)
    free(p) = Libc.free(p)
    calloc() = Libc.calloc(1, 8)
    freed_all(ps) = foreach(Libc.free, ps)
    ptr_from_int(x::Int) = Ptr{Float64}(x)
    ptr_cvoid(x::UInt) = Ptr{Cvoid}(x)
    ptr_reinterpret(x::UInt) = reinterpret(Ptr{Float64}, x)
    ptr_param(::Type{T}, x::UInt) where {T} = Ptr{T}(x)
    memref_new(v) = Base.memoryrefnew(v.ref, 100, false)
    memref_get(v) = Base.memoryrefget(v.ref, :not_atomic, false)
    memref_set(v) = Base.memoryrefset!(v.ref, 0.0, :not_atomic, false)
    tuple_unchecked(t, i) = getfield(t, i, false)
    objref(x) = pointer_from_objref(x)
    stored_qualified(p) = (f = Base.unsafe_load; f(p))
    stored_libc(p) = (fr = Libc.free; fr(p))
    stored_intrinsic(p) = (f = Core.Intrinsics.pointerref; f(p, 1, 1))
    by_getglobal(p) = getglobal(Base, :unsafe_load)(p)
    stored_getglobal(p) = (f = getglobal(Base, :unsafe_load); f(p))
    ptr_convert(addr::UInt) = convert(Ptr{Float64}, addr)
    end

    expect = Dict(
        "plain" => "unsafe_load", "kwcall" => "unsafe_wrap", "broadcasted" => "unsafe_load",
        "mapped" => "unsafe_load", "splatted" => "unsafe_load", "aliased" => "unsafe_load",
        "returned" => "unsafe_load", "qualified" => "unsafe_load",
        "qualified_mapped" => "unsafe_load", "composed" => "unsafe_load",
        "intrinsic_ref" => "pointerref", "intrinsic_set" => "pointerset", "llvm" => "llvmcall",
        "cglob" => "cglobal", "cfun" => "@cfunction", "malloc" => "malloc", "free" => "free",
        "calloc" => "calloc", "freed_all" => "free", "ptr_from_int" => "Ptr",
        "ptr_cvoid" => "Ptr", "ptr_reinterpret" => "Ptr", "ptr_param" => "Ptr",
        "memref_new" => "memoryrefnew", "memref_get" => "memoryrefget",
        "memref_set" => "memoryrefset!", "tuple_unchecked" => "getfield",
        "objref" => "pointer_from_objref",
        "stored_qualified" => "unsafe_load", "stored_libc" => "free",
        "stored_intrinsic" => "pointerref", "by_getglobal" => "unsafe_load",
        "stored_getglobal" => "unsafe_load", "ptr_convert" => "Ptr",
    )
    fs = unsafe_report(FenceSpellings)
    by = Dict{String, String}()
    for f in fs
        by[f.func] = get(by, f.func, "") * f.reason
    end
    for (name, construct) in expect
        @test haskey(by, name)
        @test occursin("`" * construct * "`", get(by, name, ""))
    end
    # A closure and a `do` block are methods of their own, named after the function that wrote them.
    @test any(f -> occursin("closure", f.func) && occursin("`unsafe_load`", f.reason), fs)
    @test any(f -> occursin("doblock", f.func) && occursin("`unsafe_load`", f.reason), fs)
    @test all(StrictMode._failed, fs)

    # The same shapes with nothing unsafe in them must stay clean.
    module FenceClean
    struct Buf
        data::Vector{Float64}
    end
    plain(v) = v[1]
    kwcall(v) = sort(v; rev = true)
    broadcasted(v) = abs.(v)
    mapped(v) = map(abs, v)
    splatted(args) = max(args...)
    aliased(v) = (f = sum; f(v))
    returned() = sum
    qualified(v) = Base.sum(v)
    closure(v) = map(q -> q + 1, v)
    free(b::Buf) = empty!(b.data)             # a package's own `free` is not `Libc.free`
    release(b::Buf) = free(b)
    takes_ptr(p::Ptr{Float64}) = p            # passing a pointer along dereferences nothing
    ptr_typed(v) = Ptr{Float64}[]             # naming the type builds no pointer
    is_null(p::Ptr{Cvoid}) = p == C_NULL
    field(t) = getfield(t, 1)
    field_checked(t, i) = getfield(t, i, true)
    memref(v) = Base.memoryrefnew(v.ref, 1, true)
    typed(x)::Float64 = x
    converts(x) = convert(Float64, x) + reinterpret(Float64, UInt64(x))
    tuple_get(t) = t[2]
    stringy(x) = string("unsafe_load(", x, ")")
    symbolic() = :unsafe_load
    compares(f) = f === unsafe_load || f == pointer
    stored_clean(v) = (f = Base.sum; f(v))
    by_getglobal_clean(v) = getglobal(Base, :sum)(v)
    qualified_compare(f) = f === Base.unsafe_load
    converts_number(x) = convert(Int, x)
    end
    @test isempty(unsafe_report(FenceClean))

    # `allow` excuses a spelling as it does the plain call, by the construct's name.
    @test isempty(
        unsafe_report(
            FenceSpellings;
            allow = (
                :unsafe_load, :unsafe_wrap, :pointerref, :pointerset, :llvmcall, :cglobal,
                :cfunction, :malloc, :free, :calloc, :Ptr, :memoryrefnew, :memoryrefget,
                :memoryrefset!, :getfield, :pointer_from_objref,
            )
        )
    )
    @test_throws "`allow` names `pointr`" unsafe_report(FenceSpellings; allow = (:pointr,))
    @test_throws "not a construct this scan reports" unsafe_report(FenceSpellings; allow = (:inbound,))
end

@testitem "unsafe_report follows a module or a pointer type kept in a local" begin
    using StrictMode

    module FenceLocals
    module_local(p) = (B = Base; B.unsafe_load(p))
    module_then_function(p) = (B = Base; f = B.unsafe_load; f(p))
    type_local(a) = (T = Ptr{Float64}; T(a))
    type_local_convert(a) = (T = Ptr{Float64}; convert(T, a))
    # The name is a value of the call, so which function this reads is decided at run time.
    by_name(p, nm) = getglobal(Base, nm)(p)
    by_name_qualified(p, nm) = getproperty(Base, nm)(p)
    by_name_local(p, nm) = (B = Base; getfield(B, nm)(p))
    end
    found(nm) = only(f for f in unsafe_report(FenceLocals) if f.func == String(nm)).reason
    @test occursin("unsafe_load", found(:module_local))
    @test occursin("unsafe_load", found(:module_then_function))
    @test occursin("Ptr", found(:type_local))
    @test occursin("Ptr", found(:type_local_convert))
    # Not resolved, and said so: a method that passes this scan calls nothing unsafe by name.
    for nm in (:by_name, :by_name_qualified, :by_name_local)
        @test occursin("dynamic_global", found(nm))
    end
    @test length(unsafe_report(FenceLocals)) == 7
    @test length(unsafe_report(FenceLocals; allow = (:dynamic_global,))) == 4

    module FenceLocalsClean
    struct S
        x::Int
    end
    module_local(v) = (B = Base; B.sum(v))
    type_local(a) = (T = Vector{Float64}; T(a))
    # A field chosen at run time is a field of a value, not a global of a module.
    field_by_name(s, nm) = getfield(s, nm)
    property_by_name(s, nm) = getproperty(s, nm)
    # A variable assigned twice is not followed to either value; neither names anything unsafe.
    twice(v, c) = (f = sum; c && (f = prod); f(v))
    end
    @test isempty(unsafe_report(FenceLocalsClean))
end

@testitem "unsafe_report reads getfield's unchecked form with a memory order" begin
    using StrictMode

    module FenceOrdered
    unchecked(t, i) = getfield(t, i, :not_atomic, false)
    checked(t, i) = getfield(t, i, :not_atomic, true)
    end
    fs = unsafe_report(FenceOrdered)
    @test only(fs).func == "unchecked"
    @test occursin("`getfield`", only(fs).reason)
end

@testitem "unsafe_report reads constructors, top-level lambdas and union callables" begin
    using StrictMode

    module CtorFence
    struct Buf
        p::Ptr{UInt8}
    end
    Buf(n::Int) = Buf(convert(Ptr{UInt8}, Libc.malloc(n)))
    struct Raw
        x::Int
        Raw(v::Vector{Float64}) = new(Int(unsafe_load(pointer(v))))
    end
    const LOAD = p -> unsafe_load(p)
    struct KA end
    struct KB end
    (k::Union{KA, KB})(x) = ccall(:abs, Cint, (Cint,), x)
    end

    fs = unsafe_report(CtorFence)
    @test length(fs) == 4
    @test all(StrictMode._failed, fs)
    reasons = [f.reason for f in fs]
    @test any(r -> occursin("`malloc`", r) && occursin("`Ptr`", r), reasons)
    @test any(r -> occursin("`pointer`", r) && occursin("`unsafe_load`", r), reasons)
    @test count(r -> occursin("`unsafe_load`", r), reasons) == 2
    @test any(r -> occursin("`ccall`", r), reasons)
    # A constructor answers to its type's name; a callable with no name of its own matches no `only`.
    @test length(unsafe_report(CtorFence; only = (:Buf,))) == 1
    @test length(unsafe_report(CtorFence; exempt = (:Buf, :Raw))) == 2

    # A keyword default is evaluated by the positional method as well as by `Core.kwcall`'s.
    module KwDefaultFence
    first_load(p; n = unsafe_load(p)) = n
    end
    @test any(f -> f.func == "first_load" && occursin("`unsafe_load`", f.reason), unsafe_report(KwDefaultFence))
end

@testitem "unsafe_report reads a generated method at each compiled specialization" begin
    using StrictMode

    module GenTyped
    @generated sumtup(t::NTuple{N, Float64}) where {N} = Expr(:call, :+, (:(t[$i]) for i in 1:N)...)
    @generated loadtup(p::NTuple{N, Ptr{Float64}}) where {N} =
        Expr(:call, :+, (:(unsafe_load(p[$i])) for i in 1:N)...)
    end
    # The generator needs the argument types, so before any call there is no code to read.
    r = only(unsafe_report(GenTyped; only = (:sumtup,)))
    @test StrictMode._failed(r)
    @test occursin("could not be read", r.reason)

    @test GenTyped.sumtup((1.0, 2.0)) == 3.0
    v = [1.0, 2.0]
    GC.@preserve v begin
        @test GenTyped.loadtup((pointer(v), pointer(v, 2))) == 3.0
    end
    @test isempty(unsafe_report(GenTyped; only = (:sumtup,)))
    @test occursin("`unsafe_load`", only(unsafe_report(GenTyped; only = (:loadtup,))).reason)
end
