# Plain, self-contained kernel definitions for `@assert_memsafe`/`memsafe_report` testing.
#
# `isolate=true` runs the guarded probe in a FRESH `julia` subprocess, which locates `f`'s source
# file via `which(f, ...).file` and `include`s it directly — so these kernels must live in a real,
# self-contained file on disk (no reliance on their including module's context), not be `eval`'d
# inline inside a `@testitem`/`@testmodule` body (those aren't reachable from a fresh process).

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
# prove `align=` actually reaches the guard buffer built inside the probe subprocess.
function memsafe_align64_check_kernel!(a::Vector{Float64})
    UInt(pointer(a)) % 64 == 0 || error("not 64-byte aligned: pointer = $(pointer(a))")
    return nothing
end

# Copies one element past the end of both buffers. With a single shared poison byte the
# overrunning store writes the source's poison into the destination's canary and neither reads back
# dirty; distinct per-buffer poison makes the store visible.
function memsafe_copy_overrun!(out::Vector{Float64}, a::Vector{Float64})
    n = length(a) + 1
    @inbounds for i in 1:n
        unsafe_store!(pointer(out), unsafe_load(pointer(a), i), i)
    end
    return out
end

# Copies a buffer's OWN canary bytes to a shifted offset past its end. A constant-fill canary is
# identical at every position, so this store would land poison-on-poison and read back clean.
function memsafe_self_launder_kernel!(a::Vector{Float64})
    p = pointer(a)
    n = length(a)
    unsafe_store!(p, unsafe_load(p, n + 1), n + 3)
    return nothing
end

# Requires its two arguments to alias. Guarding each argument position independently would hand
# this kernel two distinct buffers and make it error, reporting a memory-safety verdict for a call
# that is fine.
function memsafe_alias_required_kernel!(a::Vector{Float64}, b::Vector{Float64})
    pointer(a) == pointer(b) || error("expected aliased arguments, got distinct buffers")
    a[1] = 1.0
    return nothing
end

# A workspace struct carrying its buffer in a field: nothing in the argument list is an `Array`, so
# the overrun below runs unguarded.
struct MemsafeWorkspace
    buf::Vector{Float64}
end

memsafe_struct_kernel!(ws::MemsafeWorkspace) = (ws.buf[1] = 1.0; nothing)

# Stores, one element past the end, the `Float64` whose every byte equals the first buffer's own
# base poison byte. A constant-fill canary of that byte reads back clean after this store; a
# position-dependent fill does not.
function memsafe_poison_collision_kernel!(a::Vector{Float64})
    unsafe_store!(pointer(a), reinterpret(Float64, 0xb4b4b4b4b4b4b4b4), length(a) + 1)
    return nothing
end
