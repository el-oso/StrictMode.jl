# Plain, self-contained kernel definitions for `@assert_memsafe`/`memsafe_report` testing.
#
# `isolate=true` runs the guarded probe in a FRESH `julia` subprocess, which locates `f`'s source
# file via `which(f, ...).file` and `include`s it directly — so these kernels must live in a real,
# self-contained file on disk (no reliance on their including module's context), not be `eval`'d
# inline inside a `@testitem`/`@testsetup` body (those aren't reachable from a fresh process).

function memsafe_inbounds_kernel!(out::Vector{Float64}, a::Vector{Float64})
    @inbounds for i in eachindex(a)
        out[i] = a[i] * 2
    end
    return nothing
end

# The masked-load shape from issue #15: reads one element past `a`'s end.
function memsafe_oob_read_kernel!(out::Vector{Float64}, a::Vector{Float64})
    n = length(a)
    @inbounds for i in 1:n
        out[i] = a[i] + a[i + 1]
    end
    return nothing
end

# Writes one element past `a`'s end.
function memsafe_oob_write_kernel!(a::Vector{Float64})
    n = length(a)
    @inbounds a[n + 1] = 99.0
    return nothing
end

# Errors (a genuine, non-memsafe failure) unless `a`'s start pointer is 64-byte aligned — used to
# prove `align=` actually reaches the guard buffer built inside the `isolate=true` subprocess, not
# just the in-process path.
function memsafe_align64_check_kernel!(a::Vector{Float64})
    UInt(pointer(a)) % 64 == 0 || error("not 64-byte aligned: pointer = $(pointer(a))")
    return nothing
end
