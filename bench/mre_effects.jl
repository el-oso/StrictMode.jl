# MRE for JuliaLang/julia Issue: extend automatic effects inference to pure @inbounds SIMD loops.
#
# Rust infers effect-free from types; Julia needs Base.@assume_effects manually.
# This MRE prints inferred effects for an annotated vs unannotated pure function.

@inline function inner_sum(x::NTuple{4, Float64})
    return x[1] + x[2] + x[3] + x[4]
end

Base.@assume_effects :foldable @inline function inner_sum_annotated(x::NTuple{4, Float64})
    return x[1] + x[2] + x[3] + x[4]
end

println("Without @assume_effects:")
println("  infer_effects: ", Base.infer_effects(inner_sum, (NTuple{4, Float64},)))

println("With @assume_effects :foldable:")
println("  infer_effects: ", Base.infer_effects(inner_sum_annotated, (NTuple{4, Float64},)))

println("\nExpected: the annotated version is :foldable (consistent+terminates+effect_free+nothrow).")
println("If the unannotated version already shows the same effects, the gap may be closed upstream.")
