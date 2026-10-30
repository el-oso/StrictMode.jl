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
    @test isempty(unsafe_report(FenceAllow; only = r"^nothing_matches$"))
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
