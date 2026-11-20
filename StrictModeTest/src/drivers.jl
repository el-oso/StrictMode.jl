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

function _gate(items, kind::Symbol, target::AbstractString; allow_exempt::Bool = false)
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
        # An exempt-only result is a failure from the proof unless this gate's caller accepted
        # the exemptions.
        StrictMode._map_findings(_proof_analyzer(allow_exempt), items)
    finally
        empty!(_TRIM_BATCH)
    end
    # A listed signature is one its author expects to return; in a sweep, a signature that always
    # throws is an error helper and stays a note.
    kind === :test_signatures && (fs = StrictMode._gate_always_throws(fs))
    failed = filter(StrictMode._failed, fs)
    isempty(failed) && return fs
    msg = sprint(io -> StrictMode.format_findings(io, failed; format = :text))
    throw(StrictMode.StrictViolation(kind, target, msg))
end

"""
    test_signatures(pairs; guarantees = (:typestable, :noalloc), allow_exempt = false)
        -> Vector{StrictFinding}

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

A signature that allocates only inside functions exempted from `:noalloc` is not a pass: the proof
reports it as a failure with code SM0018 that lists the exempt functions and their reasons, and this
gate, like `test_compiled`, `test_registered` and `@test_noalloc`, fails on it. `allow_exempt = true`
accepts the exemptions for this gate: the result is then a note, and the gate passes when nothing
else allocates.
Only an exemption declared in the function's own module counts; a session-wide one, which covers by
name, leaves its caller an ordinary failure.
"""
function test_signatures(pairs; guarantees = (:typestable, :noalloc), allow_exempt::Bool = false)
    # A name no guarantee has is a mistake in the call, not a failing signature.
    StrictMode._check_guarantees(guarantees)
    items = Any[(f, Tuple(types), guarantees) for (f, types) in pairs]
    return _gate(items, :test_signatures, "signatures"; allow_exempt)
end

"""
    test_compiled(mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = (),
                  allow_exempt = false)
        -> Vector{StrictFinding}

Prove `guarantees` for every concrete method instance `mod`'s functions have **actually compiled**
(during your tests, a run, or the precompile workload), and throw a `StrictMode.StrictViolation`
collecting every failure.

That includes the methods `mod`, its submodules and its loaded extensions define on a function
`mod` does not own (`Base.getproperty`, `Base.size`, or a submodule's own function): the method
written in the package is swept, and the function's other methods are not.

No annotation needed, but coverage is whatever executed, and a module that mixes hot and cold
(plan-time) helpers will be noisy — cold helpers that legitimately allocate show up too. Scope it
with `only` / `exempt`, each a collection of functions / name `Symbol`s, a **`Regex`** matched
against the (demangled) name, or a predicate `f -> Bool`. `@strict_exempt` names are always
excluded, so `exempt = r"^_plan"` scales a mixed hot/cold library without a hand-listed set.

This is the gate. [`StrictMode.audit`](@ref) is the reporting counterpart for the same scope.
"""
function test_compiled(
        mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = (),
        allow_exempt::Bool = false
    )
    items = StrictMode._compiled_items(mod; guarantees, only, exempt)
    return _gate(items, :test_compiled, string(nameof(mod)); allow_exempt)
end

"""
    test_registered(; guarantees = nothing, modules = nothing, allow_exempt = false)
        -> Vector{StrictFinding}

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
function test_registered(; guarantees = nothing, modules = nothing, allow_exempt::Bool = false)
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
    return _gate(items, :test_registered, "registry"; allow_exempt)
end

"""
    proof_findings(mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = (),
                   allow_exempt = false)
        -> Vector{StrictFinding}

Every concrete method instance `mod`'s functions have **actually compiled**, proved and returned as
data. The module-scope counterpart of [`proof_findings(f, types)`](@ref), and the non-raising
counterpart of [`test_compiled`](@ref).

Reach for it when you want the proofs but not the raise: `test_compiled` returns its findings only
when everything passes and throws a `StrictViolation` carrying a formatted string otherwise, so it
cannot hand you structured findings for a package that is currently failing — which is exactly when
an agent wants them.

A signature that allocates only inside functions exempted from `:noalloc` is a failure with code
SM0018, as in every gate; `allow_exempt = true` accepts those exemptions, and the result is then a
note (`:info`, same code, same `exempt_by`).
"""
proof_findings(
    mod::Module; guarantees = (:typestable, :noalloc), only = nothing, exempt = (),
    allow_exempt::Bool = false
) = StrictMode._findings_compiled(_proof_analyzer(allow_exempt), mod; guarantees, only, exempt)

# `_proof_findings` as the `analyze(f, types, guarantees)` callable the shared drivers take, with
# the caller's acceptance of exempt-only results applied to every signature they reach.
_proof_analyzer(allow_exempt::Bool) =
    (f, types, gs) -> _proof_findings(f, types, gs; allow_exempt)

"""
    proof_audit(target = :registered; guarantees = nothing, sweep = false,
                require = nothing, only = nothing, exempt = (), allow_exempt = false)
        -> Vector{StrictFinding}

[`StrictMode.audit`](@ref) with the proofs behind it: same targets, same scoping, and the same
`Vector{StrictFinding}` back, and it likewise **never throws on a violation and never sets an exit
status**. The only difference is the engine — AllocCheck, JET and TrimCheck instead of the
value-free scan. An argument that names nothing raises an `ArgumentError`, as in `audit`: an
unknown guarantee, a `target` that is neither `:registered` nor a module, an invalid `require`,
`format`/`io`, and an `only` or `exempt` entry that matches no function with a method in the
module.

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

A signature that allocates only inside functions exempted from `:noalloc` is a failure with code
SM0018; `allow_exempt = true` accepts those exemptions for every signature the audit proves, and the
result is then a note (`:info`, same code, same `exempt_by`).
"""
proof_audit(target = :registered; allow_exempt::Bool = false, kwargs...) =
    StrictMode._audit(_proof_analyzer(allow_exempt), "proof_audit", target; kwargs...)

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
    # No method in scope renders exactly like full coverage, so say so, as the registry does. The
    # findings name only what is undeclared, so it is the scope that is counted, not them.
    _coverage_scope_empty(mod, require; only, exempt) &&
        @warn "test_coverage($(nameof(mod)); require = :$require): no methods are in " *
        "scope (0 checks) — this result proves nothing. `require = :public` judges exported " *
        "functions only; `require = :all` judges every method the module defines."
    failed = filter(StrictMode._failed, fs)
    isempty(failed) && return fs
    msg = sprint(io -> StrictMode.format_findings(io, failed; format = :text))
    throw(StrictMode.StrictViolation(:test_coverage, string(nameof(mod)), msg))
end

function _coverage_scope_empty(mod::Module, require::Symbol; only, exempt)
    require === :all && return isempty(first(StrictMode.module_methods(mod; only, exempt)))
    keep_only = StrictMode._name_matcher(only)
    drop = StrictMode._name_matcher(exempt)
    return !any(names(mod)) do nm
        isdefined(mod, nm) || return false
        f = getfield(mod, nm)
        (f isa Function && parentmodule(f) === mod) || return false
        (isnothing(drop) || !drop(f)) && (isnothing(keep_only) || keep_only(f))
    end
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
        fn, sg, md = StrictMode._func_name(f), StrictMode._sig_string(types), StrictMode._mod_sym(f, types)
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

"""
    test_latency(pkg::Symbol; calls = String[], max_load_ms = nothing,
                 max_first_call_ms = nothing, precompile = true) -> LatencyReport

Measure load time and first-call time for `pkg` in a fresh child process, and throw a
`StrictMode.StrictViolation` if a stated budget is exceeded.

This is the axis none of the guarantees reach. They are all about the code a call runs; this is
about the time paid before it runs — the load, and the compile tax on the first call of a
signature. Both are properties of a cold process, so only a child can measure them.

**Both budgets are opt-in, and deliberately so.** A wall-clock threshold depends on the machine:
the same package loads at different speeds on a laptop, a shared runner and a pinned host, so a
default would fail honest code on a slow box and pass a regression on a fast one. State a budget
only where the host is pinned. With neither budget given this measures and returns, and nothing can
fail — use it that way to record the numbers before choosing them.

```julia
test_latency(:MyPkg)                                      # measure, never fail
test_latency(:MyPkg; max_load_ms = 400)                   # a pinned host, a real budget
test_latency(:MyPkg; calls = ["MyPkg.solve!(ws, b)"], max_first_call_ms = 2_000)
```

`calls` are strings of Julia code run in the child after the package loads; write them fully
qualified. `max_first_call_ms` applies to each call separately, and the failure names the one that
missed. `precompile = false` skips building the cache first, for a suite that already loaded the
package — see [`StrictMode.latency_report`](@ref) for what that costs and what the report then
claims.
"""
function test_latency(
        pkg::Symbol; calls::AbstractVector{<:AbstractString} = String[],
        max_load_ms = nothing, max_first_call_ms = nothing, precompile::Bool = true
    )
    r = StrictMode.latency_report(pkg; calls, precompile)
    over = String[]
    isnothing(max_load_ms) || r.load_ms <= max_load_ms ||
        push!(over, "load took $(round(r.load_ms; digits = 1)) ms against a budget of $max_load_ms ms")
    if !isnothing(max_first_call_ms)
        for (call, ms) in r.first_call_ms
            ms <= max_first_call_ms ||
                push!(over, "the first `$call` took $(round(ms; digits = 1)) ms against a budget of $max_first_call_ms ms")
        end
    end
    isempty(over) && return r
    throw(
        StrictMode.StrictViolation(
            :test_latency, String(pkg),
            join(over, "; ") * ".\n  Measured in a fresh process on this machine: load time and " *
                "first-call time are properties of a cold start, so these numbers do not transfer " *
                "between hosts. A budget belongs to the host that set it.\n  " *
                (
                r.precompiled ? "The precompile cache was built first, so the load time is a " *
                    "warm-cache load." :
                    "The precompile cache was NOT built by this call, so the load time may include " *
                    "building it — work a second run would not repeat."
            )
        )
    )
end

"""
    test_no_unsafe(mod::Module; only = nothing, exempt = (), allow = ()) -> Vector{StrictFinding}

Prove that no method in `mod` leaves Julia's safety guarantees, and throw a
`StrictMode.StrictViolation` naming every one that does.

The Julia form of Rust's `#![forbid(unsafe_code)]`. A module that must stay inside the language
declares it by calling this. Julia cannot enforce it on its own, since a `ccall` and an
`unsafe_load` are ordinary calls that any module may make.

`ccall`, `@cfunction`, `pointer`, any function whose name begins with `unsafe_`, the pointer
intrinsics, `llvmcall`, `cglobal`, the C allocator and a pointer made from an integer are what it
looks for, in any spelling: a plain call, a broadcast, a `map`, a splat, a keyword call or a local
alias. [`StrictMode.unsafe_report`](@ref) has the full table.

`allow` names the constructs this module may use anyway, so a deliberate, reviewed escape is
recorded where the policy is written rather than silently tolerated:

```julia
test_no_unsafe(MyKernels)                            # no escapes at all
test_no_unsafe(MyKernels; allow = (:unsafe_load,))   # one reviewed read, everything else held
```

`@inbounds` is covered too, as `:inbounds`, and `allow = (:inbounds,)` excuses it where the in-range
property is proved and tested. See [`StrictMode.unsafe_report`](@ref), the scan this gates, for the
rest of the scope.
"""
function test_no_unsafe(mod::Module; only = nothing, exempt = (), allow = ())
    fs = StrictMode.unsafe_report(mod; only, exempt, allow)
    isempty(fs) && return fs
    msg = sprint(io -> StrictMode.format_findings(io, fs; format = :text))
    throw(StrictMode.StrictViolation(:test_no_unsafe, string(nameof(mod)), msg))
end

# --- the specialization baseline ------------------------------------------------------------

# A compiled-specialization count has no absolute threshold: twenty specializations of a numeric
# kernel is Julia producing fast code, and `StrictMode.specialization_report` is `:info` for exactly
# that reason. What CAN be gated is the change, so this one needs something to compare against.
#
# The baseline is keyed on `(Julia version, workload)`. The version, because inference and codegen
# decide how many specializations exist and that moves between releases. The workload, because
# `_specializations` reports what has compiled in THIS session: the same call placed after a full
# suite sees more than one placed at the top of it, so two placements are two baselines and must
# never be compared with each other.
const _SpecBaseline = Dict{Tuple{String, String}, Dict{String, Int}}

function _read_spec_baseline(path::AbstractString)
    isfile(path) || return _SpecBaseline()
    store = try
        deserialize(path)
    catch err
        throw(
            ArgumentError(
                "could not read the specialization baseline at `$path`: " *
                    "$(sprint(showerror, err)). It is written by `Serialization`; delete it and " *
                    "let the next run record a new one."
            )
        )
    end
    store isa _SpecBaseline ||
        throw(ArgumentError("`$path` holds a $(typeof(store)), not a specialization baseline."))
    return store
end

function _write_spec_baseline(path::AbstractString, store::_SpecBaseline)
    dir = dirname(path)
    isempty(dir) || isdir(dir) || mkpath(dir)
    serialize(path, store)
    return nothing
end

"""
    test_specializations(mod::Module; baseline, workload, tolerance = 0, update = false,
                         only = nothing, exempt = ()) -> Dict{String, Int}

Compare every method of `mod` against a recorded compiled-specialization count, and throw a
`StrictMode.StrictViolation` naming each one that carries more than it did. Returns the counts this
run measured, keyed by signature.

A count on its own says nothing: a kernel specialized on twenty element types is Julia working as
intended, which is why [`StrictMode.specialization_report`](@ref) is `:info` and has no absolute
limit to offer. What this gates is the **change** — a method that compiled twelve specializations
last release and forty now is a compile-time regression someone can act on.

**The baseline records itself on first run and nothing can fail.** With no entry for this
`(Julia version, workload)` pair the counts are written and the call returns, so adding this to a
suite is never a failure on the first run. A later run on the same version and workload is compared.

```julia
test_specializations(MyPkg; baseline = "spec.bin", workload = "full-suite")
test_specializations(MyPkg; baseline = "spec.bin", workload = "full-suite", tolerance = 4)
test_specializations(MyPkg; baseline = "spec.bin", workload = "full-suite", update = true)
```

`workload` names what ran before this call, and it is part of the baseline key. Counts come from
what has compiled **in this session**, so the same call placed at the end of a suite sees more than
one placed at the start: those are two different measurements and must not be compared. Name them
apart, and keep each call at the same point in the run.

`tolerance` allows that much growth before failing. `update = true` records this run instead of
comparing, for growth that is intended. A method the baseline does not name is recorded by the next
`update`, never failed — a new method has nothing to regress against.

The baseline is a machine artifact written with `Serialization`, so it is readable only by a Julia
that can deserialize it. Keep one per host that gates, the way a benchmark baseline is kept.
"""
function test_specializations(
        mod::Module; baseline::AbstractString, workload::AbstractString,
        tolerance::Int = 0, update::Bool = false, only = nothing, exempt = ()
    )
    tolerance >= 0 || throw(
        ArgumentError("test_specializations: tolerance must not be negative, got $tolerance")
    )
    isempty(workload) && throw(
        ArgumentError(
            "test_specializations: `workload` must name what ran before this call. It is part of " *
                "the baseline key, because a count depends on what has compiled in this session."
        )
    )
    methods_, _ = StrictMode.module_methods(mod; only, exempt)
    counts = Dict{String, Int}(
        string(m.sig) => length(StrictMode._specializations(m)) for m in methods_
    )
    key = (string(VERSION), workload)
    store = _read_spec_baseline(baseline)
    before = get(store, key, nothing)
    if update || isnothing(before)
        store[key] = counts
        _write_spec_baseline(baseline, store)
        isnothing(before) && @info "StrictModeTest.test_specializations: `$baseline` has no " *
            "baseline for Julia $(VERSION) / workload `$workload`, so this run was recorded as " *
            "one. A later run on the same version and workload is compared against it."
        return counts
    end
    over = String[]
    for (sig, n) in counts
        was = get(before, sig, nothing)
        # A method the baseline does not name has nothing to regress against.
        isnothing(was) && continue
        n > was + tolerance || continue
        push!(over, "`$sig` carries $n compiled specializations against $was in the baseline")
    end
    isempty(over) && return counts
    throw(
        StrictMode.StrictViolation(
            :test_specializations, string(nameof(mod)),
            join(sort!(over), ";\n  ") * ".\n  A specialization count is compile-time pressure, " *
                "not a defect — many of them is how Julia produces fast code. What this gates is " *
                "the growth, so read it as \"this method got more expensive to compile\" and " *
                "decide whether that is intended.\n  Counts come from what compiled in THIS " *
                "session, measured for Julia $(VERSION) / workload `$workload`. A call that " *
                "reaches this point after different work has run is measuring a different " *
                "workload and needs its own name.\n  Record the new numbers with `update = true` " *
                "if the growth is wanted; split the part that must specialize from the part that " *
                "does not if it is not."
        )
    )
end

"""
    StrictModeTest.AllocEntry

One entry point of a function and what an allocation proof says about it. `kind` is `:positional`
or `:keyword`. `status` is one of:

- `:pass` — the proof found no allocation.
- `:fail` — the proof failed: it found an allocation, or AllocCheck could not analyze the
  signature; `reason` says which.
- `:unproven` — nothing was proved: the signature names no concrete types to run a proof against,
  which is always so for a `:keyword` entry; it always throws, so no returning path was checked; or
  the proof raised before producing a verdict.
- `:info` — the proof's exempt-only result (SM0018) accepted with `allow_exempt = true`: every
  allocation is inside a function exempted from `:noalloc`, and `reason` names them. Not a pass.
"""
struct AllocEntry
    sig::Any
    kind::Symbol
    status::Symbol
    reason::String
end

"""
    StrictModeTest.AllocEntryReport

Every entry point of one function, with the allocation proof's verdict for each.

See [`alloc_entry_report`](@ref StrictModeTest.alloc_entry_report).
"""
struct AllocEntryReport
    target::String
    entries::Vector{AllocEntry}
end

# A keyword call dispatches through `Core.kwcall`, and that method is a separate entry point with
# its own compiled code: proving `f(args...)` says nothing about it. `Core.Typeof` rather than
# `typeof`: for a type, `typeof` is `DataType`, which matches the keyword constructor of every type
# in the session.
_kw_entries(@nospecialize(f)) =
    collect(methods(Core.kwcall, Tuple{Any, Core.Typeof(f), Vararg{Any}}))

function _positional_entry(@nospecialize(f), sig; allow_exempt::Bool = false)
    Base.isdispatchtuple(sig) || return AllocEntry(
        sig, :positional, :unproven,
        "the signature names no concrete argument types — prove it at the types a caller uses " *
            "with `test_signatures([(f, (T1, T2, …))])` or `@test_noalloc f(args…)`"
    )
    fs = try
        _proof_findings(f, Tuple(sig.parameters[2:end]), (:noalloc,); allow_exempt)
    catch e
        return AllocEntry(
            sig, :positional, :unproven, "the proof could not run: " * sprint(showerror, e)
        )
    end
    failed = filter(StrictMode._failed, fs)
    isempty(failed) || return AllocEntry(sig, :positional, :fail, join((f.reason for f in failed), "; "))
    # A note is not a pass: a signature that always throws had nothing on a returning path checked,
    # and an accepted exempt-only result still allocates inside the exempt functions.
    notes = filter(x -> x.status !== :pass, fs)
    isempty(notes) && return AllocEntry(sig, :positional, :pass, "")
    status = any(x -> x.code === :SM0208, notes) ? :unproven : :info
    return AllocEntry(sig, :positional, status, join((x.reason for x in notes), "; "))
end

# A `Core.kwcall` method declares its keyword `NamedTuple` abstract, so its signature is never one
# a proof can run against: the keyword types have to be named at a call.
_keyword_entry(sig) = AllocEntry(
    sig, :keyword, :unproven,
    "the keyword NamedTuple is abstract — name the keyword types with " *
        "`@test_noalloc f(…; k = v)`, or measure the call with `@test_allocated_zero`"
)

"""
    StrictModeTest.alloc_entry_report(f) -> AllocEntryReport

Every entry point of `f` — each of its own methods, and each `Core.kwcall` method that reaches it —
with what the allocation proof says about each.

A proof of `f(args...)` covers the positional method only. The keyword method is separate compiled
code reached by `f(args...; k = v)`, and it is always listed as `:unproven`: its signature declares
the keyword `NamedTuple` abstract, so a proof needs a call that names the keyword types. Listing it
is what shows a suite that proved only the positional method that the keyword path is uncovered.

```julia
r = StrictModeTest.alloc_entry_report(gemm!)
filter(e -> e.status === :unproven, r.entries)
```
"""
function alloc_entry_report(@nospecialize(f); allow_exempt::Bool = false)
    entries = AllocEntry[]
    for m in methods(f)
        push!(entries, _positional_entry(f, m.sig; allow_exempt))
    end
    for m in _kw_entries(f)
        push!(entries, _keyword_entry(m.sig))
    end
    target = string(f isa Function || f isa Type ? f : typeof(f))
    return AllocEntryReport(target, entries)
end

function Base.show(io::IO, r::AllocEntryReport)
    printstyled(io, "AllocEntryReport"; bold = true)
    print(io, ": ", r.target, " — ", length(r.entries), " entry point(s)\n")
    for e in r.entries
        color = e.status === :pass ? :green : (e.status === :fail ? :red : :yellow)
        mark = e.status === :pass ? "✓" : (e.status === :fail ? "✗" : "?")
        printstyled(io, "  ", mark, " ", rpad(string(e.status), 9); color)
        print(io, e.kind === :keyword ? "keyword   " : "positional ", e.sig, "\n")
        isempty(e.reason) || print(io, "      ", e.reason, "\n")
    end
    return nothing
end

"""
    StrictModeTest.test_threaded_speedup(pkg::Symbol, call; efficiency = nothing,
                                         max_slowdown = 1.5, kwargs...) -> ThreadedSpeedupReport

Fail when threading makes `call` slower than its bounds allow, measured in fresh processes by
[`StrictMode.threaded_speedup_report`](@ref), which takes the remaining keywords (`setup`, `cpus`,
`threads`, `workers`, `repeats`).

Two bounds, both on the ratio of the threaded time to the one-thread time taken on the same
machine minutes apart:

- `max_slowdown` — the threaded run may take at most this many times the serial one. On by
  default at `1.5`: a threaded kernel that loses to its own serial path by half is a defect on
  any machine. Pass `nothing` to drop it.
- `efficiency` — the threaded run must reach this fraction of perfect scaling over its workers,
  `threaded <= serial / (efficiency * workers)`. Off by default, because how well a kernel scales
  depends on the cores, the SMT layout and what else the host is doing; a number that holds on
  one machine fails on another. Set it only in a suite that runs on a host you control.

The efficiency bound needs the processes confined to `cpus` CPUs. Where `taskset` is not available
it is not applied, a warning says so, and only `max_slowdown` gates.

```julia
test_threaded_speedup(:MyPkg, "MyPkg.lu!(copy(A))"; setup = "A = rand(1024, 1024)")
test_threaded_speedup(:MyPkg, "MyPkg.lu!(copy(A))"; setup = "A = rand(1024, 1024)", efficiency = 0.4)
```
"""
function test_threaded_speedup(
        pkg::Symbol, call::AbstractString; efficiency = nothing, max_slowdown = 1.5, kwargs...
    )
    isnothing(efficiency) && isnothing(max_slowdown) && throw(
        ArgumentError("test_threaded_speedup: no bound was given, so there is nothing to gate on")
    )
    r = StrictMode.threaded_speedup_report(pkg, call; kwargs...)
    ratio = r.threaded_ms / r.serial_ms
    shown = round(ratio; digits = 2)
    over = String[]
    isnothing(max_slowdown) || ratio <= max_slowdown || push!(
        over, "the threaded run took $(shown)x the serial time against a limit of $(max_slowdown)x"
    )
    if !isnothing(efficiency)
        if r.pinned
            bound = 1 / (efficiency * r.workers)
            ratio <= bound || push!(
                over,
                "the threaded run took $(shown)x the serial time, and an efficiency of " *
                    "$efficiency over $(r.workers) worker(s) allows $(round(bound; digits = 2))x"
            )
        else
            @warn "test_threaded_speedup: `taskset` is not available, so the processes were not " *
                "confined and the efficiency bound of $efficiency was not applied. Only " *
                "`max_slowdown` gated this run."
        end
    end
    isempty(over) && return r
    throw(
        StrictMode.StrictViolation(
            :test_threaded_speedup, String(call),
            join(over, "; ") * ".\n  1 thread: $(round(r.serial_ms; digits = 3)) ms; " *
                "$(r.nthreads) threads: $(round(r.threaded_ms; digits = 3)) ms, " *
                (r.pinned ? "both confined to $(r.cpus) CPU(s)" : "not confined to a CPU set") *
                ".\n  Measured in fresh processes on this machine. The ratio moves with the " *
                "host's cores and load, so a bound belongs to the host that set it."
        )
    )
end

"""
    StrictModeTest.test_threadcount_invariant(pkg::Symbol, call; witness, setup = "",
                                              threads = 1:Sys.CPU_THREADS)

Fail unless `call` returns the same bits at every thread count in `threads` **and** `witness`
reports that the threaded path ran at each count above one. See
[`StrictMode.threadcount_invariant_report`](@ref) for how the result is compared.

`witness` is required. Identical results at every thread count are exactly what a call that
never threads produces, and whether a package's threaded path ran can only be observed from
inside the package — so this takes that observation as code, such as
`"MyPkg.pool_jobs() > 0"`, and does not run without it.

```julia
test_threadcount_invariant(
    :MyPkg, "MyPkg.mul(A, B)";
    setup = "using Random; Random.seed!(1); A = rand(300, 300); B = rand(300, 300)",
    witness = "MyPkg.pool_jobs() > 0", threads = 1:4,
)
```
"""
function test_threadcount_invariant(
        pkg::Symbol, call::AbstractString; witness::Union{Nothing, AbstractString} = nothing,
        kwargs...
    )
    isnothing(witness) && throw(
        ArgumentError(
            "test_threadcount_invariant: pass `witness`, code that returns `true` when the " *
                "threaded path ran. Without it a call that never threads passes at every " *
                "thread count."
        )
    )
    r = StrictMode.threadcount_invariant_report(pkg, call; witness, kwargs...)
    why = String[]
    for i in eachindex(r.threads)
        r.identical[i] || push!(
            why, "at -t $(r.threads[i]) the result differs from the one at -t $(r.threads[1]), " *
                "first at byte $(r.first_difference[i])"
        )
        r.nthreads[i] > 1 && !r.witnessed[i] &&
            push!(why, "at -t $(r.threads[i]) the witness reported that the threaded path did not run")
    end
    any(>(1), r.nthreads) ||
        push!(why, "no process had more than one thread, so the threaded path was never asked for")
    isempty(why) && return r
    throw(StrictMode.StrictViolation(:test_threadcount_invariant, String(call), join(why, "; ") * "."))
end

"""
    StrictModeTest.test_route_parity(f => types, g => types; mod = nothing, stop = ()) -> RouteParity

Fail unless the two calls are shown to take the same route: both call graphs were read in full,
neither is empty, and they reach the same functions. See [`StrictMode.route_parity`](@ref) for how
the graphs are read and what `mod` and `stop` do.

A graph that could not be read in full fails as well as one that differs. Two entries are not
shown to agree by a comparison that left part of either unread, and an entry whose graph came back
empty would otherwise agree with anything.

```julia
T = (Matrix{Float64}, Matrix{Float64}, Matrix{Float64})
test_route_parity(MyBLAS.gemm! => T, MyBLAS.gemm_cabi! => T; mod = MyBLAS)
```
"""
function test_route_parity(a::Pair, b::Pair; kwargs...)
    p = StrictMode.route_parity(a, b; kwargs...)
    StrictMode.status(p) === :agree && return p
    throw(
        StrictMode.StrictViolation(
            :test_route_parity, p.a.target * " against " * p.b.target, StrictMode._parity_reason(p)
        )
    )
end

"""
    test_waits_yield(f, types) -> StrictMode.SpinWaitReport

Prove that every task the call `f(types...)` spawns waits by **yielding**, and throw a
`StrictMode.StrictViolation` naming each one that does not.

A worker that waits by spinning on `pause()`, a safepoint or a fence, and never yields, keeps its
thread from running any other task for as long as it spins: every task queued there waits behind
it. That is a stall no allocation or type guarantee can see, and it is read from the same task
bodies [`StrictMode.spin_wait_report`](@ref) reads.

A task that yields while it waits passes this gate even when it never blocks; `spin_wait_report`
still reports that it keeps a CPU busy. The gate fails on what it could not judge: a task it could
not read, a bound task (`@async`, `Task`), a call inside a task it did not follow, and a call that
spawns no task it could find.

It recognizes a wait by the operation the loop polls with — `yield`, a safepoint, `pause()`, a
fence — so a loop with no such operation, such as `while !flag; end`, is not recognized as a wait.

```julia
test_waits_yield(gemm!, (Matrix{Float64}, Matrix{Float64}, Matrix{Float64}))
```
"""
function test_waits_yield(@nospecialize(f), @nospecialize(types::Tuple))
    r = StrictMode.spin_wait_report(f, types)
    bad = String[]
    for x in r.findings
        :yield in x.polls && continue
        push!(
            bad, "`$(x.target)` waits by $(join(x.polls, ", ")) and never yields, so no other task " *
                "can run on its thread while it waits"
        )
    end
    isempty(r.unread) || push!(
        bad, "spawned task(s) could not be read, so how they wait is not established: " *
            join(r.unread, ", ")
    )
    # Each of these is a part of the call the scan did not judge, and a gate does not pass on what it
    # did not check.
    r.bound > 0 && push!(
        bad, "$(r.bound) bound task(s) (`@async`, `Task`) were not judged; a bound task that spins " *
            "holds the thread it is bound to"
    )
    r.unfollowed > 0 && push!(bad, "$(r.unfollowed) call(s) inside the tasks were not followed")
    (r.tasks == 0 && r.bound == 0 && isempty(r.unread)) &&
        push!(bad, "the call spawns no task the scan could find, so nothing was proven")
    isempty(bad) && return r
    target = string(f) * StrictMode._sig_string(types)
    throw(StrictMode.StrictViolation(:waits_yield, target, join(bad, "\n  ")))
end

"""
    test_history_invariant(f, args...; movers) -> StrictMode.HistoryReport

Prove that `f(args...)` gives the same bits after the calls in `movers` have run in the same
process, and throw a `StrictMode.StrictViolation` when it does not. See
[`StrictMode.history_report`](@ref), which this runs.

`movers` must not be empty: with nothing run in between, the two calls are the same call and the
comparison proves nothing.

```julia
test_history_invariant(gemm!, C, A, B; movers = (() -> gemm!(Cbig, Abig, Bbig),))
```
"""
function test_history_invariant(@nospecialize(f), args...; movers)
    isempty(movers) && throw(
        ArgumentError(
            "test_history_invariant: `movers` is empty, so nothing ran between the two calls and the " *
                "comparison would prove nothing; pass the calls that move the package's state"
        )
    )
    r = StrictMode.history_report(f, args...; movers)
    r.status === :same && return r
    msg = r.status === :different ?
        "the result is not the same bits after $(r.movers) state mover(s) ran in this process (first " *
        "difference at $(r.difference)): it depends on what ran before it" :
        r.status === :first_call ?
        "the first call gives different bits from the three calls after it, which agree (at " *
        "$(r.difference)): consistent with state left behind by the first call that changes the result" :
        "two calls with nothing between them already differ (at $(r.difference)), so whether the " *
        "result depends on what ran before it cannot be established"
    throw(StrictMode.StrictViolation(:history, r.target, msg))
end
