@testitem "@strict_function loads a clean definition and it works" begin
    using StrictMode
    @strict_function square(x::Int) = x * x
    @test square(7) == 49
end

@testitem "@strict_function reports an allocating definition at definition time" begin
    using StrictMode, StrictModeTest
    # The declaration runs at the enclosing module's precompile, where the proof is unreachable by
    # construction, so a value-free guess must not be able to abort the load. Reaching the next line
    # at all is the assertion that it did not throw.
    @strict_function leaky(n::Int) = sum(collect(1:n))
    @test leaky(3) == 6
    @test_logs (:warn,) match_mode = :any StrictMode._verify_strict_def(leaky, (Int,), "leaky(Int)")
    # …and it registers, so the test environment re-proves the same signature and DOES fail.
    @test_throws StrictViolation test_signatures([(leaky, (Int,))]; guarantees = (:noalloc,))
end

@testitem "@strict_function rejects a type-unstable definition" begin
    using StrictMode
    # Return type Union{Int,String} is a heap-boxing union — not accepted (F21).
    @test_throws StrictViolation begin
        @strict_function maybe(x::Int) = x > 0 ? x : "nope"
    end
end

@testitem "@strict_function skips (warns on) a non-concrete signature" begin
    using StrictMode
    # Abstract arg type → static guarantees are skipped, definition still loads.
    @strict_function generic(x::Number) = x + one(x)
    @test generic(3) == 4
end

@testitem "@strict_function verifies (does not skip) a ::Type{T} argument signature (F37)" begin
    using StrictMode
    empty!(StrictMode.registered_strict())
    # `Type{Float64}` is a fully-specified dispatch signature, not a non-concrete one — it used to
    # be silently skipped (isconcretetype(Type{Float64}) == false) even though it's checkable. (A
    # `where {T}`-generic argument is checked separately below: the macro no longer evaluates the
    # declared types when the signature is parametric.)
    @strict_function typed_clean(::Type{Float64}, n::Int) = n + 1
    @test !isempty(StrictMode.registered_strict())
    @test typed_clean(Float64, 3) == 4
end

@testitem "@strict_function accepts a parametric (where) declaration" begin
    using StrictMode
    # The type variables of a `where` belong to the METHOD, not the enclosing module, so evaluating
    # the declared argument types at module top level raised `UndefVarError: T`. Checks are on by
    # default, so this failed to load in every dev and test environment while working in production.
    @strict_function pgen(x::T) where {T <: Real} = x * 2
    @test pgen(2.0) == 4.0
    @test pgen(3) == 6

    # Nothing is lost by not evaluating them: `Tuple{T}` is not a dispatch tuple, so the check would
    # have taken its abstract-signature path anyway. It says so rather than passing silently.
    @test_logs (:warn,) match_mode = :any (@eval @strict_function pgen2(x::T) where {T <: Real} = x)

    # `signatures = [...]` remains the way to name the concrete instantiations, and still verifies.
    @strict_function pgen3(x::T) where {T <: Real} = x + one(T)  signatures = [(Float64,)]
    @test pgen3(1.0) == 2.0
end

@testitem "@strict module reports the allocation verdict and gates the rest" begin
    using StrictMode
    # `@strict module` runs at the CONSUMER'S own precompile, where StrictModeTest is not loadable,
    # so its allocation verdict is the value-free scan — 8.1% false over a 120-specialization corpus
    # (issue #17). Aborting a module load on that is issue #18, fixed for `@strict_function` and
    # left live here, where the blast radius is every definition in the module rather than one.
    @test_logs (:warn,) match_mode = :any (@eval @strict module _SMAlloc
            leaky(n::Int) = (v = Int[]; for i in 1:n
                    push!(v, i)
                end; sum(v))
        end)
    @test _SMAlloc.leaky(3) == 6

    # The half that must still throw: a non-concrete return is observed, not guessed.
    @test_throws StrictViolation (@eval @strict module _SMBad
            badret(x::Int) = x > 0 ? x : "not a number"
        end)

    # A small isbits union is accepted by design, so this is NOT a violation — pinning it keeps the
    # gate above from being read as "any Union fails".
    @eval @strict module _SMUnion
        maybe(x::Int) = x > 0 ? x : 1.0
    end
    @test _SMUnion.maybe(2) == 2
end
