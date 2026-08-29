# The gating drivers. Each takes a scope, proves every guarantee in it, and raises ONCE at the end
# carrying every failure — so one method that cannot be analyzed leaves the other 299 evaluated
# rather than aborting the sweep at the first bad one.
#
# A guarantee the analysis could not evaluate counts as a failure here. A gate that cannot evaluate
# a method must not pass it.

function _gate(items, kind::Symbol, target::AbstractString)
    fs = StrictMode._map_findings(_proof_findings, items)
    failed = filter(StrictMode._failed, fs)
    isempty(failed) && return fs
    msg = sprint(io -> StrictMode.format_findings(io, failed; format = :text))
    throw(StrictMode.StrictViolation(kind, target, msg))
end

"""
    test_signatures(pairs; guarantees = (:typestable, :noalloc)) -> Vector{StrictFinding}

Prove `guarantees` for an explicit list of `(f, types)` pairs, and throw a
`StrictMode.StrictViolation` collecting every failure. Returns the findings when all pass.

It takes **signatures, not values**, which is why it exists alongside the `@test_*` macros:
`@test_noalloc gemm!(C, A, B)` makes you build the arguments, while gating a `10000×10000`
signature here costs nothing. It also needs no `src/` annotations, so a test suite can list a
library's guaranteed entry points without the library depending on StrictMode at all:

```julia
test_signatures([
    (dot3, (NTuple{3,Float64}, NTuple{3,Float64})),
    (gemm!, (Matrix{Float64}, Matrix{Float64}, Matrix{Float64})),
])
```
"""
function test_signatures(pairs; guarantees = (:typestable, :noalloc))
    items = Any[(f, Tuple(types), guarantees) for (f, types) in pairs]
    return _gate(items, :test_signatures, "signatures")
end

"""
    test_compiled(mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = ())
        -> Vector{StrictFinding}

Prove `guarantees` for every concrete method instance `mod`'s functions have **actually compiled**
(during your tests, a run, or the precompile workload), and throw a `StrictMode.StrictViolation`
collecting every failure.

No annotation needed, but coverage is whatever executed, and a module that mixes hot and cold
(plan-time) helpers will be noisy — cold helpers that legitimately allocate show up too. Scope it
with `only` / `exempt`, each a collection of functions / name `Symbol`s, a **`Regex`** matched
against the (demangled) name, or a predicate `f -> Bool`. `@strict_exempt` names are always
excluded, so `exempt = r"^_plan"` scales a mixed hot/cold library without a hand-listed set.

This is the gate. [`StrictMode.audit`](@ref) is the reporting counterpart for the same scope.
"""
function test_compiled(mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = ())
    items = StrictMode._compiled_items(mod; guarantees, only, exempt)
    return _gate(items, :test_compiled, string(nameof(mod)))
end

"""
    test_registered(; guarantees = nothing) -> Vector{StrictFinding}

Re-prove every signature in StrictMode's mark-once registry — everything `@strict_function`,
`@strict module`, or `register_strict!` declared — and throw a `StrictMode.StrictViolation`
collecting every failure. `guarantees = nothing` uses each entry's own setting; pass a tuple to
override.

It reports how many signatures it proved, because the registry is populated at *declaration* time
and an implausibly small count is the signal that something did not register. In particular,
`@strict_function` runs at its own module's precompile, and that cross-package `Dict` insert does
not survive a cached pkgimage load — so a consumer's test process can see an empty registry however
many declarations its `src/` carries. [`test_signatures`](@ref) and [`test_compiled`](@ref)
enumerate directly and are unaffected.
"""
function test_registered(; guarantees = nothing)
    StrictMode.assert_enabled()
    items = StrictMode._registry_items(guarantees)
    if isempty(items)
        StrictMode._warn_empty_registry(
            "test_registered",
            "`test_signatures([(f, types), …])` or `test_compiled(MyPkg)`"
        )
    else
        @info "StrictModeTest: re-proving $(length(items)) registered signature(s)."
    end
    return _gate(items, :test_registered, "registry")
end
