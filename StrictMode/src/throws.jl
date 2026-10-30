# What a function raises, read from its own typed IR: every `throw` in the body, with the inferred
# type of the value handed to it.
#
# SCOPE, which is the whole design decision here. This reports what the body itself throws, not what
# its callees throw. The alternative — everything reachable — is not useful in Julia: `v[1]` can
# raise a `BoundsError` from inside `getindex`, `x + y` can raise from a promotion, and almost any
# call can raise `OutOfMemoryError`, so a transitive catalog converges on "nearly everything" for
# nearly every function. What an author can act on, document, and promise is the set of exceptions
# their own code constructs deliberately, and that is what this lists.

# The exception types a body throws. `throw` receives one value; its inferred type IS the exception
# type, since the value is built in the statement above and inference has it exactly.
function _thrown_types(@nospecialize(f), @nospecialize(types::Tuple))
    out = Set{Type}()
    cts = try
        Base.code_typed(f, types; optimize = false)
    catch
        return out
    end
    for pair in cts
        ci = pair isa Pair ? pair.first : pair
        ci isa Core.CodeInfo || continue
        for st in ci.code
            st isa Expr && st.head === :call && length(st.args) >= 2 || continue
            callee = _unopt_callee(ci, st.args[1])
            callee === Core.throw || callee === Base.throw || continue
            T = _unopt_arg_type(ci, st.args[2])
            T isa Type && T !== Union{} && push!(out, T)
        end
    end
    return out
end

"""
    throw_report(f, types) -> Vector{Type}
    throw_report(mod::Module; only = nothing, exempt = ()) -> Vector{StrictFinding}

The exception types `f` raises **in its own body**, sorted by name; or, for a module, one `:info`
finding per method that throws, listing them.

```julia
throw_report(parse_header, (Vector{UInt8},))      # [ArgumentError, DomainError]
throw_report(MyPkg)                               # every method that raises, with its types
```

**It reports what this body throws, not what its callees throw**, and that is deliberate. A
transitive catalog is not useful in Julia: `v[1]` raises `BoundsError` from inside `getindex`,
arithmetic raises from promotion, and nearly any call can raise `OutOfMemoryError` — so "everything
reachable" converges on "nearly everything" for nearly every function, which tells a reader nothing.
What an author can act on, document and promise is the set their own code constructs deliberately.

So read a result as *"these are the failures this function declares"*, not *"these are the only
failures a caller can see"*. For the stronger statement — this function raises **only** these types
— pair it with a [`@strict_contract`](@ref), where the claim is checked against a declaration rather
than discovered.

The types come from inference on unoptimized IR, so a `throw` on a branch no test reaches is still
listed; that is the point. A method with no compiled specialization contributes nothing to the module
form, which sweeps the same set as [`audit`](@ref).
"""
function throw_report(@nospecialize(f), @nospecialize(types))
    tt = Tuple(types)
    return sort!(collect(Type, _thrown_types(f, tt)); by = string)
end

function throw_report(mod::Module; only = nothing, exempt = ())
    out = StrictFinding[]
    methods_, _ = module_methods(mod; only, exempt)
    for m in methods_
        f = try
            _method_function(m).instance
        catch
            continue
        end
        found = Set{Type}()
        for tt in _method_signatures(m)
            union!(found, _thrown_types(f, Tuple(tt)))
        end
        isempty(found) && continue
        names = sort!(collect(found); by = string)
        push!(
            out,
            StrictFinding(
                nameof(mod), string(m.name), string(m.sig), :throws, :info,
                string(m.file), Int(m.line),
                "raises " * join(("`" * string(T) * "`" for T in names), ", "),
                "document these in the docstring, or pin them with a `@strict_contract` so the " *
                    "set is a declaration rather than whatever the body happens to construct. " *
                    "Exceptions raised by callees are not listed and a caller still sees them",
                :report
            )
        )
    end
    return out
end
