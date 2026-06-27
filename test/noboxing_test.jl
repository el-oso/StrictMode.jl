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
