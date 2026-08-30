@testitem "@assert_owned fails on a runtime IdDict scratch lookup (GKH-ownership violation)" begin
    using StrictMode
    # A workspace accessor that falls through to a runtime keyed lookup for the type — the exact
    # PureBLAS `_symm_scr` shape: type-stable, non-allocating on the warm hit, so @assert_noalloc /
    # @assert_noboxing / @assert_typestable all PASS. The dict probe lives in a NON-INLINED callee,
    # so this exercises the interprocedural walk.
    const _SCRATCH = IdDict{DataType, Vector{Float64}}()
    @noinline _scr(::Type{T}) where {T} = get(_SCRATCH, T, Float64[])::Vector{Float64}
    usescr(::Type{T}) where {T} = length(_scr(T))
    @test_throws StrictViolation (@assert_owned usescr(Float64) types = (Type{Float64},))
end

@testitem "@assert_owned passes on a const-dispatched owned accessor (Ref-per-type)" begin
    using StrictMode
    const _SCR64 = Ref(Vector{Float64}(undef, 8))
    @noinline _scr(::Type{Float64}) = _SCR64[]          # owned, resolved at compile time — no dict
    usescr(::Type{T}) where {T} = length(_scr(T))
    @test (@assert_owned usescr(Float64) types = (Type{Float64},)) == 8
end

@testitem "@assert_owned honors StrictMode._FAST_ALLOC_DEPTH[] as its default depth (F38)" begin
    using StrictMode
    # @assert_owned's default depth was hardcoded to 2 (in the macro, `_assert_owned`, and both
    # `check.jl` :owned branches) instead of reading the session-wide `_FAST_ALLOC_DEPTH[]` override
    # that @assert_noalloc and the batch API already honor — a lookup 3+ non-inlined levels deep was
    # invisible to @assert_owned's default even after raising the Ref for the rest of the codebase.
    const _WS = IdDict{DataType, Vector{Float64}}()
    @noinline _l3(::Type{T}) where {T} = get(_WS, T, Float64[])::Vector{Float64}
    @noinline _l2(::Type{T}) where {T} = _l3(T)
    @noinline _l1(::Type{T}) where {T} = _l2(T)
    usescr(::Type{T}) where {T} = length(_l1(T))

    @test !StrictMode._alloc_signals(usescr, (Type{Float64},); depth = StrictMode._FAST_ALLOC_DEPTH[]).dictlookup

    old = StrictMode._FAST_ALLOC_DEPTH[]
    StrictMode._FAST_ALLOC_DEPTH[] = 3
    try
        @test_throws StrictViolation (@assert_owned usescr(Float64) types = (Type{Float64},))
    finally
        StrictMode._FAST_ALLOC_DEPTH[] = old
    end
end

@testitem "@assert_owned fails on delete!/getkey, not just get/getindex (F38)" begin
    using StrictMode
    # _DICT_ACCESSORS previously omitted delete!/getkey (only pop! was listed alongside get/getindex/
    # get!/setindex!/haskey) despite them being equally real runtime keyed-lookup ownership violations.
    const _WS1 = Dict{Symbol, Int}(:a => 1)
    rundel(x::Int) = (delete!(_WS1, :a); x)
    @test_throws StrictViolation (@assert_owned rundel(1))

    const _WS2 = Dict{Symbol, Int}(:a => 1)
    rungk(x::Int) = (getkey(_WS2, :a, :missing); x)
    @test_throws StrictViolation (@assert_owned rungk(1))
end
