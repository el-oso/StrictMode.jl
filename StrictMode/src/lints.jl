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
        bang = endswith(String(m.name), "!")
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
                "rename it `$(m.name)!`, or return a modified copy instead — a caller reading the " *
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
    out = StrictFinding[]
    methods_, _ = module_methods(mod; only, exempt)
    for m in methods_
        n = length(_specializations(m))
        d = _type_depth(m.sig)
        over = String[]
        n > max_specializations && push!(over, "$n compiled specializations (limit $max_specializations)")
        d > max_type_depth && push!(over, "type-parameter depth $d (limit $max_type_depth)")
        isempty(over) && continue
        push!(
            out,
            StrictFinding(
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
    return out
end
