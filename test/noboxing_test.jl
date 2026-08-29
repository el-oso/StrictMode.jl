@testitem "@assert_noboxing passes on a clean call and returns its value" begin
    using StrictMode
    dot3(a, b) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    @test (@assert_noboxing dot3((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))) === 32.0
end

@testitem "the noboxing macros flag runtime tuple indexing (boxing)" begin
    using StrictMode, StrictModeTest
    heterogeneous = (1, 2.0, 3.0f0)
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    @test_logs (:warn,) match_mode = :any (@assert_noboxing boxy(heterogeneous))
    @test_throws StrictViolation @test_noboxing boxy(heterogeneous)
end

@testitem "the noboxing proof flags dynamic dispatch" begin
    using StrictMode, StrictModeTest
    struct AnyBox
        x::Any
    end
    usebox(b) = b.x + 1
    @test_throws StrictViolation @test_noboxing usebox(AnyBox(2))
end

@testitem "noboxing ALLOWS a legitimate buffer allocation (unlike noalloc)" begin
    using StrictMode, StrictModeTest
    # Allocates a Vector but never boxes — the whole reason @assert_noboxing exists.
    function fill_sum(n)
        v = Vector{Float64}(undef, n)
        for i in 1:n
            @inbounds v[i] = i
        end
        return sum(v)
    end
    @test_throws StrictViolation @test_noalloc fill_sum(3)   # it does allocate
    @test (@test_noboxing fill_sum(3)) == 6.0                # …but it does not box
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
    msg = StrictMode._box_msg("boxing (IR scan)", sb)
    @test occursin("abstract-eltype container", msg)
    @test occursin("Tuple", msg)
    @test StrictMode._box_msg("boxing (IR scan)", sg) == "boxing (IR scan)"   # no enrichment when clean
end

@testitem "the two engines answer DIFFERENT questions on a memoized accessor" begin
    using StrictMode, StrictModeTest
    # The PureBLAS `_l3ws` / GKH-ownership shape, and a correction: an earlier version of this item
    # claimed `:fast` was RIGHT here and AllocCheck merely conservative. That was a category error.
    # It measured `@allocated` WARM — steady state — and then credited whichever engine agreed with
    # it. AllocCheck does not answer that question. It proves "cannot allocate on ANY path", and
    # this accessor genuinely allocates on its first call: measured 64 B cold, 0 B warm for the
    # equivalent `get_ws` shape. Flagging it is correct for the question AllocCheck is asked.
    #
    # So there are three different questions in play, and they must not be conflated:
    #   `@allocated` warm  — does the steady state allocate?
    #   AllocCheck         — can ANY path allocate?
    #   the fast heuristic — does the typed IR contain an allocation site? (a guess at AllocCheck's
    #                        question, made without LLVM, so it cannot see what LLVM elides)
    #
    # What this pins is the DIVERGENCE, not a winner: on a narrowed dict read the heuristic passes
    # `:noboxing` and the proof fails it. That matters because after the tier split `:fast` is the
    # only engine most consumers get, so the disagreement is user-visible and should not drift
    # silently.
    const _L3 = IdDict{Symbol, Any}()
    helper() = get!(() -> Int[], _L3, :k)::Vector{Int}
    caller() = length(helper())::Int
    caller()
    for _ in 1:5
        caller()
    end
    @test @allocated(caller()) == 0                          # steady state: nothing
    @test all(f -> f.status === :pass, findings(caller, (); guarantees = (:noboxing,)))
    @test any(f -> f.status === :fail, proof_findings(caller, (); guarantees = (:noboxing,)))
end

@testitem ":noboxing permits a typed allocation — the heuristic over-flags one, the proof does not" begin
    using StrictMode, StrictModeTest
    # The other half of the correction, and the direction that actually matters: here the HEURISTIC
    # is wrong. `bad` allocates a `Vector{_Foo}` (96 B measured) and dispatches over its abstract
    # elements. That vector is a legitimate TYPED heap allocation, which `:noboxing` explicitly
    # permits — so AllocCheck passing is correct. The heuristic fails it because it treats an
    # abstract-eltype container as boxing, which is a code smell, not a boxing proof.
    #
    # Together with issue #17 (19/68 false failures on PureIPM, every one measuring 0 B), this is
    # the honest summary: there is no measured case where the heuristic beats AllocCheck. Its one
    # advantage is needing no backend, which is exactly why it is the tier that ships without one.
    abstract type _Foo end
    struct _A <: _Foo
        x::Int
    end
    struct _B <: _Foo
        y::Float64
    end
    _val(a::_A) = a.x
    _val(b::_B) = round(Int, b.y)
    function bad(n)
        v = _Foo[]
        push!(v, _A(n))
        push!(v, _B(2.0))
        s = 0
        for f in v
            s += _val(f)
        end
        return s
    end
    bad(1)
    @test @allocated(bad(1)) > 0                             # it really does allocate...
    @test all(f -> f.status === :pass, proof_findings(bad, (Int,); guarantees = (:noboxing,)))
    @test any(StrictMode._failed, findings(bad, (Int,); guarantees = (:noboxing,)))
    # ...and :noalloc, which asks the broader question, agrees across both engines.
    @test any(StrictMode._failed, findings(bad, (Int,); guarantees = (:noalloc,)))
    @test any(f -> f.status === :fail, proof_findings(bad, (Int,); guarantees = (:noalloc,)))
end

@testitem "an UNNARROWED Any-returning lookup correctly fails all three" begin
    using StrictMode, StrictModeTest
    # The counterpart: `docs/src/guarantees.md`'s own `unit` example returns `Any` unnarrowed, so it
    # is genuinely unstable and every guarantee fails on the return type alone — even though it too
    # is 0-alloc warm. Narrowing is what separates this from the item above; the doc used to claim
    # all three passed on it.
    const _U = IdDict{Type, Any}(Int => 1, Float64 => 1.0)
    unit(::Type{T}) where {T} = _U[T]
    unit(Float64)
    @test_throws StrictViolation @assert_typestable unit(Float64)
    @test_throws StrictViolation @test_noboxing unit(Float64)
end

@testitem "the tier is the macro you wrote, not ambient state" begin
    using StrictMode, StrictModeTest
    # What makes the two-package split work without a preference: `@assert_noboxing` IS the
    # value-free scan and `@test_noboxing` IS the proof, decided at macro expansion by the name.
    # Nothing reads a flag at call time, so there is no state that can silently pick the other one.
    boxy(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    tup = (1, 2.0, 3.0f0)
    @test_logs (:warn,) match_mode = :any (@assert_noboxing boxy(tup))
    @test_throws StrictViolation @test_noboxing boxy(tup)

    # The scan is still the only engine `@assert_noalloc` has, even with the proofs loaded…
    @test StrictMode._noalloc_mode(nothing) === :heuristic
    @test StrictMode._noalloc_mode(false) === :empirical
    # …and asking it for the proof is refused, not silently downgraded.
    @test StrictMode._noalloc_mode(true) === :static
    @test_throws ArgumentError StrictMode._assert_noalloc("boxy", boxy, (typeof(tup),), () -> boxy(tup); mode = :static)
end
