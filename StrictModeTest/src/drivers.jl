# The gating drivers. Each takes a scope, proves every guarantee in it, and raises ONCE at the end
# carrying every failure — so one method that cannot be analyzed leaves the other 299 evaluated
# rather than aborting the sweep at the first bad one.
#
# A guarantee the analysis could not evaluate counts as a failure here. A gate that cannot evaluate
# a method must not pass it.

# A gate over an EMPTY scope proves nothing, and returning green is indistinguishable from having
# proved everything. Every driver funnels through here so no scope can go quiet: an empty signature
# list, a module nothing has compiled yet, or an `only`/`exempt` filter that matched nothing all
# reach this point.
# The signatures in a gate that asked for `:trim_compatible`, in the key shape `_trim_validate`
# looks up.
function _trim_sigs(items)
    sigs = Tuple{Any, Vector{Any}}[]
    for (f, types, guarantees) in items
        (:trim_compatible in guarantees) || continue
        push!(sigs, (f, _argtypes(Tuple{types...})))
    end
    return sigs
end

function _gate(items, kind::Symbol, target::AbstractString)
    isempty(items) && @warn "StrictModeTest.$kind: nothing to prove for `$target` (0 signatures). " *
        "This result is green because it checked nothing, not because anything passed. A module " *
        "sweep needs its kernels exercised first (a concrete specialization must exist), and an " *
        "`only`/`exempt` filter can exclude everything."
    # Trim verification for the whole gate in one child process, rather than one per signature:
    # starting Julia, loading the packages and applying juliac's patches is the entire cost, and it
    # is the same cost for fifty signatures as for one. The cache is emptied afterwards so a verdict
    # can never outlive the gate that asked for it.
    fs = try
        _trim_batch!(_trim_sigs(items))
        StrictMode._map_findings(_proof_findings, items)
    finally
        empty!(_TRIM_BATCH)
    end
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
    test_registered(; guarantees = nothing, modules = nothing) -> Vector{StrictFinding}

Re-prove every signature in StrictMode's mark-once registry — everything `@strict_function`,
`@strict module`, or `register_strict!` declared — and throw a `StrictMode.StrictViolation`
collecting every failure. `guarantees = nothing` uses each entry's own setting; pass a tuple to
override.

The registry is process-global and keyed on `(f, types)` with no module of its own, so a dependency
loaded from source in the same session (a Revise or `dev` setup) contributes its declarations too —
and your gate would then judge its kernels. `modules = [MyPkg]` scopes the sweep by each registered
function's defining module. Unscoped, the reported count is broken down per module so an unexpected
one is visible rather than silent.

It reports how many signatures it proved, because the registry is populated at *declaration* time
and an implausibly small count is the signal that something did not register. A declaration made in
a package's own `src/` is stored in that package, so it survives the package's cached load and is
counted here; one made by a direct `register_strict!` call belongs to the session that made it.
"""
function test_registered(; guarantees = nothing, modules = nothing)
    StrictMode.assert_enabled()
    items = StrictMode._registry_items(guarantees; modules)
    if isempty(items)
        StrictMode._warn_empty_registry(
            "test_registered",
            "`test_signatures([(f, types), …])` or `test_compiled(MyPkg)`"
        )
    else
        # The per-module breakdown, not just the total: the registry is process-global and carries
        # no module of its own, so a module you did not expect in this list is a dependency's
        # declarations being judged by your gate.
        by_mod = StrictMode._registry_breakdown(items)
        @info "StrictModeTest: re-proving $(length(items)) registered signature(s) — " *
            join(("$m: $n" for (m, n) in by_mod), ", ")
    end
    return _gate(items, :test_registered, "registry")
end

"""
    proof_findings(mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = ())
        -> Vector{StrictFinding}

Every concrete method instance `mod`'s functions have **actually compiled**, proved and returned as
data. The module-scope counterpart of [`proof_findings(f, types)`](@ref), and the non-raising
counterpart of [`test_compiled`](@ref).

Reach for it when you want the proofs but not the raise: `test_compiled` returns its findings only
when everything passes and throws a `StrictViolation` carrying a formatted string otherwise, so it
cannot hand you structured findings for a package that is currently failing — which is exactly when
an agent wants them.
"""
proof_findings(mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = ()) =
    StrictMode._findings_compiled(_proof_findings, mod; guarantees, only, exempt)

"""
    proof_audit(target = :registered; guarantees = nothing, sweep = false,
                require = nothing, only = nothing, exempt = ()) -> Vector{StrictFinding}

[`StrictMode.audit`](@ref) with the proofs behind it: same targets, same scoping, and the same
`Vector{StrictFinding}` back, and it likewise **never throws and never sets an exit status**. The
only difference is the engine — AllocCheck, JET and TrimCheck instead of the value-free scan.

That is the whole point of it existing. `audit`'s allocation verdicts are structural guesses, which
is fine for discovery but means an agent cannot tell a real regression from noise; the `test_*`
drivers prove but raise, so they cannot hand back findings for a failing package. `proof_audit`
is the missing corner: proved verdicts, as data.

It costs what the proofs cost — roughly an order of magnitude more per method than `audit` — so
scope a module sweep with `only`/`exempt` rather than pointing it at everything.

```julia
using MyPkg, StrictMode, StrictModeTest
fs = proof_audit(MyPkg; sweep = true, exempt = r"^_plan")
nfailures(fs)        # proved failures, not guesses
```
"""
proof_audit(target = :registered; kwargs...) =
    StrictMode._audit(_proof_findings, "proof_audit", target; kwargs...)

"""
    test_coverage(mod::Module; require = :all, only = nothing, exempt = ())
        -> Vector{StrictFinding}

Assert that every signature `mod` defines and has compiled is either **declared** or **visibly
exempt**, and throw a `StrictMode.StrictViolation` naming each one that is neither.

A method that has compiled concrete signatures needs every one of them declared: a declaration
names a signature, so declaring `f(Float64)` says nothing about an `f(Int32)` that reached the same
body. A method nothing has compiled yet has no signature to name, and there this asks only whether
some declaration speaks for it.

This is the gate for the thing the other drivers cannot see. `test_registered` re-proves what was
declared and `test_compiled` proves what ran; neither notices a method that was never brought under
StrictMode at all. Here a missing declaration is a failure, so forgetting one is a red test rather
than a silent pass.

Its verdicts are facts, not inferences — a declaration either names a signature this method would
be dispatched for, or it does not — which is why this gates where StrictMode's allocation verdicts
only report.

`require = :all` counts every method, including those on foreign functions (`Base.size`,
`Base.getindex`); `:public` counts only exported/`public` functions. Scope with `only`/`exempt`
exactly as the other drivers do.

```julia
# in runtests.jl, next to the drivers that prove the guarantees
StrictMode.register_strict!(MyPkg.kernel!, (Vector{Float64},); guarantees = (:noalloc,))
test_registered()                       # …the declared guarantees hold
test_coverage(MyPkg; exempt = r"^_plan")   # …and nothing is undeclared
```

!!! note
    A declaration made by `@strict_function` inside a package's `src/` counts here: it is stored in
    that package, so it survives the cached load this gate runs after. A package that annotates its
    source is therefore not told its own methods are undeclared.
"""
function test_coverage(mod::Module; require::Symbol = :all, only = nothing, exempt = ())
    fs = require === :all ? StrictMode._coverage_all_findings(mod; only, exempt) :
        require === :public ? StrictMode._coverage_findings(mod; only, exempt) :
        throw(ArgumentError("test_coverage: require must be :all or :public, got $(require)"))
    failed = filter(StrictMode._failed, fs)
    isempty(failed) && return fs
    msg = sprint(io -> StrictMode.format_findings(io, failed; format = :text))
    throw(StrictMode.StrictViolation(:test_coverage, string(nameof(mod)), msg))
end

"""
    test_exemptions(mod::Module; only = nothing) -> Vector{StrictFinding}

Report the exemptions in `mod` that the **proofs** now find unnecessary: code marked cold that
satisfies the guarantee it was excused from.

An exemption is forever unless something looks at it. Code gets fixed, a buffer gets preallocated,
and the opt-out stays — so the guarantee is off for a function that would now pass. This is the
counterpart of declaring: `test_coverage` finds what nobody declared, and this finds what nobody
un-excused.

Findings are `:info` and **never failures**, so this never fails a build. Two reasons: an exemption
is a human's deliberate statement and removing it is their call, and a red test for tidy-up work is
a new reason to switch the gate off.

It lives here, in the proving tier, because only a proof may say this. StrictMode's value-free scan
is wrong in both directions on allocation, so "the scan no longer sees a problem" is a guess; acting
on it would delete an exemption the proofs then fail. Each exemption is checked by AllocCheck, JET
and TrimCheck, on the signatures the exemption covers.

An exemption that names no signature is checked against every concrete signature the function has
compiled; one that names a signature is checked against that one. A function with nothing compiled
cannot be judged and is reported as such.
"""
function test_exemptions(mod::Module; only = nothing)
    out = StrictMode.StrictFinding[]
    for e in StrictMode.exemptions()
        _name_hit(only, e.func) || continue
        for (f, tt) in _exempt_signatures(mod, e)
            gs = isnothing(e.guarantees) ? StrictMode._DEFAULT_POLICY : e.guarantees
            sg = StrictMode._sig_string(tt)
            fs = try
                proof_findings(f, tt; guarantees = gs)
            catch err
                # Not swallowed: an exemption the proofs could not evaluate is a third answer, and
                # reporting nothing would read as "still needed" without having checked.
                push!(
                    out, StrictMode.StrictFinding(
                        nameof(mod), string(e.func), sg, :exemption, :info, e.file, e.line,
                        "could not check whether this exemption is still needed: " *
                            sprint(showerror, err),
                        "Prove the signature directly with `test_signatures([($(e.func), $sg)])` " *
                            "to decide whether the opt-out is doing anything.", :proof
                    )
                )
                continue
            end
            all(x -> x.status === :pass, fs) || continue
            push!(
                out, StrictMode.StrictFinding(
                    nameof(mod), string(e.func), sg, :exemption, :info, e.file, e.line,
                    "exemption is no longer needed: $(sg) satisfies $(join(gs, ", "))" *
                        (e.reason == "" ? "" : " (recorded reason: $(e.reason))"),
                    "the proofs pass for this signature, so the opt-out now hides nothing — " *
                        "remove `@strict_exempt $(e.func)` to hold it to the guarantee again.",
                    :proof
                )
            )
        end
    end
    return out
end

# `only` filters by the exemption's function NAME, since that is all an exemption carries — the
# shared `_name_matcher` builds a predicate over functions instead.
_name_hit(spec, name::Symbol) =
    isnothing(spec) ? true :
    spec isa Regex ? occursin(spec, string(name)) :
    spec isa Function ? spec(name) :
    name in Set{Symbol}(x isa Symbol ? x : nameof(x) for x in spec)

# The signatures an exemption should be judged on: the one it names, or every concrete signature the
# function has compiled.
function _exempt_signatures(mod::Module, e::StrictMode.Exemption)
    out = Tuple{Any, Tuple}[]
    ms, _ = StrictMode.module_methods(mod; include_exempt = true)   # the subject IS the exempt code
    for m in ms
        StrictMode._demangle(m.name) === e.func || continue
        ft = StrictMode._method_function(m)
        f = try
            ft.instance
        catch
            continue
        end
        if isnothing(e.types)
            for tt in StrictMode._method_signatures(m)
                push!(out, (f, Tuple(tt)))
            end
        else
            push!(out, (f, e.types))
        end
    end
    return out
end

# A call that cannot resolve is not a performance defect, so none of the guarantees cover it and it
# has no entry in `StrictMode.guarantee_names()`. It is its own sweep, like `test_coverage`: the
# filters are by NAME, which is also the escape hatch when inference cannot follow a guard.
function _call_findings(mod::Module; only = nothing, exempt = ())
    out = StrictMode.StrictFinding[]
    for (f, tt, _) in StrictMode._compiled_items(mod; guarantees = (:typestable,), only, exempt)
        types = Tuple(tt)
        fn, sg, md = StrictMode._func_name(f), StrictMode._sig_string(types), StrictMode._mod_sym(f)
        reps = _call_reports("test_calls", f, types, mod)
        if isempty(reps)
            push!(out, StrictMode._mkfinding(md, fn, sg, :calls, false, "", "", 0; tier = :proof))
            continue
        end
        for rep in reps
            m = try
                first(methods(f, types))
            catch
                nothing
            end
            file = m isa Method ? string(m.file) : ""
            line = m isa Method ? Int(m.line) : 0
            push!(
                out,
                StrictMode._mkfinding(
                    md, fn, sg, :calls, true, sprint(show, rep), file, line,
                    "a call on this path cannot resolve, so reaching it raises rather than " *
                        "returning. Fix the call, or — when a guard makes the path unreachable " *
                        "and inference cannot prove it — exclude the function by name with " *
                        "`exempt = (:$fn,)` and say why in a comment.";
                    tier = :proof
                )
            )
        end
    end
    return out
end

"""
    test_calls(mod::Module; only = nothing, exempt = ()) -> Vector{StrictFinding}

Prove that every call reachable from `mod`'s compiled signatures resolves, and throw a
`StrictMode.StrictViolation` collecting every one that does not.

This is the hole the other gates cannot see. [`@test_typestable`](@ref) and the allocation proofs
read **optimized** IR and answer performance questions — does this dispatch at run time, does it
allocate. A call that cannot resolve at all is invisible to them: a `MethodError` on a branch no
test happens to take passes every one. JET's call analysis (`report_call`) finds it before the
branch is ever reached, which is the closest Julia analogue of a compiler that checks every line of
every build.

Two report kinds are gated, `MethodErrorReport` and `UndefVarErrorReport` — a call with no matching
method, and a name that is not defined. The others are deliberately dropped. Over StrictMode's own
569 compiled signatures there were 373 non-boolean-condition reports, nearly all a `Missing` from
union-splitting a `Vector{Any}` that never holds one, against 3 distinct method errors; and an
uncaught-exception report fires on any function that validates its arguments and throws, which is
correct code. A gate whose output is mostly noise is a gate that gets switched off.

Scope is the same as [`test_compiled`](@ref): the signatures that have actually **compiled**, so
warm the kernels first. `only` and `exempt` filter by function name.

```julia
test_calls(MyPkg)                                   # every compiled signature
test_calls(MyPkg; only = r"^kernel_")               # just the hot ones
test_calls(MyPkg; exempt = (:read_config,))         # a guard inference cannot follow
```

A failure can be a false positive, and the shape is specific: a guard that makes the bad path
unreachable, written where inference cannot carry the refinement to the call. `isnothing(ref[]) &&
(ref[] = build())` followed by a second load of `ref[]` is the common one — the check narrows the
first load, not the second, so the value stays `Union{Nothing,T}` and every use of it reports.
Binding the load to a local once fixes both the report and the type instability behind it.
"""
function test_calls(mod::Module; only = nothing, exempt = ())
    fs = _call_findings(mod; only, exempt)
    failed = filter(StrictMode._failed, fs)
    isempty(failed) && return fs
    msg = sprint(io -> StrictMode.format_findings(io, failed; format = :text))
    throw(StrictMode.StrictViolation(:test_calls, string(nameof(mod)), msg))
end
