# Two ways to answer "is this definition type-stable?" for a declaration that names no concrete
# types: `signatures = [...]` answers at module load for instantiations you list, `@strict_stable`
# answers per specialization for the ones callers create.

@testitem "@strict_function signatures= checks instantiations the declaration cannot name" begin
    using StrictMode

    # The premise: a generic declaration infers to `Any`, so checking it directly would fail every
    # generic function. That is why the bare form skips it.
    pick_probe(t::Tuple, i::Int) = t[i]
    @test Base.isdispatchtuple(Tuple{Tuple, Int}) == false
    @test only(Base.return_types(pick_probe, Tuple{Tuple, Int})) === Any

    good = [(NTuple{3, Float64}, Int)]
    @strict_function signatures = good listed_ok(t::Tuple, i::Int) = t[i]
    @test listed_ok((1.0, 2.0, 3.0), 2) === 2.0

    # A listed instantiation that is genuinely unstable fails where the definition is evaluated.
    bad = [(Tuple{Float64, String}, Int)]
    @test_throws StrictViolation @eval @strict_function signatures = $bad listed_bad(t::Tuple, i::Int) = t[i]

    # Supplying `signatures` answers the abstract-declaration question, so it must not also warn
    # about the declaration being abstract.
    @test_logs min_level = Base.CoreLogging.Warn @eval @strict_function signatures = $good quiet_pick(t::Tuple, i::Int) = t[i]
end

@testitem "@strict_stable checks every specialization and elides when stable" begin
    using StrictMode

    @strict_stable st_pick(t::Tuple, i::Int) = t[i]
    @test st_pick((1.0, 2.0, 3.0), 2) === 2.0
    # A 3-way isbits union is tolerated, matching `_is_typestable_return` everywhere else.
    @test st_pick((1, 2.0, 3.0f0), 2) === 2.0
    # A union carrying a heap type is not.
    @test_throws StrictViolation st_pick((1.0, "a"), 2)

    # The bare declaration is what `@strict_function` cannot check at all, which is the point.
    @test Base.isdispatchtuple(Tuple{Tuple, Int}) == false

    # Elision: a stable specialization must leave no branch behind. Compare against the same body
    # with no annotation — equal instruction counts, and no throw.
    plain_dot(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    @strict_stable st_dot(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    tt = (NTuple{3, Float64}, NTuple{3, Float64})
    ir = StrictMode._llvm_ir(st_dot, tt)
    plain_ir = StrictMode._llvm_ir(plain_dot, tt)
    @test !occursin("jl_throw", ir)
    @test !occursin("StrictViolation", ir)
    # Equal instruction counts only mean anything without coverage instrumentation, which emits a
    # counter per FUNCTION — and this macro defines two, the wrapper and its hidden inner, so the
    # wrapper carries one extra line under `Pkg.test(; coverage = true)`. The elision itself is
    # unaffected, which is what the two assertions above pin.
    if iszero(Base.JLOptions().code_coverage)
        @test count(==('\n'), ir) == count(==('\n'), plain_ir)
    else
        @test_skip count(==('\n'), ir) == count(==('\n'), plain_ir)
    end
end

@testitem "@strict_stable rejects what it cannot check, rather than passing silently" begin
    using StrictMode
    @test_throws LoadError @eval @strict_stable kw_fn(x::Int; y::Int = 1) = x + y
    @test_throws LoadError @eval @strict_stable va_fn(x::Int, rest...) = x
end

@testitem "the hidden inner body demangles to its public name" begin
    using StrictMode
    # `only`/`exempt` match on the demangled name, so the wrapper's inner must not read as a
    # separate function to a module sweep.
    @test StrictMode._demangle(Symbol("#foo#inner")) === :foo
    @test StrictMode._demangle(Symbol("#foo#12")) === :foo      # kwsorter mangling still works
    @test StrictMode._demangle(:foo) === :foo
end
