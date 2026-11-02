# Two advisory module sweeps. Neither states a property the compiler can confirm, so both are
# `:info` findings and neither has a gating counterpart that fails on a threshold alone: a naming
# convention is a convention, and a specialization count is high in exactly the code where Julia is
# working as intended.

# ── the `!` convention ───────────────────────────────────────────────────────────────────────────

# Whether this signature mutates any argument, reusing the taint scan `@assert_concurrency_safe`
# is built on: it seeds taint on one argument and reports a store reaching it, through a chain of
# projections and into non-inlined callees. Asking it once per argument answers "does this method
# write any of them".
function _mutates_any_arg(@nospecialize(f), @nospecialize(types::Tuple); max_depth::Int = 4)
    for i in eachindex(types)
        vs = try
            concurrency_findings(f, types; self_arg = i, max_depth)
        catch
            continue              # a signature the scan cannot read says nothing either way
        end
        isempty(vs) || return true
    end
    return false
end

"""
    bang_report(mod::Module; only = nothing, exempt = (), max_depth = 4) -> Vector{StrictFinding}

Where `mod`'s method names and their mutation disagree: a name ending in `!` whose method writes no
argument, and a name without one whose method writes an argument.

Julia's convention is that `!` marks a function that mutates its arguments. Nothing enforces it, and
a name that gets it wrong misleads every reader and every caller — `@assert_noalias` takes the same
convention as its default for which argument is written, so a wrong name there checks the wrong pair.

Both findings are `:info`, and the two directions are **not** equally reliable:

- **writes an argument without a `!`** is the trustworthy one. The store is in this method's own IR
  or in a callee the scan followed, so it was found rather than assumed, and it is the dangerous
  direction: a caller has no warning its data will change.
- **a `!` that writes nothing** is a lead, not a fact. Mutation through a callee the scan could not
  follow — an unresolved dynamic dispatch, a `foreigncall`, a Base method outside the modelled set
  — reads as no mutation. Check such a method by hand before renaming it.

Judged on the concrete signatures a method has **compiled**, like [`audit`](@ref)'s sweep, so warm
the kernels first; a method with no specialization is skipped rather than guessed at.

```julia
bang_report(MyPkg)                        # every disagreement
bang_report(MyPkg; only = r"^apply")      # just one family
```
"""
function bang_report(mod::Module; only = nothing, exempt = (), max_depth::Int = 4)
    out = StrictFinding[]
    methods_, _ = module_methods(mod; only, exempt)
    for m in methods_
        # The convention is a property of the name the author wrote. Julia's keyword lowering moves
        # the body of `f(x; k)` into a method named `#f#NN`, which ends in a digit, so a raw test
        # reports every keyword-taking `f!` as a mutating method that forgot its `!`.
        name = _demangle(m.name)
        bang = endswith(String(name), "!")
        sigs = _method_signatures(m)
        isempty(sigs) && continue
        f = try
            _method_function(m).instance
        catch
            continue
        end
        mutates = any(tt -> _mutates_any_arg(f, Tuple(tt); max_depth), sigs)
        bang === mutates && continue
        reason, suggestion = if mutates
            (
                "writes an argument, and its name does not end in `!`",
                "rename it `$(name)!`, or return a modified copy instead — a caller reading the " *
                    "name has no warning that its data changes",
            )
        else
            (
                "its name ends in `!`, and no argument is written on the signatures it has compiled",
                "drop the `!` if nothing is mutated. Check by hand first: mutation through an " *
                    "unresolved dispatch, a `foreigncall`, or a Base method outside the modelled " *
                    "set reads as no mutation here",
            )
        end
        push!(
            out,
            StrictFinding(
                nameof(mod), string(m.name), string(m.sig), :bang, :info,
                string(m.file), Int(m.line), reason, suggestion, :report
            )
        )
    end
    return out
end

# ── specialization pressure ──────────────────────────────────────────────────────────────────────

# How deeply a signature nests type parameters. `Vector{Vector{Tuple{Int,Int}}}` is depth 4. Depth
# is a proxy for how much inference has to carry, which is why it is reported and not gated.
function _type_depth(@nospecialize(T), depth::Int = 0)
    depth > 32 && return depth                    # a self-referential parameter cannot deepen forever
    T isa Type || return depth
    best = depth
    if T isa UnionAll
        return _type_depth(T.body, depth)
    elseif T isa Union
        for t in Base.uniontypes(T)
            best = max(best, _type_depth(t, depth + 1))
        end
        return best
    elseif T isa DataType
        for p in T.parameters
            best = max(best, _type_depth(p, depth + 1))
        end
        return best
    end
    return best
end

"""
    specialization_report(mod::Module; max_specializations = 32, max_type_depth = 4,
                          only = nothing, exempt = ()) -> Vector{StrictFinding}

Methods of `mod` that carry more compiled specializations, or deeper nested type parameters, than
the given limits. Every finding is `:info`.

Both numbers are compile-time pressure: each specialization is a separate inference and codegen of
the same source, and parameter depth is how much type structure inference carries through it. A
package that compiles slowly often has a few methods responsible for most of it, and this says which.

**It cannot tell you a count is wrong**, which is why nothing here gates on it. Many
specializations is how Julia produces fast code — a numeric kernel specialized on twenty element
types is the design working. Read a finding as "this is where the compile time is", then decide
whether the method should take fewer type parameters, split its generic part from its specialized
part, or stay exactly as it is.

```julia
specialization_report(MyPkg)                            # the defaults
specialization_report(MyPkg; max_specializations = 8)   # a tighter look at the worst
```

Counts come from what has actually compiled in this session, so a sweep after the suite has run
reports more than one on a cold start.
"""
function specialization_report(
        mod::Module; max_specializations::Int = 32, max_type_depth::Int = 4,
        only = nothing, exempt = ()
    )
    max_specializations >= 1 ||
        throw(ArgumentError("specialization_report: max_specializations must be at least 1"))
    max_type_depth >= 1 ||
        throw(ArgumentError("specialization_report: max_type_depth must be at least 1"))
    # Ranked by the count, highest first: a sweep over a large package returns tens of findings,
    # and the one a reader wants is the biggest. Order IS the summary view — every renderer walks
    # the vector in order, and `findings_diff` is keyed, so it is unaffected.
    ranked = Pair{Int, StrictFinding}[]
    methods_, _ = module_methods(mod; only, exempt)
    for m in methods_
        n = length(_specializations(m))
        d = _type_depth(m.sig)
        over = String[]
        n > max_specializations && push!(over, "$n compiled specializations (limit $max_specializations)")
        d > max_type_depth && push!(over, "type-parameter depth $d (limit $max_type_depth)")
        isempty(over) && continue
        push!(
            ranked,
            n => StrictFinding(
                nameof(mod), string(m.name), string(m.sig), :specialization, :info,
                string(m.file), Int(m.line), join(over, ", "),
                "each specialization is a separate inference and codegen of the same source. If " *
                    "the compile time matters, split the part that must specialize from the part " *
                    "that does not, or move a size or flag into a `Val` so one parameter replaces " *
                    "many. A high count can also be correct — this says where the time goes, not " *
                    "that anything is wrong",
                :report
            )
        )
    end
    sort!(ranked; by = first, rev = true)
    return StrictFinding[f for (_, f) in ranked]
end

# ── the aliasing guard ───────────────────────────────────────────────────────────────────────────

# Julia's own overlap predicates. `Base.mightalias` is the oracle both `@assert_noalias` and
# `Base.unalias` use, and `dataids` is what `mightalias` is built from. Naming any of them is
# unambiguous evidence that the author considered overlap.
const _ALIAS_ORACLES = Set{Symbol}((:mightalias, :unalias, :dataids))

# `===` is the narrower guard LinearAlgebra's `mul!` writes by hand, and it counts ONLY between two
# of the method's own arguments. Unqualified it also matches the `=== nothing` that every `for`
# loop's iteration protocol emits — measured: counting it marked every looping method as guarded,
# including one that reads `a[i + 1]` while writing `out[i]` with no check at all.
function _is_arg_identity(nm::Symbol, args)
    (nm === :(===) || nm === :(!==)) || return false
    length(args) == 2 || return false
    return all(a -> a isa Core.Argument || a isa Core.SlotNumber, args)
end

# Could a value of this type be an array, so that two parameters of it could name the same memory?
# Asked of the TYPE, so the answer is "cannot be ruled out" rather than "is" — `Any` counts, and a
# type the scan cannot narrow is not a type it has cleared.
# `Any` is excluded deliberately. `typeintersect(Any, AbstractArray)` is non-empty, so an
# unannotated argument counted as a possible array and any `!` method with two of them was
# reported — which is most generic Julia code, and was 5 of 6 findings on StrictMode itself (`f`,
# `types`, `ci` parameters, none of them arrays). An `Any` declaration carries no information about
# aliasing, and this check is `:info` precisely because an empty report is a lead rather than a
# proof, so trading unknowable-type recall for a usable signal is the right side of that bargain.
# An abstract ARRAY type still counts: `AbstractVector{T}` says the argument is an array.
_could_be_array(@nospecialize(T)) =
    T isa Type && T !== Any && typeintersect(T, AbstractArray) !== Union{}

# How many of this method's parameters could alias one another. One array argument has nothing to
# overlap with, so the guard question only arises from two.
function _aliasable_arity(m::Method)
    sig = Base.unwrap_unionall(m.sig)
    (sig isa DataType && length(sig.parameters) >= 2) || return 0
    return count(_could_be_array(Base.unwrap_unionall(P)) for P in sig.parameters[2:end])
end

# Does this method's own body ask whether two of its arguments overlap? Read from UNOPTIMIZED IR,
# because the guard is a call the author wrote and optimization folds `mightalias` into comparisons
# that no longer carry its name. `nothing` when the IR could not be read — which a caller must not
# read as "no guard".
function _has_alias_guard(m::Method)
    cis = try
        Base.code_typed_by_type(m.sig; optimize = false)
    catch
        return nothing
    end
    isempty(cis) && return nothing
    for pair in cis
        ci = pair isa Pair ? pair.first : pair
        ci isa Core.CodeInfo || continue
        for st in ci.code
            callee, args = _call_callee_and_args(ci, st)
            isnothing(callee) && continue
            nm = try
                nameof(callee)
            catch
                continue
            end
            nm isa Symbol || continue
            (nm in _ALIAS_ORACLES || _is_arg_identity(nm, args)) && return true
        end
    end
    return false
end

"""
    alias_guard_report(mod::Module; only = nothing, exempt = ()) -> Vector{StrictFinding}

Mutating methods in `mod` that take two or more possibly-overlapping array arguments and never ask
whether they overlap. Every finding is `:info`.

Rust rejects `C = A * C` at compile time, because the call borrows `C` twice. Julia compiles it, and
whether anything notices is up to the callee: `LinearAlgebra.mul!` throws on `C === A`, but only on
its BLAS and small-matrix paths — the generic fallback has no check, so the same call on
`Matrix{Int}` returns a silently wrong answer, and a `view(C, :, :)` slips past an identity test on
every path. A user kernel usually has no check at all.

What this asks is narrow and value-free: does the method's own body *mention* overlap, through
`Base.mightalias`, `Base.unalias`, `dataids`, or an `===` between arguments. That is a question
about text, not about values, so it can be swept — where [`@assert_noalias`](@ref) cannot, since
overlap is a property of the arguments and a sweep has none.

**It is `:info`, and the absent direction is a lead rather than a fact.** A guard living in a callee
the scan did not follow reads as no guard, exactly as in [`bang_report`](@ref): "found a guard" is
observed, "found none" is not. So this nominates methods to read, and the per-call-site
`@assert_noalias` — or a `Base.unalias` in the body — is what actually establishes the property.

```julia
alias_guard_report(MyPkg)                      # every unguarded mutating kernel
alias_guard_report(MyPkg; only = r"^gemm")     # one family
```

Judged on the method's declared signature, so a method with no compiled specialization is still
covered — unlike the sweeps that read what has run.

An argument declared `Any` does **not** count as a possible array. The declaration says nothing
about aliasing, and counting it reported every `!` method with two unannotated arguments, which is
most generic Julia code. An abstract array type still counts: `AbstractVector{T}` does say the
argument is an array.
"""
function alias_guard_report(mod::Module; only = nothing, exempt = ())
    out = StrictFinding[]
    methods_, _ = module_methods(mod; only, exempt)
    for m in methods_
        endswith(String(m.name), "!") || continue
        n = _aliasable_arity(m)
        n >= 2 || continue
        _has_alias_guard(m) === false || continue    # `true` guards, `nothing` could not be read
        push!(
            out,
            StrictFinding(
                nameof(mod), string(m.name), string(m.sig), :alias_guard, :info,
                string(m.file), Int(m.line),
                "mutates, takes $n arguments that could overlap, and never asks whether they do",
                "guard the overlap where the method is written — `Base.unalias` to copy, or an " *
                    "explicit `Base.mightalias` test and a `throw` — or assert it per call site " *
                    "with `@assert_noalias`. A guard inside a callee this scan did not follow " *
                    "reads as none, so check by hand before adding one",
                :report
            )
        )
    end
    return out
end

# ── numeric conversions ──────────────────────────────────────────────────────────────────────────

# Every concrete number type appearing anywhere in a type, element types included: a
# `Vector{Float64}` argument names `Float64` exactly as a bare `Float64` does. `Bool` is left out
# because it is an `Integer` in Julia, so counting it would make a flag argument a conversion source
# in every method that branches on one.
function _numeric_types!(acc::Set{Any}, @nospecialize(T), depth::Int = 0)
    depth > 8 && return acc                      # a self-referential parameter cannot deepen forever
    T isa Type || return acc
    if T isa UnionAll
        return _numeric_types!(acc, T.body, depth + 1)
    elseif T isa Union
        for t in Base.uniontypes(T)
            _numeric_types!(acc, t, depth + 1)
        end
        return acc
    elseif T isa DataType
        isconcretetype(T) && T <: Number && T !== Bool && push!(acc, T)
        for p in T.parameters
            _numeric_types!(acc, p, depth + 1)
        end
    end
    return acc
end

# Julia lowers every numeric conversion to one of these intrinsics, and the name already states the
# direction, so classifying one needs no size comparison.
const _CONV_KIND = Dict{Symbol, String}(
    :fpext => "widened",
    :sext_int => "widened",
    :zext_int => "widened",
    :fptrunc => "narrowed",
    :trunc_int => "narrowed",
    :sitofp => "retyped",
    :uitofp => "retyped",
    :fptosi => "retyped",
    :fptoui => "retyped"
)

# The inferred type of a conversion's operand, whichever kind of IR reference holds it.
function _conv_operand_type(ci, @nospecialize(x))
    if x isa Core.Argument
        slots = ci.slottypes
        return (slots isa Vector && 1 <= x.n <= length(slots)) ? slots[x.n] : nothing
    elseif x isa Core.SSAValue
        sts = ci.ssavaluetypes
        return (sts isa Vector && 1 <= x.id <= length(sts)) ? sts[x.id] : nothing
    end
    return typeof(x)
end

# The numeric conversions one signature performs on its OWN data, as `(from, to, direction)`.
#
# Read from the conversion INSTRUCTION, not from the set of types the locals carry. A type set
# cannot tell a converted value from an unrelated one, and integers make that fatal: a clean
# `Float32` loop carries `Int64` and `UInt64` locals for its counters, so comparing type sets
# reports every loop in a package (measured). An intrinsic is the conversion itself, so a kernel
# that keeps its precision has none at all.
#
# The operand type must be one the arguments name, which is what makes this the method's own data
# rather than an incidental conversion inside something it called.
function _conversions(@nospecialize(f), @nospecialize(types::Tuple))
    out = Set{Tuple{Any, Any, String}}()
    own = Set{Any}()
    for A in types
        _numeric_types!(own, A)
    end
    isempty(own) && return out
    ci = try
        Base.code_typed(f, types; optimize = true)[1].first
    catch
        return out
    end
    sts = ci.ssavaluetypes
    sts isa Vector || return out
    for (i, st) in enumerate(ci.code)
        Meta.isexpr(st, :call) || continue
        callee = st.args[1]
        (callee isa GlobalRef && haskey(_CONV_KIND, callee.name)) || continue
        length(st.args) >= 3 || continue
        src = _conv_operand_type(ci, st.args[end])
        (src in own) || continue
        dst = (1 <= i <= length(sts)) ? sts[i] : nothing
        (dst isa DataType && isconcretetype(dst) && dst <: Number) || continue
        dst === src && continue
        push!(out, (src, dst, _CONV_KIND[callee.name]))
    end
    return out
end

"""
    conversion_report(mod::Module; only = nothing, exempt = ()) -> Vector{StrictFinding}

Methods of `mod` that convert their own numeric data to another type. Every finding is `:info`.

A bare numeric literal in Julia carries a default type — `Float64` for `0.529`, `Int` for `2` — so
one unsuffixed constant converts a whole kernel: `0.529 * x` with `x::Float32` is a `Float64`
multiply, and `2 * x` with `x::Int32` is an `Int64` multiply. The result converts back on the way
out, so the answers are right and the output type is right, and the arithmetic ran at half the SIMD
width. Measured on a 65536-element loop, `0.529` against `T(0.529)`: **2.2 µs against 7.2 µs**, with
36 double-precision operations in the generated code and no single-precision ones.

Three directions are reported, named in the finding:

- **widened** — `Float32` to `Float64`, `Int32` to `Int64`. The arithmetic runs wider than the data.
- **narrowed** — `Float64` to `Float32`, `Int64` to `Int32`. Values outside the narrower range or
  precision are lost.
- **retyped** — between integer and floating point, which rounds or truncates.

**Nothing else reports this.** The compiler is not permitted to remove the conversion: narrowing the
arithmetic would change results (~19% of random `Float32` inputs differ between
`Float64`-then-round and `Float32`-throughout), so the promotion is semantics rather than a missed
optimization, and `@fastmath` does not narrow it either. An error analyzer sees no error, an
optimization analyzer sees no dynamic dispatch, and [`@assert_typestable`](@ref) sees a perfectly
concrete type — `Float64` is concrete, it is merely the wrong one.

Read from the conversion **instruction**, never from the types the locals carry, and never from the
return type:

- A type set cannot distinguish a converted value from an unrelated one. A clean `Float32` loop
  carries `Int64` and `UInt64` locals for its counters, so comparing type sets reports every loop in
  a package.
- Every way of handing back a `T` converts at the boundary — a `::T` declaration, an explicit `T(x)`,
  a store into an `Array{T}` — so a kernel computing entirely in `Float64` still returns a flawless
  `Float32`. A check reading the return type passes such a method.

A conversion is attributed to this method only when its operand has a type the arguments name, which
is what separates the method's own data from an incidental conversion inside something it called.

Two shapes are reported that may be exactly what the author wanted, which is why this never gates:

- **a deliberately wider accumulator**, such as a `Float64` sum over `Float32` data for numerical
  stability. This is correct code and it is reported.
- **an explicit narrowing or retyping**, such as `Float32(x)` in a `Float64` kernel or `round` to an
  integer index.

```julia
conversion_report(MyPkg)                                  # every conversion
conversion_report(MyPkg; only = r"^kernel_")              # one family
conversion_report(MyPkg; from = Float32, to = Float64)    # one class
conversion_report(MyPkg; directions = "narrowed")         # one direction
```

`directions`, `from` and `to` filter which conversions count, and on a package with C-ABI shims
that is the difference between a usable report and an unusable one: passing a Fortran `CHARACTER`
through `Ptr{UInt8}` widens `UInt8` to `UInt32` at every such call, which is benign, unfixable
without breaking the ABI, and numerous enough to bury the `Float32`-to-`Float64` findings this
exists for. `from`/`to` take a type or a tuple of types; `directions` takes one of `"widened"`,
`"narrowed"`, `"retyped"`, or a tuple.

Judged on the concrete signatures a method has **compiled**, like [`bang_report`](@ref), so warm the
kernels first; a method with no specialization is skipped rather than guessed at.
"""
function conversion_report(
        mod::Module; only = nothing, exempt = (),
        directions = ("widened", "narrowed", "retyped"), from = nothing, to = nothing
    )
    dirs = directions isa AbstractString ? (directions,) : directions
    froms = isnothing(from) ? nothing : (from isa Type ? (from,) : from)
    tos = isnothing(to) ? nothing : (to isa Type ? (to,) : to)
    keep(c) =
        (c[3] in dirs) &&
        (isnothing(froms) || any(T -> c[1] === T, froms)) &&
        (isnothing(tos) || any(T -> c[2] === T, tos))

    out = StrictFinding[]
    methods_, _ = module_methods(mod; only, exempt)
    for m in methods_
        sigs = _method_signatures(m)
        isempty(sigs) && continue
        f = try
            _method_function(m).instance
        catch
            continue
        end
        convs = Set{Tuple{Any, Any, String}}()
        for tt in sigs
            union!(convs, _conversions(f, Tuple(tt)))
        end
        filter!(keep, convs)
        isempty(convs) && continue
        shown = sort!(["$(c[1]) to $(c[2]) ($(c[3]))" for c in convs])
        widened = any(c -> c[3] == "widened", convs)
        push!(
            out,
            StrictFinding(
                nameof(mod), string(m.name), string(m.sig), :conversion, :info,
                string(m.file), Int(m.line),
                "converts its own values: " * join(shown, ", ") *
                    (widened ? " — the arithmetic runs wider than the data" : ""),
                "write the literals in the type the data already has, by suffix (`0.5f0`) or by " *
                    "wrapping (`T(0.5)`), so no conversion is needed. A wider accumulator or a " *
                    "narrowing chosen on purpose reports here too, so confirm the intent before " *
                    "changing anything",
                :report
            )
        )
    end
    return out
end
