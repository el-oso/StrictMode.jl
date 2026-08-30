# MRE for JuliaLang/julia Issue: automatic noalias propagation parity with Rust.
#
# Rust gives LLVM `noalias` on every `&mut` parameter for free via ownership.
# Julia's Array arguments are conservatively aliasing unless the user asserts otherwise.
# This MRE shows the LLVM IR difference; attach @code_llvm output when filing the issue.

function dot_conservative(a::Vector{Float64}, b::Vector{Float64})
    s = 0.0
    @inbounds for i in eachindex(a, b)
        s += a[i] * b[i]
    end
    return s
end

function dot_ivdep(a::Vector{Float64}, b::Vector{Float64})
    s = 0.0
    @inbounds @simd ivdep for i in eachindex(a, b)
        s += a[i] * b[i]
    end
    return s
end

using InteractiveUtils

println("=== Without @simd ivdep (conservative aliasing) ===")
@code_llvm debuginfo = :none dot_conservative(Float64[], Float64[])

println("\n=== With @simd ivdep (noalias asserted) ===")
@code_llvm debuginfo = :none dot_ivdep(Float64[], Float64[])

println("\n--- noalias in define line? ---")
ir_conservative = sprint(io -> code_llvm(io, dot_conservative, (Vector{Float64}, Vector{Float64}); debuginfo = :none))
ir_ivdep = sprint(io -> code_llvm(io, dot_ivdep, (Vector{Float64}, Vector{Float64}); debuginfo = :none))
define_conservative = first(eachline(IOBuffer(ir_conservative)))
define_ivdep = first(eachline(IOBuffer(ir_ivdep)))
println("conservative: ", occursin("noalias", define_conservative) ? "noalias present" : "noalias ABSENT")
println("ivdep:        ", occursin("noalias", define_ivdep) ? "noalias present" : "noalias ABSENT")
