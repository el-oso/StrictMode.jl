# F39: a non-isbits union phi boxes even when the union fully splits. The box leaves no `:new` and
# no allocating `foreigncall` in optimized IR — its only trace is the phi's own type — so every
# other rule here is blind to it, and so is JET, because union splitting is not dynamic dispatch.

@testmodule UnionPhi begin
    # The shape from PureBLAS `_trsm_right!`: one local assigned more than one type, so the slot
    # becomes union-typed. Which members it holds decides whether flowing through it costs anything.
    @noinline function through_union(A::AbstractMatrix{Float64}, take::Bool)
        # `Matrix` and `SubArray` are both members; only the immutable `SubArray` boxes on entry.
        local x = take ? view(A, :, 1:1) : A
        s = 0.0
        for i in eachindex(x)
            s += @inbounds x[i]
        end
        return s
    end

    # Benign control: every member is mutable, so each is already a pointer and none boxes.
    @noinline function mutable_members(A::Matrix{Float64}, B::Vector{Float64}, take::Bool)
        local x = take ? A : B
        s = 0.0
        for i in eachindex(x)
            s += @inbounds x[i]
        end
        return s
    end

    # Benign control: an isbits union rides the inline payload.
    @noinline function isbits_members(a::Float64, take::Bool)
        local x = take ? a : 1
        return Float64(x) + 1.0
    end
end

@testitem "F39: a boxing union phi is flagged, and rides on :typestable not :noalloc" setup = [UnionPhi] begin
    using StrictMode

    A = rand(4, 4)
    V = rand(4)
    UnionPhi.through_union(A, true)
    UnionPhi.mutable_members(A, V, true)
    UnionPhi.isbits_members(1.0, true)

    sig = StrictMode._alloc_signals(UnionPhi.through_union, (Matrix{Float64}, Bool); depth = 0)
    @test sig.unionphi

    # The two benign shapes must NOT fire: member count is not the discriminator, representation is.
    @test !StrictMode._alloc_signals(UnionPhi.mutable_members, (Matrix{Float64}, Vector{Float64}, Bool); depth = 0).unionphi
    @test !StrictMode._alloc_signals(UnionPhi.isbits_members, (Float64, Bool); depth = 0).unionphi

    # The representation test itself, on the types F39 names.
    @test StrictMode._box_on_entry(SubArray{Float64, 2, Matrix{Float64}, Tuple{Base.Slice{Base.OneTo{Int}}, UnitRange{Int}}, true})
    @test !StrictMode._box_on_entry(Matrix{Float64})      # mutable — already a pointer
    @test !StrictMode._box_on_entry(Int)                  # isbits — rides unboxed
    @test StrictMode._box_on_entry(Union{Int, Matrix})    # not a concrete DataType — assume it boxes

    # It reaches `:typestable`, whose return-type layer cannot see it: the return IS concrete.
    @test only(Base.return_types(UnionPhi.through_union, Tuple{Matrix{Float64}, Bool})) === Float64
    f = only(findings(UnionPhi.through_union, (Matrix{Float64}, Bool); guarantees = (:typestable,)))
    @test StrictMode._failed(f)
    @test occursin("union-typed local", f.reason)

    # And it must NOT reach `:noalloc`: LLVM elides the box at the signature whose member is
    # already a pointer, so folding this into an allocation verdict would red a provably-0 B
    # kernel — issue #17's failure mode.
    na = only(findings(UnionPhi.through_union, (Matrix{Float64}, Bool); guarantees = (:noalloc,)))
    @test !occursin("union-typed local", na.reason)
end

@testitem "F39: the signal is structural — it fires where nothing is allocated" setup = [UnionPhi] begin
    using StrictMode

    A = rand(4, 4)
    UnionPhi.through_union(A, true)
    UnionPhi.through_union(A, false)

    # Whether the box actually survives is LLVM's call, and it moves with inlining: this exact
    # fixture measures 16 B/call across a module boundary and 0 B once it inlines into its caller.
    # The signal does not move with it — it reports the local's TYPE, which is the same either way.
    # That is the whole reason it rides `:typestable`: "this local is union-typed with a
    # box-on-entry member" is a property of the code as written, while "it allocates" is not, and
    # folding this into `:noalloc` would red kernels LLVM made free — issue #17's exact failure.
    @test StrictMode._alloc_signals(UnionPhi.through_union, (Matrix{Float64}, Bool); depth = 0).unionphi

    # The consequence worth pinning: the union comes from branch structure rather than from the
    # argument types, so the verdict does not depend on anyone having thought to pass the argument
    # type that would actually box. F39's case allocated only through `SubArray`; this fires from a
    # plain `Matrix` signature.
    @test !StrictMode._box_on_entry(Matrix{Float64})
end
