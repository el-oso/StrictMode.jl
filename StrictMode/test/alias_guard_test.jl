@testitem "alias_guard_report names the mutating kernels that never ask about overlap" begin
    using StrictMode

    module AliasGuards
    # Unguarded, and genuinely wrong when aliased: element i reads a[i+1], which an aliased `out`
    # has already overwritten.
    function shift_add!(out::Vector{Float64}, a::Vector{Float64})
        for i in 1:(length(a) - 1)
            out[i] = a[i] + a[i + 1]
        end
        return out
    end
    # Guarded with Julia's own oracle, the one `@assert_noalias` and `Base.unalias` both use.
    function guarded!(out::Vector{Float64}, a::Vector{Float64})
        Base.mightalias(out, a) && throw(ArgumentError("out must not alias a"))
        copyto!(out, a)
        return out
    end
    # Guarded the narrower way LinearAlgebra writes by hand.
    function identity_guarded!(out::Vector{Float64}, a::Vector{Float64})
        out === a && throw(ArgumentError("out must not be a"))
        copyto!(out, a)
        return out
    end
    # Guarded by taking a copy instead of refusing.
    function unaliased!(out::Vector{Float64}, a::Vector{Float64})
        copyto!(out, Base.unalias(out, a))
        return out
    end
    # One array argument: nothing to overlap with.
    scale!(out::Vector{Float64}, k::Float64) = (out .*= k; out)
    # Mutates nothing, so the convention does not put it in scope.
    total(a::Vector{Float64}, b::Vector{Float64}) = sum(a) + sum(b)
    end

    fs = alias_guard_report(AliasGuards)
    named = Set(f.func for f in fs)

    @test "shift_add!" in named
    @test all(f -> f.guarantee === :alias_guard && f.status === :info, fs)
    @test all(f -> f.code === :SM0308, fs)

    # Each of the three guard spellings counts, and neither the single-array nor the non-mutating
    # method is in scope at all.
    @test !("guarded!" in named)
    @test !("identity_guarded!" in named)
    @test !("unaliased!" in named)
    @test !("scale!" in named)
    @test !("total" in named)

    only_one = only(filter(f -> f.func == "shift_add!", fs))
    @test occursin("could overlap", only_one.reason)
    @test occursin("@assert_noalias", only_one.suggestion)

    # The name filters behave as on every other sweep.
    @test isempty(alias_guard_report(AliasGuards; only = r"^nothing_matches$"))
    @test isempty(alias_guard_report(AliasGuards; exempt = (:shift_add!,)))

    # It is a REPORT: no gating counterpart, and `:alias_guard` is not a swept guarantee — the
    # value-taking `:noalias` is what establishes the property, per call site.
    @test !(:alias_guard in StrictMode._GUARANTEES)
    @test !(:noalias in StrictMode._GUARANTEES)
end

@testitem "an `Any` argument is not evidence of an array" begin
    using StrictMode

    # `typeintersect(Any, AbstractArray)` is non-empty, so an unannotated argument counted as a
    # possible array and any `!` method with two of them was reported. That is most generic Julia
    # code: it was 5 of 6 findings on StrictMode itself, all on `f`/`types`/`ci` parameters. An
    # `Any` declaration says nothing about aliasing. An abstract ARRAY type still counts.
    @test !StrictMode._could_be_array(Any)
    @test StrictMode._could_be_array(AbstractArray)
    @test StrictMode._could_be_array(AbstractVector{Float64})
    @test StrictMode._could_be_array(Vector{Float64})
    @test StrictMode._could_be_array(Union{Nothing, Vector{Int}})
    @test !StrictMode._could_be_array(Int)

    module AnyArgs
    # Two unannotated arguments, neither an array. Reported before, silent now.
    register!(f, types) = (push!([], (f, types)); nothing)
    # Two real arrays and no guard: still reported.
    both!(a::Vector{Float64}, b::Vector{Float64}) = (a[1] = b[1]; nothing)
    # An abstract array type is still an array.
    absarr!(a::AbstractVector{Float64}, b::AbstractVector{Float64}) = (a[1] = b[1]; nothing)
    end

    named = Set(f.func for f in alias_guard_report(AnyArgs))
    @test !("register!" in named)
    @test "both!" in named
    @test "absarr!" in named
end
