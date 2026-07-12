@testitem "@assert_typestable passes on a type-stable call and returns its value" begin
    using StrictMode
    affine(x) = 2x + 1
    @test (@assert_typestable affine(3.0)) === 7.0
end

@testitem "@assert_typestable fails on runtime tuple indexing (boxing class)" begin
    using StrictMode
    # The canonical trap: indexing a heterogeneous tuple with a runtime value yields a Union
    # return type and silently boxes — measured a 135x slowdown in the FFT work.
    heterogeneous = (1, 2.0, "three")
    pick(tup, i) = tup[i]
    @test_throws StrictViolation @assert_typestable pick(heterogeneous, rand(1:3))
end

@testitem "_typestable_fast (the :fast-mode check) passes/fails correctly" begin
    using StrictMode
    stable(x) = 2x + 1
    @test StrictMode._typestable_fast("t", stable, (Float64,)) === nothing   # concrete return

    heterogeneous = (1, 2.0, "three")
    pick(tup, i) = tup[i]
    @test_throws StrictViolation StrictMode._typestable_fast("t", pick, (typeof(heterogeneous), Int))
end

@testitem "_typestable_fast also catches internal dynamic dispatch behind a concrete return (F38)" begin
    using StrictMode
    # A concrete return can hide runtime dispatch: `c.f` is `::Function` (abstract), so `c.f(1)`
    # dynamically dispatches even though the `::Int` annotation makes the overall return concrete.
    # findings(...; mode=:fast) already caught this via the IR boxing signal (check.jl's
    # _findings_fast); _typestable_fast (the macro's :fast path) had been missing it.
    struct CB38
        f::Function
    end
    callit(c::CB38) = (c.f(1))::Int
    @test_throws StrictViolation StrictMode._typestable_fast("callit", callit, (CB38,))

    # A genuinely stable call with no internal dispatch still passes.
    stable(x) = 2x + 1
    @test StrictMode._typestable_fast("stable", stable, (Float64,)) === nothing
end

@testitem "typestable is this-level (depth-0): a resolved :invoke to a boxy helper is not the caller's instability" begin
    using StrictMode
    # Regression for the 0.3.6 :fast false positive on PureBLAS complex herk!/_cpotrf_lower!. Those call
    # the complex `_l3ws` workspace accessor, a `get!` on an abstract-valued IdDict that boxes internally
    # but whose result is narrowed by a `::L3Workspace{T}` assert. The caller has NO dispatch of its own
    # (only a resolved :invoke), so it is type-stable — JET's :full opt-analysis agrees. The typestable
    # boxing signal must therefore be THIS-LEVEL (depth-0), not the full-depth noalloc/noboxing signal.
    const _BOXD = IdDict{Symbol, Any}()
    boxy_helper() = get!(() -> Int[], _BOXD, :k)::Vector{Int}   # boxes internally; result narrowed
    stable_caller() = length(boxy_helper())::Int                # only a resolved :invoke to the helper
    @test StrictMode._typestable_fast("stable_caller", stable_caller, ()) === nothing        # :fast passes
    @test all(f -> f.status === :pass, check(stable_caller, (); guarantees = (:typestable,), fail = :none))
    # ...but the helper DOES box at runtime, so the full-depth guarantees still catch it.
    @test any(f -> f.status === :fail, check(stable_caller, (); guarantees = (:noboxing,), fail = :none))
    # And a DIRECT dynamic dispatch (F38's shape) is still caught at this level.
    struct _CB; f::Function; end
    callit(c::_CB) = (c.f(1))::Int
    @test_throws StrictViolation StrictMode._typestable_fast("callit", callit, (_CB,))
end

@testitem "@assert_typestable accepts keyword arguments (issue #4)" begin
    using StrictMode
    scaled(x; scale = 2) = x .* scale
    @test (@assert_typestable scaled([1.0, 2.0]; scale = 3)) == [3.0, 6.0]
end

@testitem "@assert_typestable fails on an unstable keyword-argument call (issue #4)" begin
    using StrictMode
    heterogeneous = (1, 2.0, "three")
    pickkw(tup; i = 1) = tup[i]
    @test_throws StrictViolation @assert_typestable pickkw(heterogeneous; i = rand(1:3))
end

@testitem "@assert_typestable types= override pins the inference signature (issue #5)" begin
    using StrictMode
    g(::Type{T}) where {T} = Vector{T}(undef, 1)
    # typeof(Float64) === DataType widens the inferred return to non-concrete → false positive.
    @test_throws StrictViolation @assert_typestable g(Float64)
    # Pinning Type{Float64} restores concreteness.
    @test (@assert_typestable g(Float64) types = (Type{Float64},)) isa Vector{Float64}
end

@testitem "analysis_mode defaults to :full in the test environment" begin
    using StrictMode
    @test analysis_mode() === :full
end
