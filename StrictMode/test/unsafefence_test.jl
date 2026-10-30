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

@testitem "unsafe_report does not claim to cover @inbounds" begin
    using StrictMode

    # `@inbounds` leaves no node in lowered or typed IR: it rides in per-statement flags. The scan
    # therefore cannot see it, and this pins that rather than leaving a reader to assume coverage —
    # the docstring says so, and a future editor must not quietly rely on it.
    module FenceInbounds
    elided(v::Vector{Float64}) = @inbounds v[1]
    end
    @test isempty(unsafe_report(FenceInbounds))

    lowered = first(Base.code_lowered(FenceInbounds.elided, (Vector{Float64},)))
    @test !any(st -> st isa Expr && st.head in (:inbounds, :boundscheck), lowered.code)
end
