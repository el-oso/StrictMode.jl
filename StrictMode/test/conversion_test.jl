@testitem "conversion_report names the methods that convert their own numeric data" begin
    using StrictMode

    module Conv
    # A bare literal is a Float64, so this computes in Float64 and converts on the way out.
    function leaky(r::T) where {T}
        f = 14.3996 * (0.529 * r)
        return f
    end
    # The same arithmetic kept in T.
    function clean(r::T) where {T}
        f = T(14.3996) * (T(0.529) * r)
        return f
    end
    # A declared return type CONVERTS, so the return reads as a flawless T while the body is
    # Float64 throughout. This is the shape a return-type check cannot see.
    function annotated(r::T)::T where {T}
        f = 14.3996 * (0.529 * r)
        return f
    end
    # A store into an Array{T} converts the same way, and hides it the same way.
    function stored!(out::Vector{T}, x::Vector{T}) where {T}
        for i in eachindex(out, x)
            out[i] = 0.529 * x[i] + 14.3996
        end
        return out
    end
    # A wider accumulator chosen deliberately, for numerical stability. Correct code, and reported.
    function wide_acc(x::Vector{T}) where {T}
        acc = 0.0
        for i in eachindex(x)
            acc += Float64(x[i])
        end
        return T(acc)
    end
    # A bare integer literal is an Int, so this widens Int32 data exactly as the float case does.
    intwide(x::T) where {T} = 2 * x + 1
    # The same arithmetic kept in T.
    intclean(x::T) where {T} = T(2) * x + T(1)
    # Integer data, floating-point arithmetic.
    tofloat(n::T) where {T} = n * 2.0
    # Float data narrowed on purpose.
    narrowing(x::T) where {T} = Float32(x) * 2.0f0
    # Mixed precision is declared in the signature, and the conversion it forces is still a
    # conversion of this method's own data, so it is reported.
    mixed(a::Float32, b::Float64) = a * b
    # No conversion at all: one integer type throughout.
    intkern(a::Int, b::Int) = a * b
    # A reduction that keeps its element type. Its loop counters are Int64 and UInt64 whatever the
    # data is, which is why this check reads conversion instructions and not the types of locals.
    function loopsum(A::AbstractVector{T}) where {T}
        acc = zero(T)
        for i in eachindex(A)
            acc += A[i]
        end
        return acc
    end
    # Float data beside an integer length: both types are the method's own, and neither converts.
    function sized!(out::Vector{T}, x::Vector{T}, n::Int) where {T}
        for i in Base.OneTo(n)
            out[i] = T(2) * x[i]
        end
        return out
    end
    # `Bool` is an `Integer` in Julia and widens to `Int64` to be counted. Treating it as data
    # would report every method that sums or branches on a flag.
    boolsum(flags::Vector{Bool}) = sum(flags)
    end

    # The sweep judges compiled signatures, so every kernel has to run once.
    o = zeros(Float32, 4); x = rand(Float32, 4)
    oi = zeros(Int32, 4); xi = Int32[1, 2, 3, 4]
    Conv.leaky(1.0f0); Conv.clean(1.0f0); Conv.annotated(1.0f0)
    Conv.stored!(o, x); Conv.wide_acc(x)
    Conv.intwide(Int32(3)); Conv.intclean(Int32(3)); Conv.tofloat(Int32(3))
    Conv.narrowing(1.0); Conv.mixed(1.0f0, 1.0); Conv.intkern(2, 3)
    Conv.loopsum(x); Conv.loopsum(xi)
    Conv.sized!(o, x, 4); Conv.sized!(oi, xi, 4)
    Conv.boolsum([true, false, true])

    fs = conversion_report(Conv)
    named = Set(f.func for f in fs)
    reason(nm) = only(filter(f -> f.func == nm, fs)).reason

    @test all(f -> f.guarantee === :conversion && f.status === :info, fs)
    @test all(f -> f.code === :SM0310, fs)

    # Floats: the original case.
    @test "leaky" in named
    @test occursin("Float32 to Float64 (widened)", reason("leaky"))
    @test occursin("wider", reason("leaky"))

    # Integers: the same defect, the same widening instruction.
    @test "intwide" in named
    @test occursin("Int32 to Int64 (widened)", reason("intwide"))

    # Between integer and floating point, in both directions.
    @test "tofloat" in named
    @test occursin("retyped", reason("tofloat"))
    @test "narrowing" in named
    @test occursin("Float64 to Float32 (narrowed)", reason("narrowing"))
    @test !occursin("wider", reason("narrowing"))

    # The whole point of reading instructions instead of the return type: both of these hand back a
    # flawless Float32 and are still caught.
    @test Base.return_types(Conv.annotated, (Float32,)) == [Float32]
    @test "annotated" in named
    @test eltype(Conv.stored!(o, x)) === Float32
    @test "stored!" in named

    # A declared mixed-precision signature still converts its own data.
    @test "mixed" in named

    # Correct code is silent, whatever its element type.
    @test !("clean" in named)
    @test !("intclean" in named)
    @test !("intkern" in named)

    # The false positive that reading types of locals would cause, pinned in both element types: a
    # clean reduction carries Int64 and UInt64 loop counters and converts nothing.
    @test !("loopsum" in named)
    @test !("sized!" in named)

    # Bool is excluded as a data type, so counting flags is not a conversion of this method's data.
    @test !("boolsum" in named)

    # The known false positive, pinned so a change in it is visible: a deliberately wider
    # accumulator is reported, which is why this check never gates.
    @test "wide_acc" in named
end

@testitem "conversion_report is silent on a module that keeps its numeric types" begin
    using StrictMode

    module AllClean
    scale(r::T) where {T} = T(2) * r
    combine(a::T, b::T) where {T} = a * b + one(T)
    countem(a::Int) = a + 1
    end

    AllClean.scale(1.0f0); AllClean.scale(Int32(2))
    AllClean.combine(1.0f0, 2.0f0); AllClean.countem(1)
    @test isempty(conversion_report(AllClean))
end
