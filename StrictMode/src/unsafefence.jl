# Rust's `#![forbid(unsafe_code)]` applied to a Julia module: a layer that must stay inside the
# language's guarantees declares so, and anything that leaves them is reported. Julia cannot enforce
# this — `ccall` and `unsafe_load` are ordinary calls — so it is a scan, and the declaration is the
# caller asking for it.
#
# Read from UNOPTIMIZED typed IR, like `trusted.jl` and `static_ownership.jl`: a small wrapper
# around a pointer load inlines under optimization, and its `unsafe_load` then surfaces in an
# innocent caller while disappearing from the method that wrote it.

# `pointer` does not begin with `unsafe_`, and taking one is the step that leaves the language's
# guarantees even when nothing is dereferenced yet.
const _UNSAFE_NAMES = (:pointer, :pointer_from_objref)

# `ccall` lowers its arguments through these two. Reporting them as separate findings would add a
# line per `ccall` that tells the reader nothing the `ccall` finding did not.
const _CCALL_GLUE = (:cconvert, :unsafe_convert)

# `@inbounds` reaches typed IR as a per-statement flag, not as a statement of its own, so it is read
# from `ssaflags` rather than from `ci.code`. The reference is direct, like `_max_methods`' use of
# `InferenceParams`: a Julia that renames the flag must fail loudly here rather than let the scan
# report a module using `@inbounds` as clean.
const _IR_FLAG_INBOUNDS = Base.Compiler.IR_FLAG_INBOUNDS

_is_unsafe_name(nm::Symbol) = nm in _UNSAFE_NAMES || startswith(String(nm), "unsafe_")

# `allow` names constructs by bare `Symbol`, but a reader looks for the macro they wrote.
_render_construct(nm::Symbol) = nm === :inbounds ? "`@inbounds`" : "`" * String(nm) * "`"

# The unsafe constructs in one method's body, as a sorted, deduplicated list of names. `ccall`
# stands for a `:foreigncall` statement, which is what a `ccall` becomes.
function _unsafe_constructs(m::Method)
    out = Set{Symbol}()
    tt = try
        m.sig
    catch
        return Symbol[]
    end
    cis = try
        Base.code_typed_by_type(tt; optimize = false)
    catch
        return Symbol[]
    end
    for pair in cis
        ci = pair isa Pair ? pair.first : pair
        ci isa Core.CodeInfo || continue
        # One finding per method, so the span an `@inbounds` block covers does not matter: a bare
        # `@inbounds a[i]` flags one statement and `@inbounds for …` flags most of the loop, and
        # both mean the same thing about this method.
        any(fl -> !iszero(fl & _IR_FLAG_INBOUNDS), ci.ssaflags) && push!(out, :inbounds)
        for st in ci.code
            st isa Expr || continue
            if st.head === :foreigncall
                push!(out, :ccall)
                continue
            end
            st.head === :call && !isempty(st.args) || continue
            callee = _unopt_callee(ci, st.args[1])
            isnothing(callee) && continue
            nm = try
                nameof(callee)
            catch
                continue
            end
            nm isa Symbol && _is_unsafe_name(nm) && push!(out, nm)
        end
    end
    # A `ccall` already says this method leaves the language; its own argument conversion is not a
    # second thing to fix.
    :ccall in out && setdiff!(out, _CCALL_GLUE)
    return sort!(collect(out))
end

"""
    unsafe_report(mod::Module; only = nothing, exempt = (), allow = ()) -> Vector{StrictFinding}

Every method in `mod` that leaves Julia's safety guarantees: one `:fail` finding per method that
calls `ccall`, `pointer`, or a function whose name begins with `unsafe_`, or that writes
`@inbounds`.

This is the scan behind `StrictModeTest.test_no_unsafe`, and the Julia form of Rust's
`#![forbid(unsafe_code)]`. The language cannot enforce it — `ccall` and `unsafe_load` are ordinary
calls that any module may make — so a layer that must stay inside the guarantees says so by running
this, and the result is the list of places that do not.

`allow` names the functions this module is permitted to use anyway, by `Symbol`:
`allow = (:unsafe_load,)` keeps a deliberate, reviewed pointer read from failing while still
reporting a `ccall` elsewhere. `only` and `exempt` filter by the *defining* function's name, as
everywhere else.

```julia
unsafe_report(MyKernels)                            # every escape, as findings
unsafe_report(MyKernels; allow = (:unsafe_load,))   # one reviewed construct excused
```

**`@inbounds` is reported as `:inbounds`.** It leaves no statement in lowered or typed IR — it is
carried in the per-statement `ssaflags` — so it is read from there and not from the statement list.
It belongs in this report because it is the one construct here that trades a thrown `BoundsError`
for silent undefined behavior; `allow = (:inbounds,)` excuses it where the in-range property is
proved and tested.

A `Base.@propagate_inbounds` method is clean on its own, and the finding lands on the caller that
wrote `@inbounds`, which is the method that made the claim.

Read from unoptimized IR on purpose. A small wrapper around a pointer load inlines under
optimization, so its `unsafe_load` would surface in an innocent caller and vanish from the method
that actually wrote it.
"""
function unsafe_report(mod::Module; only = nothing, exempt = (), allow = ())
    allowed = Set{Symbol}(Symbol(a) for a in allow)
    out = StrictFinding[]
    methods_, _ = module_methods(mod; only, exempt)
    for m in methods_
        found = _unsafe_constructs(m)
        isempty(found) && continue
        reported = filter(n -> !(n in allowed), found)
        isempty(reported) && continue
        names = join((_render_construct(n) for n in reported), ", ")
        push!(
            out,
            _mkfinding(
                nameof(mod), string(m.name), string(m.sig), :unsafe, true,
                "leaves Julia's safety guarantees: " * names,
                string(m.file), Int(m.line),
                "rewrite the method inside the language, or — where the escape is deliberate and " *
                    "reviewed — name it with `allow = (" *
                    join((":" * String(n) for n in reported), ", ") * ",)` so the exception is " *
                    "visible where the policy is written"
            )
        )
    end
    return out
end
