# F39 (StrictMode issue #27): the proof must not be weaker than the scan. JET cannot see a
# union-typed local that boxes a member on the way in — union splitting is not dynamic dispatch —
# so `@test_typestable` has to consult the scan's `unionphi` signal or it waves through exactly the
# class `@assert_typestable` catches.

@testitem "issue #27: @test_typestable catches the union-phi box JET is blind to" begin
    using StrictMode, StrictModeTest
    @noinline function boxing_union_local(A::AbstractMatrix{Float64}, take::Bool)
        local x = take ? view(A, :, 1:1) : A
        s = 0.0
        for i in eachindex(x)
            s += @inbounds x[i]
        end
        return s
    end
    A = rand(4, 4)
    boxing_union_local(A, true)
    tt = (Matrix{Float64}, Bool)

    # The proof's other two layers both pass on this signature, which is what makes the class
    # invisible to them: the return type is concrete and JET reports nothing.
    @test only(Base.return_types(boxing_union_local, Tuple{tt...})) === Float64
    @test isempty(StrictModeTest._opt_reports("probe", boxing_union_local, tt))

    # The scan sees it, and so must the proof.
    @test StrictMode._alloc_signals(boxing_union_local, tt; depth = 0).unionphi
    f = only(proof_findings(boxing_union_local, tt; guarantees = (:typestable,)))
    @test StrictMode._failed(f)
    @test occursin("union-typed local", f.reason)
end
