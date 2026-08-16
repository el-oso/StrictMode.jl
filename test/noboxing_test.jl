@testitem "@assert_noboxing passes on a clean call and returns its value" begin
    using StrictMode
    dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    @test (@assert_noboxing dot3((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))) === 32.0
end

@testitem "@assert_noboxing fails on runtime tuple indexing (boxing)" begin
    using StrictMode
    heterogeneous = (1, 2.0, 3.0f0)
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    @test_throws StrictViolation @assert_noboxing boxy(heterogeneous)
end

@testitem "@assert_noboxing fails on dynamic dispatch" begin
    using StrictMode
    struct AnyBox
        x::Any
    end
    usebox(b) = b.x + 1
    @test_throws StrictViolation @assert_noboxing usebox(AnyBox(2))
end

@testitem "@assert_noboxing ALLOWS a legitimate buffer allocation (unlike @assert_noalloc)" begin
    using StrictMode
    # Allocates a Vector but never boxes — the whole reason @assert_noboxing exists.
    function fill_sum(n)
        v = Vector{Float64}(undef, n)
        for i in 1:n
            @inbounds v[i] = i
        end
        return sum(v)
    end
    @test_throws StrictViolation @assert_noalloc fill_sum(3)   # it does allocate
    @test (@assert_noboxing fill_sum(3)) == 6.0               # …but it does not box
end

@testitem "abstract-eltype container is detected as a boxing anti-pattern (F34)" begin
    using StrictMode
    abstract type _Foo end
    struct _A <: _Foo
        x::Int
    end
    struct _B <: _Foo
        y::Float64
    end
    _val(a::_A) = a.x
    _val(b::_B) = round(Int, b.y)
    function bad(n)                       # the autoplan anti-pattern in miniature
        v = _Foo[]                        # Vector{_Foo} — abstract eltype, grown with push!
        push!(v, _A(n)); push!(v, _B(2.0))
        s = 0
        for f in v                        # dispatch over abstract elements — note _val returns concrete Int
            s += _val(f)
        end
        return s
    end
    function good(n)                      # the fix: a Tuple keeps each element's concrete type
        v = (_A(n), _B(2.0))
        s = 0
        for f in v
            s += _val(f)
        end
        return s
    end
    sb = StrictMode._alloc_signals(bad, (Int,))
    sg = StrictMode._alloc_signals(good, (Int,))
    # Detected from the IR's container type directly — even though `_val` returns a concrete `Int`, which
    # the result-type boxing heuristic would miss:
    @test sb.abscontainer === _Foo
    @test sg.abscontainer === nothing
    # …and the finding message names the root cause + the fix:
    msg = StrictMode._box_msg("boxing (fast heuristic)", sb)
    @test occursin("abstract-eltype container", msg)
    @test occursin("Tuple", msg)
    @test StrictMode._box_msg("boxing (fast heuristic)", sg) == "boxing (fast heuristic)"   # no enrichment when clean
end

@testitem "warm dict lookup: :fast is RIGHT and AllocCheck is conservative (measured)" begin
    using StrictMode, StrictModeTest
    # The PureBLAS `_l3ws` / GKH-ownership shape. Ground truth first: warm, this allocates NOTHING.
    # `Any` only boxes an *isbits* value on STORE; reading is always free, and storing a heap object
    # (the workspace itself) is free too. AllocCheck's all-paths proof still reports boxing here —
    # it has to assume the `Any` slot could hold an isbits value and that the cold-miss branch runs.
    # So on this shape `:fast` gives the correct verdict and `:full` is the conservative one. This
    # is the direction that matters after the tier split, so it is pinned rather than left implicit.
    const _L3 = IdDict{Symbol, Any}()
    helper() = get!(() -> Int[], _L3, :k)::Vector{Int}
    caller() = length(helper())::Int
    caller()
    for _ in 1:5
        caller()
    end
    @test @allocated(caller()) == 0                                                   # ground truth
    @test all(f -> f.status === :pass, findings(caller, (); guarantees = (:noboxing,), mode = :fast))
    @test any(f -> f.status === :fail, findings(caller, (); guarantees = (:noboxing,), mode = :full))
end

@testitem "an UNNARROWED Any-returning lookup correctly fails all three" begin
    using StrictMode
    # The counterpart: `docs/src/guarantees.md`'s own `unit` example returns `Any` unnarrowed, so it
    # is genuinely unstable and every guarantee fails on the return type alone — even though it too
    # is 0-alloc warm. Narrowing is what separates this from the item above; the doc used to claim
    # all three passed on it.
    const _U = IdDict{Type, Any}(Int => 1, Float64 => 1.0)
    unit(::Type{T}) where {T} = _U[T]
    unit(Float64)
    @test_throws StrictViolation @assert_typestable unit(Float64)
    @test_throws StrictViolation @assert_noboxing unit(Float64)
end

@testitem "the tier is the dependency graph: guarantees escalate when StrictModeTest is loaded" begin
    using StrictMode, StrictModeTest
    # This is what makes the two-package split work without a preference: the engine is chosen at
    # CALL time, not at macro expansion, so ONE compiled call site runs the heuristic in a package's
    # own dev/precompile environment (StrictMode alone) and the AllocCheck/JET proof under test
    # (StrictModeTest present). Nothing is recompiled and no import line selects it.
    @test StrictMode.backend_available()
    @test StrictMode.trimcheck_available()
    # `:heuristic` is the "no explicit static=" default and is the thing that escalates...
    @test StrictMode._noalloc_mode(nothing) === :heuristic
    # ...while an explicit user decision is never overridden in either direction.
    @test StrictMode._noalloc_mode(true) === :static
    @test StrictMode._noalloc_mode(false) === :empirical
    # With the backend up, the default path is the proof: this boxes, and AllocCheck says so.
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    @test_throws StrictViolation @assert_noalloc boxy((1, 2.0, 3.0f0))
end
