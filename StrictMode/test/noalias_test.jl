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
    # Measured in a function, where the argument types are known. At a call site whose arguments
    # infer to `Any` — a non-`const` global — the argument tuple is heap-allocated by the call
    # itself, before this check sees it, and no check written here can avoid that.
    function cost()
        a = zeros(64)
        b = ones(64)
        bare() = copyto!(a, b)
        checked() = @assert_noalias copyto!(a, b)
        bare(); checked()                                 # warm both specializations
        return (@allocated(bare()), @allocated(checked()))
    end
    cost()
    bare_bytes, checked_bytes = cost()
    @test checked_bytes == bare_bytes
    @test iszero(checked_bytes)
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
