@testitem "@assert_noalias passes distinct arguments and returns the call's value" begin
    using StrictMode

    # Writes argument 1, reads arguments 2 and 3 — the shape of every three-argument kernel whose
    # destination must stay separate from its inputs.
    add2!(dest, a, b) = (dest .= a .+ b; dest)

    a = [1.0, 2.0]
    out = zeros(2)
    val = @assert_noalias add2!(out, a, a)     # a may alias itself: only `out` is written
    @test val === out
    @test out == [2.0, 4.0]                    # the real call ran, on the real arguments
end

@testitem "@assert_noalias rejects a destination that is also an input" begin
    using StrictMode

    add2!(dest, a, b) = (dest .= a .+ b; dest)
    a = [1.0, 2.0]
    out = zeros(2)

    @test_throws StrictMode.StrictViolation @assert_noalias add2!(a, a, a)
    @test_throws "share memory" @assert_noalias add2!(a, a, a)
    @test_throws "argument 1 (written) and argument 2" @assert_noalias add2!(out, out, a)

    # A view of the destination reads what the call writes, which is the same defect wearing a
    # wrapper — the oracle resolves it to the memory underneath rather than comparing wrapper types.
    @test_throws StrictMode.StrictViolation @assert_noalias add2!(out, a, view(out, 1:2))
    @test_throws StrictMode.StrictViolation @assert_noalias add2!(out, a, reshape(out, 2, 1))
end

@testitem "@assert_noalias accepts disjoint slices of one buffer" begin
    using StrictMode

    # The pattern this check must NOT red: one workspace, carved into tiles that never overlap. A
    # predicate that compared only the parent would reject every blocked kernel that shares scratch.
    ws = zeros(8)
    dst = view(ws, 1:4)
    src = view(ws, 5:8)
    src .= 1.0
    @test (@assert_noalias copyto!(dst, src)) == ones(4)

    # Interleaved strides touch no common element either, and a column pair of one matrix does not.
    M = zeros(4, 4)
    @test (@assert_noalias copyto!(view(M, 1, 1:2:3), view(M, 1, 2:2:4))) == zeros(2)
    @test (@assert_noalias copyto!(view(M, :, 1), view(M, :, 2))) == zeros(4)

    # …but a row and a column of the same matrix share one element, and that is still an overlap.
    @test_throws StrictMode.StrictViolation @assert_noalias copyto!(view(M, 1, :), view(M, :, 1))
end

@testitem "@assert_noalias takes its written positions from the name, or from mutates=" begin
    using StrictMode

    swap2!(a, b) = (a[1], b[1]) = (b[1], a[1])
    pick(a, b) = a .+ b
    x = [1.0]; y = [2.0]

    # A `!` name claims argument 1 and nothing else, so a second written position must be named.
    @test (@assert_noalias mutates = (1, 2) swap2!(x, y)) == (2.0, 1.0)
    @test x == [2.0] && y == [1.0]                             # the real call ran
    @test_throws StrictMode.StrictViolation @assert_noalias mutates = (1, 2) swap2!(x, x)

    # A name without `!` makes no claim about what it writes. Passing it would compare no pair and
    # accept every call, so it is rejected — at expansion, before the call runs.
    @test_throws LoadError @eval @assert_noalias pick($x, $y)
    @test_throws "does not end in `!`" @eval @assert_noalias pick($x, $y)
    @test (@assert_noalias mutates = (1,) pick(x, y)) == [3.0]   # …named, so it is checked

    @test_throws "out of range" @assert_noalias mutates = (9,) swap2!(x, y)
    @test_throws "argument position" @assert_noalias mutates = (:first,) swap2!(x, y)

    # `mutates` names positional arguments, so a keyword call has nothing for it to name.
    @test_throws LoadError @eval @assert_noalias copyto!($x; dims = 1)
end

@testitem "@assert_noalias costs nothing on the path that satisfies it" begin
    using StrictMode

    # A check that allocates is paid at every execution of the call site, and lands in the caller's
    # body — so an assertion about allocation-freedom would destroy the property it asserts
    # (issue #29). The scan must return before building anything.
    #
    # Asked of the check itself, with StrictMode's own `:noalloc` scan rather than `@allocated`.
    # `@allocated` reads a process-wide counter, so a neighbor thread's bytes land in its answer
    # for a call that allocates none — measured, 4.8 MB for a `mul!` whose true figure is zero.
    # The scan reads this function's IR, so no other thread can move the verdict.
    # The arrays are arguments, so the analyzed signature is concrete. Closing over a non-`const`
    # global instead would have the call site box the argument tuple before the check sees it, and
    # the scan would report that correctly — it is the call site's cost, not the check's.
    check(x, y) = StrictMode._assert_noalias("t", copyto!, (x, y); mutates = (1,))
    fs = findings(check, (Vector{Float64}, Vector{Float64}); guarantees = (:noalloc, :noboxing))
    @test !isempty(fs)
    @test all(f -> f.status === :pass, fs)

    # `@test_noalloc` cannot state this property for any `@assert_*` in the package, which is why
    # it is not used here: every check funnels through `_fail`, and `_fail` may warn and return
    # instead of throwing, so its message-building path is not throw-only and an all-paths proof
    # must count it. `ignore_throw` is what discounts that path, and the scan above honors it.
    @test StrictMode.ignore_throw()
end

@testitem "@assert_noalias is a value-taking check, so no sweep can declare it" begin
    using StrictMode

    # Whether two arrays overlap is a property of the arrays, not of their types. The value-free
    # engine has no values, so `:noalias` must stay out of the guarantee registry: a declaration
    # naming it would be swept by `audit` and reported unevaluable for every signature.
    @test !(:noalias in StrictMode.guarantee_names())
    @test_throws ArgumentError StrictMode.register_strict!(copyto!, (Vector{Float64}, Vector{Float64}); guarantees = (:noalias,))

    # It still carries a diagnostic code, because a violation is reported to a human.
    @test StrictMode.explain(:SM0012) isa String
    @test occursin("shares memory", StrictMode.explain(:SM0012))
end

@testitem "@assert_noalias does not pass a pair it could not compare" begin
    using StrictMode, LinearAlgebra

    y = [1.0, 2.0, 3.0, 4.0]
    x = [4.0, 3.0, 2.0, 1.0]

    # The `!` default names argument 1. A scalar there holds no memory, so the default compares
    # nothing: the call is rejected until `mutates` names what is written.
    @test_throws ArgumentError @assert_noalias BLAS.axpy!(2.0, y, y)
    @test_throws "argument 1 is a `Float64`, which holds no memory to write" @assert_noalias BLAS.axpy!(2.0, y, y)
    @test_throws "mutates = (2,)" @assert_noalias BLAS.axpy!(2.0, y, y)
    scale_into!(a, src, dst) = (dst .= a .* src; dst)
    @test_throws "holds no memory to write" @assert_noalias scale_into!(2.0, x, y)
    @test_throws "share memory: argument 3 (written) and argument 2" @assert_noalias mutates = (3,) BLAS.axpy!(2.0, y, y)
    @test (@assert_noalias mutates = (3,) BLAS.axpy!(2.0, x, copy(y))) == [9.0, 8.0, 7.0, 6.0]
    # A named position that cannot be written is the same mistake, spelled out.
    @test_throws "mutates = 1, but argument 1 is a `Float64`" @assert_noalias mutates = (1,) scale_into!(2.0, x, y)
    # A function or a type in the first position is no better than a scalar.
    @test_throws "holds no memory to write" @assert_noalias map!(abs, y, y)
    @test (@assert_noalias mutates = (2,) map!(abs, copy(y), x)) == x

    # An array type with no `Base.dataids` method answers with its own identity, which never
    # matches the vector it wraps.
    struct Wrapped{T} <: AbstractVector{T}
        data::Vector{T}
    end
    Base.size(w::Wrapped) = size(w.data)
    Base.getindex(w::Wrapped, i::Int) = w.data[i]
    Base.setindex!(w::Wrapped, v, i::Int) = (w.data[i] = v)
    @test !Base.mightalias(Wrapped(y), y)
    @test_throws StrictMode.StrictViolation @assert_noalias copyto!(Wrapped(y), y)
    @test_throws "argument 1 (written) and argument 2" @assert_noalias copyto!(Wrapped(y), y)
    @test_throws StrictMode.StrictViolation @assert_noalias copyto!(y, Wrapped(y))
    @test (@assert_noalias copyto!(Wrapped(copy(y)), y)) isa Wrapped
    # A wrapper that declares its ids is taken at its word.
    struct Declared{T} <: AbstractVector{T}
        data::Vector{T}
    end
    Base.size(w::Declared) = size(w.data)
    Base.getindex(w::Declared, i::Int) = w.data[i]
    Base.setindex!(w::Declared, v, i::Int) = (w.data[i] = v)
    Base.dataids(w::Declared) = Base.dataids(w.data)
    @test_throws StrictMode.StrictViolation @assert_noalias copyto!(Declared(y), y)
    @test (@assert_noalias copyto!(Declared(copy(y)), y)) isa Declared

    # A buffer held in a field of an argument that is not an array is shared memory the kernel
    # may never read: reported, not raised.
    struct Workspace
        buf::Vector{Float64}
    end
    from_ws!(dst, ws) = (dst .= ws.buf; dst)
    from_fact!(F, dst) = (dst .= F.factors; dst)
    @test_logs (:warn, r"argument 1 \(written\) and argument 2 \(a buffer held in a field of argument 2, a `[^`]*Workspace`\)"s) match_mode = :any (@assert_noalias from_ws!(y, Workspace(y)))
    @test_logs (@assert_noalias from_ws!(y, Workspace(x)))
    # A factorization that is the first argument of a two-argument `ldiv!`: the written argument
    # is the second, and the pair compared is the same one.
    F = lu([4.0 1.0; 1.0 3.0])
    @test_logs (:warn, r"argument 2 \(written\) and argument 1 \(a buffer held in a field of argument 1"s) match_mode = :any (@assert_noalias mutates = (2,) from_fact!(F, F.factors))
    # The `!` default compares argument 1 with the rest, which finds the same shared buffer.
    @test_logs (:warn, r"argument 1 \(written\) and argument 2 \(a buffer held in a field of argument 1"s) match_mode = :any (@assert_noalias from_fact!(F, F.factors))
    @test_logs (@assert_noalias ldiv!(F, [1.0, 2.0]))

    # Disjoint views of one parent are still told apart, and distinct arrays still cost nothing.
    M = zeros(4, 4)
    @test (@assert_noalias copyto!(view(M, :, 1), view(M, :, 2))) == zeros(4)
    check(a, b) = StrictMode._assert_noalias("t", copyto!, (a, b); mutates = (1,))
    fs = findings(check, (Vector{Float64}, Vector{Float64}); guarantees = (:noalloc, :noboxing))
    @test all(f -> f.status === :pass, fs)
    vcheck(a, b) = StrictMode._assert_noalias("t", copyto!, (a, b); mutates = (1,))
    V = SubArray{Float64, 1, Matrix{Float64}, Tuple{Base.Slice{Base.OneTo{Int}}, Int}, true}
    @test all(f -> f.status === :pass, findings(vcheck, (V, V); guarantees = (:noalloc,)))
end
