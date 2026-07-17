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

# The masked-load shape from issue #15: reads one element past `a`'s end via a raw pointer, not
# `getindex` — `unsafe_load` never goes through `checkbounds`, so this is NOT the same bug class
# `julia --check-bounds=yes` catches (that flag only re-enables the bounds branch inside
# `@boundscheck`/`getindex`/`setindex!` lowering; `unsafe_load`/`unsafe_store!` never had one to
# re-enable). This is deliberately raw-pointer access — see "@assert_memsafe" in
# docs/src/guarantees.md for why the plain-indexing case doesn't need this harness at all.
function memsafe_oob_read_kernel!(out::Vector{Float64}, a::Vector{Float64})
    n = length(a)
    p = pointer(a)
    @inbounds for i in 1:n
        out[i] = a[i] + unsafe_load(p, i + 1)
    end
    return nothing
end

# Writes one element past `a`'s end via a raw pointer (same rationale as the read kernel above).
function memsafe_oob_write_kernel!(a::Vector{Float64})
    n = length(a)
    unsafe_store!(pointer(a), 99.0, n + 1)
    return nothing
end

# Errors (a genuine, non-memsafe failure) unless `a`'s start pointer is 64-byte aligned — used to
# prove `align=` actually reaches the guard buffer built inside the `isolate=true` subprocess, not
# just the in-process path.
function memsafe_align64_check_kernel!(a::Vector{Float64})
    UInt(pointer(a)) % 64 == 0 || error("not 64-byte aligned: pointer = $(pointer(a))")
    return nothing
end
