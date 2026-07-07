@testitem "static_ownership_suggestions flags a Type-keyed IdDict get! (GKH anti-pattern)" begin
    using StrictMode

    struct SOWorkspace{T} end
    const _SO_WS = IdDict{Type, Any}()
    _so_ws(::Type{T}) where {T} = get!(() -> SOWorkspace{T}(), _SO_WS, T)

    fs = static_ownership_suggestions(_so_ws, (Type{Float64},))
    @test !isempty(fs)
    f = only(fs)
    @test f.guarantee === :static_ownership
    @test f.status === :info
    @test nfailures(fs) == 0                          # informational, never a failure
    @test occursin("get!", f.reason)
    @test occursin("const", f.suggestion)
end

@testitem "static_ownership_suggestions flags a lookup reached via a non-inlined callee (interprocedural)" begin
    using StrictMode
    # The PureBLAS `_symm_scr` shape (also @assert_owned's motivating case): the driver's own body
    # is clean, the Type-keyed IdDict lookup lives one level down in a @noinline accessor, and the
    # accessor's `get(...)` itself fully inlines to a `jl_eqtable_get` ccall — no `getindex`/`get`
    # call survives at ANY level for a direct method-name match.
    const _SO_ITP = IdDict{DataType, Vector{Float64}}()
    @noinline _so_scr(::Type{T}) where {T} = get(_SO_ITP, T, Float64[])::Vector{Float64}
    _so_driver(::Type{T}) where {T} = length(_so_scr(T))

    fs = static_ownership_suggestions(_so_driver, (Type{Float64},))
    @test !isempty(fs)
    @test only(fs).status === :info
    @test occursin("interprocedural", only(fs).reason)
end

@testitem "static_ownership_suggestions does not flag a value-keyed IdDict via interprocedural scan" begin
    using StrictMode
    # The interprocedural eqtable rule is deliberately IdDict-shaped (a known, documented
    # precision/recall tradeoff — see the comment in static_ownership.jl), but a plain (non-IdDict)
    # value-keyed Dict reached through a callee must still not be flagged: check_compiled and the
    # direct rule (`_mi_typekey_dict_lookup`) require a Type/Symbol key, so a hash-Dict-based
    # config-style lookup one level down stays clean.
    const _SO_ITP_STR = Dict{String, Int}("a" => 1)
    @noinline _so_cfg(s::String) = get(_SO_ITP_STR, s, 0)
    _so_cfg_driver(s::String) = _so_cfg(s)

    @test isempty(static_ownership_suggestions(_so_cfg_driver, (String,)))
end

@testitem "static_ownership_suggestions flags a Type-keyed Dict getindex" begin
    using StrictMode

    const _SO_WS2 = Dict{Type, Any}(Float64 => 1.0)
    _so_get(::Type{T}) where {T} = _SO_WS2[T]

    fs = static_ownership_suggestions(_so_get, (Type{Float64},))
    @test !isempty(fs)
    @test only(fs).status === :info
end

@testitem "static_ownership_suggestions flags a Symbol-keyed Dict lookup" begin
    using StrictMode

    const _SO_SYM = Dict{Symbol, Int}(:a => 1)
    _so_sym(s::Symbol) = _SO_SYM[s]

    fs = static_ownership_suggestions(_so_sym, (Symbol,))
    @test !isempty(fs)
    @test only(fs).guarantee === :static_ownership
end

@testitem "static_ownership_suggestions: the dispatch (GKH) form produces no finding" begin
    using StrictMode

    struct SOL3{T} end
    const _SO_L3_F64 = SOL3{Float64}()
    const _SO_L3_F32 = SOL3{Float32}()
    _so_l3(::Type{Float64}) = _SO_L3_F64
    _so_l3(::Type{Float32}) = _SO_L3_F32

    @test isempty(static_ownership_suggestions(_so_l3, (Type{Float64},)))
end

@testitem "static_ownership_suggestions: a value-keyed (String) dict is not flagged" begin
    using StrictMode

    const _SO_STR = Dict{String, Int}("x" => 1)
    _so_str(s::String) = _SO_STR[s]

    @test isempty(static_ownership_suggestions(_so_str, (String,)))
end

@testitem "static_ownership_suggestions works in :fast mode (no backend needed)" begin
    using StrictMode

    struct SOFastWs{T} end
    const _SO_FAST_WS = IdDict{Type, Any}()
    _so_fast(::Type{T}) where {T} = get!(() -> SOFastWs{T}(), _SO_FAST_WS, T)

    # No `mode` kwarg exists on static_ownership_suggestions — it's Base-inference-only by
    # construction, so it needs no AllocCheck/JET backend and behaves identically regardless of
    # analysis_mode().
    fs = static_ownership_suggestions(_so_fast, (Type{Float64},))
    @test !isempty(fs)
end

@testitem "audit(Module; static_ownership_suggest=true) surfaces suggestions without failing" begin
    using StrictMode

    # The GKH shape end-to-end: two `::Type{T}`-dispatched hot-path methods (clean) plus a Dict
    # fallback for the rare-type tail (flagged, but advisory — never fails nfailures). Depends on
    # `check_compiled`'s sweep recognizing a `::Type{T}` argument as a valid dispatch tuple (F37);
    # `isconcretetype(Type{Float64}) == false` used to make every such method invisible here.
    module StaticOwnershipDemo
        struct Ws{T} end
        const WS_F64 = Ws{Float64}()
        const WS_F32 = Ws{Float32}()
        const WS_FALLBACK = IdDict{Type, Any}()
        get_ws(::Type{Float64}) = WS_F64
        get_ws(::Type{Float32}) = WS_F32
        get_ws(::Type{T}) where {T} = get!(() -> Ws{T}(), WS_FALLBACK, T)
    end

    StaticOwnershipDemo.get_ws(Float64)                # hot path: dispatch, no lookup
    StaticOwnershipDemo.get_ws(BigFloat)                # rare path: sanctioned Dict fallback

    fs = audit(StaticOwnershipDemo; static_ownership_suggest = true, format = :text, io = devnull)
    @test count(x -> x.guarantee === :static_ownership, fs) == 1   # only the fallback, not the dispatch methods
    @test any(x -> x.guarantee === :static_ownership && x.status === :info && occursin("BigFloat", x.signature), fs)
    @test nfailures(fs) == 0                          # info findings never fail the audit
end

@testitem "static_ownership :info findings render distinctly per sink" begin
    using StrictMode

    struct SORenderWs{T} end
    const _SO_RENDER_WS = IdDict{Type, Any}()
    _so_render(::Type{T}) where {T} = get!(() -> SORenderWs{T}(), _SO_RENDER_WS, T)

    fs = static_ownership_suggestions(_so_render, (Type{Float64},))
    @test !isempty(fs)

    txt = format_findings(fs; format = :text)
    @test occursin("static_ownership", txt)

    gh = format_findings(fs; format = :github)
    @test occursin("::notice", gh)
    @test !occursin("::error", gh)

    js = format_findings(fs; format = :json)
    @test occursin("\"status\":\"info\"", js)
end
