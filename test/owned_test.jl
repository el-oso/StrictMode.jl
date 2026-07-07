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
