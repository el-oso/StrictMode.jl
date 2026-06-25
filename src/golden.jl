# F19: @golden — gated bit-exact (or ~ULP-tolerant) regression harness.
#
# A dev/test tool for port verification: record a function's output once, then compare on
# every subsequent run. Exact for deterministic ops; accepts a ULP tolerance for SIMD
# reductions whose lane-combine order is codegen-defined (F18).
#
# Always runs regardless of `checks_enabled` — a golden test must execute even in production
# builds, since it checks correctness, not performance.

# --- type support -------------------------------------------------------------------------------

# Supported concrete real element types for golden storage.
const _GOLDEN_REAL = Union{Float32, Float64}
# Supported result types: Real scalar, real array, complex array.
const _GOLDEN_SUPPORTED = Union{
    Real,
    AbstractArray{<:Real},
    AbstractArray{<:Complex{<:Real}},
}

# Tag byte written at the start of every golden file (guards against type/shape mismatch).
const _GOLDEN_MAGIC = UInt8(0xAB)   # arbitrary sentinel
const _TAG_F32 = UInt8(1)
const _TAG_F64 = UInt8(2)
const _TAG_CF32 = UInt8(3)
const _TAG_CF64 = UInt8(4)
const _TAG_SCALAR_F32 = UInt8(5)
const _TAG_SCALAR_F64 = UInt8(6)

function _golden_tag(@nospecialize(x))
    x isa Real && return (Float64(x), _TAG_SCALAR_F64)
    isa(x, AbstractArray{Float32}) && return (convert(Array{Float32}, x), _TAG_F32)
    isa(x, AbstractArray{Float64}) && return (convert(Array{Float64}, x), _TAG_F64)
    isa(x, AbstractArray{<:Complex{Float32}}) && return (convert(Array{ComplexF32}, x), _TAG_CF32)
    isa(x, AbstractArray{<:Complex{Float64}}) && return (convert(Array{ComplexF64}, x), _TAG_CF64)
    # Fall-through for unsupported types (caller handles)
    return (nothing, UInt8(0))
end

# Write golden file: magic + tag + length (8 bytes) + raw payload.
function _write_golden(path::String, @nospecialize(x))
    val, tag = _golden_tag(x)
    tag == 0 && error("@golden: unsupported result type $(typeof(x)); supported: Real scalar, AbstractArray{<:Real}, AbstractArray{<:Complex}")
    open(path, "w") do io
        write(io, _GOLDEN_MAGIC, tag)
        if val isa Float64
            write(io, UInt64(0), val)  # length=0 signals scalar
        else
            n = length(val)
            write(io, UInt64(n))
            write(io, val)
        end
    end
    return nothing
end

# Read and validate golden file; return (tag, data_vector_or_scalar).
function _read_golden(path::String)
    bytes = read(path)
    length(bytes) < 10 && error("@golden: corrupted golden file (too short): $path")
    bytes[1] == _GOLDEN_MAGIC || error("@golden: bad magic in golden file (may be from a different run): $path")
    tag = bytes[2]
    n = reinterpret(UInt64, bytes[3:10])[1]
    payload = bytes[11:end]
    if tag == _TAG_SCALAR_F64
        length(payload) == 8 || error("@golden: corrupted scalar golden at $path")
        return tag, reinterpret(Float64, payload)[1]
    elseif tag == _TAG_F32
        length(payload) == n * 4 || error("@golden: shape mismatch in golden at $path")
        return tag, copy(reinterpret(Float32, payload))
    elseif tag == _TAG_F64
        length(payload) == n * 8 || error("@golden: shape mismatch in golden at $path")
        return tag, copy(reinterpret(Float64, payload))
    elseif tag == _TAG_CF32
        length(payload) == n * 8 || error("@golden: shape mismatch in golden at $path")
        return tag, copy(reinterpret(ComplexF32, payload))
    elseif tag == _TAG_CF64
        length(payload) == n * 16 || error("@golden: shape mismatch in golden at $path")
        return tag, copy(reinterpret(ComplexF64, payload))
    else
        error("@golden: unknown tag $(tag) in golden file — was it written by a different version? $path")
    end
end

# ULP distance between two Float64 values (signed-magnitude integer rep distance).
@inline function _ulp_dist(a::Float64, b::Float64)
    ia = reinterpret(Int64, a)
    ib = reinterpret(Int64, b)
    # Normalize negative-zero and handle sign differences via abs difference.
    ia = ia < 0 ? (Int64(-9223372036854775808) - ia) : ia  # typemin(Int64) == -2^63
    ib = ib < 0 ? (Int64(-9223372036854775808) - ib) : ib
    return abs(ia - ib)
end
@inline function _ulp_dist(a::Float32, b::Float32)
    ia = reinterpret(Int32, a)
    ib = reinterpret(Int32, b)
    ia = ia < 0 ? (Int32(-2147483648) - ia) : ia
    ib = ib < 0 ? (Int32(-2147483648) - ib) : ib
    return abs(ia - ib)
end
@inline _ulp_dist(a::Complex{T}, b::Complex{T}) where {T} =
    max(_ulp_dist(real(a), real(b)), _ulp_dist(imag(a), imag(b)))

# Compare result vs golden bytes, throwing StrictViolation on mismatch.
function _compare_golden(name::String, @nospecialize(result), path::String, ulps::Int)
    rval, rtag = _golden_tag(result)
    rtag == 0 && error("@golden: unsupported result type $(typeof(result))")

    gtag, gdata = _read_golden(path)
    rtag == gtag || throw(StrictViolation(
        :golden, name,
        "type mismatch: golden has tag $gtag, result has tag $rtag. " *
        "Delete the golden file to re-record: $path"
    ))

    if rval isa Float64 && gdata isa Float64
        # Scalar case
        if ulps == 0
            rval === gdata || throw(StrictViolation(
                :golden, name,
                "exact mismatch: expected $gdata, got $rval (ULP distance: $(_ulp_dist(rval, gdata))). " *
                "Use `ulps=N` for tolerance or delete the golden to re-record."
            ))
        else
            d = _ulp_dist(rval, gdata)
            d <= ulps || throw(StrictViolation(
                :golden, name,
                "ULP mismatch: expected $gdata, got $rval ($d ULPs, tolerance $ulps)."
            ))
        end
        return
    end

    # Array case
    length(rval) == length(gdata) || throw(StrictViolation(
        :golden, name,
        "length mismatch: golden has $(length(gdata)) elements, result has $(length(rval)). " *
        "Delete the golden file to re-record: $path"
    ))
    for i in eachindex(rval, gdata)
        a, b = rval[i], gdata[i]
        if ulps == 0
            a === b || throw(StrictViolation(
                :golden, name,
                "exact mismatch at index $i: expected $b, got $a " *
                "(ULP distance: $(_ulp_dist(a, b))). " *
                "Use `ulps=N` for tolerance or delete the golden to re-record."
            ))
        else
            d = _ulp_dist(a, b)
            d <= ulps || throw(StrictViolation(
                :golden, name,
                "ULP mismatch at index $i: expected $b, got $a ($d ULPs, tolerance $ulps)."
            ))
        end
    end
    return
end

# --- macro --------------------------------------------------------------------------------------

"""
    @golden name expr
    @golden name expr ulps=N
    @golden name expr dir=some_path
    @golden name expr ulps=N dir=some_path
    @golden name expr validator=f

Gated bit-exact (or ~ULP-tolerant) regression harness for numeric kernels.

**Record mode** (golden file absent, or `STRICTMODE_RECORD_GOLDEN=1`): evaluate `expr`,
write the result to a golden file, log `@info`, and return the result.

**Compare mode** (golden file present): evaluate `expr`, compare against the stored golden.
- `ulps=0` (default): exact bit equality (`===` per element).
- `ulps=N>0`: allow up to N ULPs per element (per-element signed-magnitude integer-rep
  distance), useful for SIMD reductions whose lane-combine order is codegen-defined (F18).

On mismatch throws [`StrictViolation`](@ref) naming `name`, the first failing index, the
expected and actual values, and the ULP distance.

- `validator = f`: semantic invariant predicate. If provided, no golden file is written or
  compared — `f(result)` is called instead, and a `StrictViolation` is thrown if it returns
  `false`. Use for problems with multiple valid outputs (e.g. shortest-float formatters where
  `parse(Float64, out) === x` is the right oracle, not byte-equality against one reference).

**Supported result types:** `Real` scalars, `AbstractArray{<:Real}`, `AbstractArray{<:Complex}`.
Other types throw a clear "unsupported golden type" error.

**Golden file location:** anchored at `@__DIR__` of the calling file by default (a `golden/`
subdirectory is created). Override with `dir=` for testing or a shared golden store.

!!! note
    This macro always executes regardless of `checks_enabled` — golden tests check correctness,
    not performance, and must run even in production builds.

```julia
# Exact match for a deterministic kernel
result = @golden "norm_l2" my_norm(x)

# 1-ULP tolerance for a SIMD reduction
result = @golden "dot_result" my_dot(a, b) ulps=1

# Custom golden directory (useful in tests with mktempdir)
result = @golden "kernel_out" kernel!(y, x) dir=tmpdir

# Semantic invariant for a shortest-float formatter
result = @golden "ryu_out" format_float(x) validator=s->parse(Float64,s)===x
```
"""
macro golden(name, expr, kwargs...)
    # Parse optional keyword arguments: ulps=N, dir=<path>, validator=f.
    ulps_val = 0
    dir_expr = nothing
    validator_expr = nothing
    for kw in kwargs
        Meta.isexpr(kw, :(=), 2) || throw(ArgumentError("@golden: unexpected argument $kw; expected `ulps=N`, `dir=<path>`, or `validator=f`"))
        k, v = kw.args
        if k === :ulps
            ulps_val = v  # may be a literal or expression
        elseif k === :dir
            dir_expr = v
        elseif k === :validator
            validator_expr = v
        else
            throw(ArgumentError("@golden: unknown keyword `$k`; expected `ulps`, `dir`, or `validator`"))
        end
    end

    # Anchor dir at the calling file's @__DIR__ if not supplied.
    if dir_expr === nothing
        dir_code = :(joinpath(@__DIR__, "golden"))
    else
        dir_code = esc(dir_expr)
    end

    name_esc = esc(name)
    expr_esc = esc(expr)
    ulps_esc = esc(ulps_val)
    validator_esc = esc(validator_expr === nothing ? :nothing : validator_expr)

    return quote
        let _golden_name = $(name_esc),
            _golden_dir  = $(dir_code),
            _golden_ulps = $(ulps_esc),
            _golden_path = joinpath(_golden_dir, string(_golden_name) * ".golden"),
            _golden_result = $(expr_esc)

            if $(validator_esc) !== nothing
                # Semantic invariant path: call validator(result) instead of byte comparison.
                # No golden file is written or read — the invariant IS the oracle.
                $(validator_esc)(_golden_result) || throw(StrictViolation(
                    :golden, string(_golden_name),
                    "semantic invariant failed for \"$_golden_name\": validator returned false."
                ))
            else
                if !isfile(_golden_path) || get(ENV, "STRICTMODE_RECORD_GOLDEN", "") == "1"
                    mkpath(_golden_dir)
                    StrictMode._write_golden(_golden_path, _golden_result)
                    @info "StrictMode @golden: recorded golden for \"$_golden_name\" at $_golden_path"
                else
                    StrictMode._compare_golden(string(_golden_name), _golden_result, _golden_path, _golden_ulps)
                end
            end
            _golden_result
        end
    end
end
