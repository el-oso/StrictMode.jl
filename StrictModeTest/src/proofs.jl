# The proofs: AllocCheck's all-paths no-allocation analysis, JET's optimization analysis, and
# TrimCheck's `juliac --trim=safe` verifier, run over a concrete `(f, types)` signature.
#
# These are called directly, not through a seam. A guarantee here can never find its backend
# missing, because the package that defines it is the package that depends on it.

using StrictMode: StrictFinding, StrictViolation

# Every verdict reached in this package is a proof, so it is built through these two rather than
# StrictMode's constructors directly: the `tier` a reader needs in order to tell a proof from the
# reporting engine's guess is then impossible to omit at a new call site.
_mkproof(args...; kwargs...) = StrictMode._mkfinding(args...; tier = :proof, kwargs...)
_unproven(args...; kwargs...) = StrictMode._unevaluated(args...; tier = :proof, kwargs...)

"""
    AnalysisError <: Exception

Thrown when a backend call (JET's `report_opt`, in practice) fails outright while compiling
`(f, types)`, instead of returning a report. The usual cause: full inference visits every branch of
a method regardless of which one is reachable at runtime for a given call, so a runtime-dead branch
that reaches a `@generated` function whose generator throws (an `@assert` at generation time, rather
than a guarded `return :(throw(...))`) fails analysis even though the function itself runs fine.
Carries the checked target, the analyzed signature, and the original error, so the failure names
what was being analyzed instead of surfacing as a bare exception raised from inside the backend.
"""
struct AnalysisError <: Exception
    target::String
    signature::String
    original::Any
end

function Base.showerror(io::IO, e::AnalysisError)
    print(
        io,
        "StrictModeTest: the analysis backend failed while compiling `", e.target,
        "` (signature ", e.signature, "). Full inference visits every branch of a method regardless ",
        "of runtime reachability, so a runtime-dead branch that reaches a `@generated` function whose ",
        "generator throws (e.g. `@assert` at generation time) fails analysis here even though the call ",
        "runs fine. Fix the generator to always succeed: guard it and return a throw expression instead ",
        "of asserting — `cond || return :(throw(AssertionError(\"...\")))`. Original error: "
    )
    showerror(io, e.original)
    return nothing
end

# ── AllocCheck ───────────────────────────────────────────────────────────────────────────────────

# Whether an allocation barrier recognized by StrictMode's IR scan
# (`Base.OncePerProcess`/`OncePerThread`, or a function passed to `register_alloc_barrier!`) exempts
# a call from AllocCheck's all-paths proof.
const _IGNORE_BARRIER = Ref(true)

"""
    ignore_barrier() -> Bool

Whether `@test_noalloc`/`@test_noboxing` exempt a call recognized as routing through a one-time-init
allocation barrier (`Base.OncePerProcess`/`OncePerThread`, or a function registered via
`StrictMode.register_alloc_barrier!`) from AllocCheck's all-paths proof. Default `true`.
See [`set_ignore_barrier!`](@ref).
"""
ignore_barrier() = _IGNORE_BARRIER[]

"""
    set_ignore_barrier!(b::Bool)

Set whether a detected allocation barrier is exempt from AllocCheck's all-paths proof. `false`
disables the exemption — a barrier-containing call then reds `@test_noalloc` exactly as it would
without this feature, since AllocCheck's static proof sees the barrier's one-time allocation and
has no way to know it is amortized. Clears StrictMode's findings cache.
"""
function set_ignore_barrier!(b::Bool)
    _IGNORE_BARRIER[] = b
    StrictMode.clear_cache!()
    return b
end

# StrictMode's own guard frame, excluded from both proofs.
#
# A `@strict` call site keeps its checks on a cold branch that runs once per signature, so the
# guarded function allocates nothing at runtime — but the branch is still part of the compiled call
# graph, and AllocCheck and JET both analyze every path regardless of how often it is taken. Left
# in, the guard makes `@test_noalloc`/`@test_typestable` fail on the enclosing function, which is
# the measurement issue #29 is about: a package that guards its hot kernels could not then prove
# those kernels clean. The branch reaches the check through a dynamic call in
# `StrictMode._guard_call`, so neither proof compiles the check itself; JET's report of that call
# is dropped with the frame (`_is_guard_report`), and AllocCheck's sites in it are kept and named
# (`_in_guard_call`).
#
# Excluding it is sound in the direction that matters. `_strict_scan` is StrictMode's own analysis
# code, not the user's, and it cannot run in a build with checks off — the whole branch is erased by
# `_gate`. What it can never do is hide a finding in the guarded kernel: these filters drop
# instances attributed to the guard frame, not to the call it guards.
const _GUARD_FRAME = :_strict_scan

# An AllocCheck instance either names its frame directly or carries the backtrace it was found in;
# both are read, so the filter does not depend on which shape a given AllocCheck release reports.
# Only the guard's own allocations pass through `_strict_scan` — the guarded kernel's do not — so
# this cannot hide a finding in the kernel.
function _is_guard_alloc(@nospecialize(inst))
    hasproperty(inst, :fname) && Symbol(getproperty(inst, :fname)) === _GUARD_FRAME && return true
    hasproperty(inst, :backtrace) || return false
    for fr in inst.backtrace
        fr isa Base.StackTraces.StackFrame || continue
        fr.func === _GUARD_FRAME && return true
        li = fr.linfo
        li isa Core.MethodInstance && li.def isa Method && li.def.name === _GUARD_FRAME &&
            return true
    end
    return false
end

function _is_guard_report(@nospecialize(rep))
    hasproperty(rep, :vst) || return false
    return any(rep.vst) do fr
        mi = fr.linfo
        mi isa Core.MethodInstance || return false
        d = mi.def
        return d isa Method && (d.name === _GUARD_FRAME || _is_guard_call(d))
    end
end

# `StrictMode._guard_call`, through which a guard calls its check: its one dynamic call is the
# guard's, whatever it reaches.
_is_guard_call(d::Method) = d.module === StrictMode && d.name === :_guard_call

# AllocCheck takes a function value. A callable object known by its type alone is checked through
# `StrictMode._call_through`, which takes the callable as its first argument and makes the call:
# AllocCheck compiles the whole call graph, so the callable's sites are found whether or not it is
# inlined into the wrapper, and the wrapper only forwards its arguments and result. A signature with
# no method raises here, as `check_allocs` does, rather than proving the wrapper's `MethodError`.
#
# `caught` says the native walk read a statement that a caught throw reaches on a call that returns:
# one in a try region whose handler can return, or one of that handler (`_caught_mask`). AllocCheck's
# `ignore_throw` drops the sites of both, as it drops every site that leads to a throw or follows a
# catch, so the code is then checked a second time without it and those extra sites are kept
# (`_caught_sites`).
#
# A specialization reached only through `invoke` (`StrictMode._Spec`) is checked through
# `StrictMode._invoke_through` (`_backend_call`), the same way: the wrapper runs exactly that
# specialization, and its frame is dropped from every backtrace.
function _check_allocs(@nospecialize(f), @nospecialize(types); caught::Bool = false)
    ignore_throw = StrictMode.ignore_throw()
    callable = f isa StrictMode._Callable
    callable && StrictMode._which(f, types)
    wrapped = callable || f isa StrictMode._Spec
    target, tt = callable ? (StrictMode._call_through, (StrictMode._ftype(f), types...)) : _backend_call(f, types)
    allocs = AllocCheck.check_allocs(target, tt; ignore_throw)
    if ignore_throw && caught
        every = AllocCheck.check_allocs(target, tt; ignore_throw = false)
        append!(allocs, _caught_sites(filter(a -> !(a in allocs), every)))
    end
    # The wrapper's frame is not the callable's code, and every reader of a backtrace asks whose code a
    # site is in.
    if wrapped
        for a in allocs
            hasproperty(a, :backtrace) && filter!(fr -> !_is_call_through(fr), a.backtrace)
        end
    end
    return allocs
end

# Runtime calls that allocate only the exception they throw. Without `ignore_throw`, AllocCheck
# reports one at every call, the calls that succeed included; the scan reads them as not allocating.
const _THROW_ONLY_RUNTIME = (
    "jl_f_ifelse", "jl_f_typeassert", "jl_f_is", "jl_f_throw", "jl_f__svec_ref",
    "jl_genericmemory_copyto",
)

# Of the sites AllocCheck reports only without `ignore_throw`, those on a path that returns normally
# because a catch handles its throw, in the try body, in a callee it calls, or in the handler. A
# backtrace is read as one group of frames per compiled body, innermost first, each ending at the
# body's own frame, and judged outermost first (`_location_class`): a group on an error path of its
# body drops the site; one in a try region whose handler can return keeps it, since what the groups
# inside it do on their own error paths ends in that handler; one on a handler statement keeps it only
# when no group inside lies on an error path, since a throw raised in a callee the handler calls is not
# caught by that try. A backtrace AllocCheck cut short ("multiple call sites") is judged on the groups
# it has. A try region whose handler returns only for a type `T` (`StrictMode._handler_filter`) keeps
# the site only when no group inside it is on the way to a throw known to be no `T`: each group inside
# is judged in that caught context (`StrictMode._join_caught`), as the scan reads those bodies.
# A site on the way to a bounds check's `BoundsError` (`_bounds_error_site`) that no enclosing handler
# returns for is on an error path.
function _caught_sites(extra)
    interp = Base.Compiler.NativeInterpreter(Base.get_world_counter())
    bodies = Dict{Tuple{Core.MethodInstance, Any}, Any}()
    return filter(extra) do a
        a isa AllocCheck.AllocatingRuntimeCall && a.name in _THROW_ONLY_RUNTIME && return false
        hasproperty(a, :backtrace) || return false
        groups = Tuple{Core.MethodInstance, Vector{Base.StackTraces.StackFrame}, Any}[]
        group = Base.StackTraces.StackFrame[]
        callee = nothing
        for fr in a.backtrace
            push!(group, fr)
            fr.inlined && continue
            mi = _frame_mi(fr)
            mi isa Core.MethodInstance || break
            push!(groups, (mi, copy(group), callee))
            empty!(group)
            callee = mi
        end
        ctx = false
        inhandler = false
        inner = nothing
        built = a isa AllocCheck.AllocationSite && a.type isa Type ? a.type : nothing
        for (k, (mi, g, c)) in Iterators.reverse(pairs(groups))
            inner = get!(() -> _body_classes(interp, mi, ctx), bodies, (mi, ctx))
            cls, rctx = _location_class(inner, g, c, k == 1 ? built : nothing)
            cls === :dead && return false
            if cls === :caught
                ctx = StrictMode._join_caught(ctx, rctx)
                ctx === true && return true
            elseif ctx === false
                inhandler |= cls === :handler
            end
        end
        ctx isa Type && !(BoundsError <: ctx) && !isempty(groups) &&
            _bounds_error_site(a, extra, inner, groups[1][2]) && return false
        return ctx !== false || inhandler
    end
end

# Whether site `a` is a bounds check's throw of a `BoundsError`: a call to a `jl_bounds_error*` runtime
# function, which throws one, or the box of the memory reference such a call reports, at the same
# frames as the call, where the innermost body's statements (`group` locates them, as
# `_location_class` does) are all ones that allocate nothing on their way to returning normally and
# one is a `memoryrefnew` of a reference of the box's type. Codegen emits that check for a `memoryrefnew`
# (on Julia 1.12 under `--check-bounds=yes` also for one the IR marks unchecked) and boxes the reference
# only to pass it to the call.
_bounds_error_call(@nospecialize(a)) =
    a isa AllocCheck.AllocatingRuntimeCall && startswith(a.name, "jl_bounds_error")

function _bounds_error_site(@nospecialize(a), extra, body, group::Vector{Base.StackTraces.StackFrame})
    _bounds_error_call(a) && return true
    (a isa AllocCheck.AllocationSite && a.type isa Type && a.type <: Core.GenericMemoryRef) || return false
    same(x, y) = length(x) == length(y) && all(
        ((p, q),) -> p.func === q.func && p.file === q.file && p.line == q.line && p.inlined == q.inlined,
        zip(x, y)
    )
    any(b -> _bounds_error_call(b) && same(b.backtrace, a.backtrace), extra) || return false
    isnothing(body) && return false
    refs, stacks = body[5], body[2]
    want = [fr.line for fr in Iterators.reverse(group)]
    at = [length(s) for s in stacks]
    best = maximum((k for (k, s) in zip(at, stacks) if 0 < k <= length(want) && s == view(want, 1:k)); init = 0)
    best > 0 || return false
    matched = [i for i in eachindex(stacks) if at[i] == best && stacks[i] == view(want, 1:best)]
    return all(i -> refs[i] !== nothing, matched) && any(i -> refs[i] === a.type, matched)
end

# Each statement of `mi`'s optimized body as `:dead` (an error path under `ignore_throw()`),
# `:caught` (in a try region whose handler can return), `:handler` (a statement of a handler, reached
# only through a catch, that is not an error path) or `:live`, with the line of each inlining level,
# outermost first, the specialization of each `:invoke`, and the caught context a `:caught` statement's
# handlers give (`StrictMode._caught_contexts`). `ctx` is the caught context the body runs in.
# `nothing` for a body that cannot be read.
function _body_classes(interp, mi::Core.MethodInstance, ctx = false)
    src = try
        Base.Compiler.typeinf_code(interp, mi, true)
    catch
        nothing
    end
    src isa Core.CodeInfo || return nothing
    dead = StrictMode._deadend_mask(src.code, src, mi.specTypes, ctx)
    region = StrictMode._caught_contexts(src.code, dead, src)
    handler = isnothing(StrictMode._try_handlers(src.code)) ? falses(length(src.code)) : _catch_only_mask(src.code)
    classes = [
        dead[i] ? :dead : !isnothing(region) && region[i] !== false ? :caught : handler[i] ? :handler : :live
            for i in eachindex(src.code)
    ]
    ctxs = isnothing(region) ? Any[false for _ in eachindex(src.code)] : region
    invoked = [
        Meta.isexpr(st, :invoke) ? StrictMode._invoke_mi(st.args[1]) : nothing for st in src.code
    ]
    refs = Any[_quiet_stmt(src, mi.specTypes, st) for st in src.code]
    news = Any[_built_type(src, i) for i in eachindex(src.code)]
    return (classes, [_stmt_lines(src, mi, i) for i in eachindex(src.code)], invoked, ctxs, refs, news)
end

# The type statement `i` builds: a `:new`, or a call of the type's own constructor (AllocCheck reports
# an allocation in a constructor it compiles inline at the caller's line). `nothing` otherwise.
function _built_type(src::Core.CodeInfo, i::Int)
    st = src.code[i]
    T = StrictMode._unwrap_lattice(src.ssavaluetypes[i])
    Meta.isexpr(st, :new) && return T
    Meta.isexpr(st, :invoke) && length(st.args) >= 2 || return nothing
    c = st.args[2]
    return (c isa Type ? c : StrictMode._static_callee(src, c)) === T ? T : nothing
end

# For a statement that allocates nothing on its way to returning normally: the reference type of a
# `memoryrefnew`, `true` for the other such statements (`nothing`, a `boundscheck`, a branch, a
# `getfield` or a `memoryrefget`). `nothing` for any other statement.
function _quiet_stmt(src::Core.CodeInfo, @nospecialize(sig), @nospecialize(st))
    (st === nothing || st isa Core.GotoNode || st isa Core.GotoIfNot || Meta.isexpr(st, :boundscheck)) && return true
    Meta.isexpr(st, :call) || return nothing
    c = StrictMode._static_callee(src, st.args[1])
    c === Core.memoryrefnew && length(st.args) >= 2 &&
        return StrictMode._unwrap_lattice(StrictMode._stmt_arg_type(src, sig, st.args[2]))
    return c === Core.getfield || c === Core.memoryrefget ? true : nothing
end

# The live statements a caught throw reaches: those in a try region whose handler can return, and
# those of a handler itself (`_catch_only_mask`) that are not an error path.
function _caught_mask(code::Vector{Any}, dead::BitVector)
    handlers = StrictMode._try_handlers(code)
    isnothing(handlers) && return falses(length(code))
    mask = _catch_only_mask(code) .& .!dead
    for i in eachindex(code)
        mask[i] |= !dead[i] && any(d -> !dead[d], handlers[i])
    end
    return mask
end

# The line of statement `pc` at each inlining level, outermost first, read as codegen reads it for
# the debug locations AllocCheck's frames come from (a line can index a further line table).
_stmt_lines(src::Core.CodeInfo, mi::Core.MethodInstance, pc::Int) =
    Int[Int(l.line) for l in Base.IRShow.buildLineInfoNode(src.debuginfo, mi, pc)]

# The class of the statements an AllocCheck frame group points at: those whose inlining lines are
# the longest prefix of the group's, outermost first. Among equally long matches `:caught` wins, then
# `:handler`, then `:live`. A group that matches no statement is `:live`: it says nothing either way.
# For a group that called `callee` (the next group in), only the statements that invoke it are read
# when one matches: lines alone cannot tell a call in a try body from one in its handler written on
# the same line. Likewise for the group an object is allocated in (`built`, its type), only the
# `:new` statements of that type are read when one matches, and the highest class among them is
# taken: a throw's exception is often built on the line of the check that passes. The class comes with the caught context of the `:caught`
# statements matched, joined.
const _CLASS_RANK = Dict(:dead => 0, :live => 1, :handler => 2, :caught => 3)

function _location_class(body, group::Vector{Base.StackTraces.StackFrame}, callee = nothing, built = nothing)
    isnothing(body) && return (:live, false)
    classes, stacks, invoked, ctxs, _, news = body
    if !isnothing(built)
        # A constructor inlined into the body puts its `:new` one level deeper than the frames
        # AllocCheck reports, so either list of lines may be the prefix of the other.
        want = [fr.line for fr in Iterators.reverse(group)]
        cls, ctx = :dead, false
        found = false
        for i in eachindex(classes)
            news[i] === built || continue
            s = stacks[i]
            n = min(length(s), length(want))
            (n > 0 && view(s, 1:n) == view(want, 1:n)) || continue
            found = true
            c = classes[i]
            _CLASS_RANK[c] > _CLASS_RANK[cls] && (cls = c)
            c === :caught && (ctx = StrictMode._join_caught(ctx, ctxs[i]))
        end
        found && return (cls, ctx)
    end
    if !isnothing(callee)
        best, cls, ctx = _location_class(classes, stacks, ctxs, group, i -> invoked[i] === callee)
        best > 0 && return (cls, ctx)
    end
    _, cls, ctx = _location_class(classes, stacks, ctxs, group, Returns(true))
    return (cls, ctx)
end

function _location_class(classes, stacks, ctxs, group, keep)
    want = [fr.line for fr in Iterators.reverse(group)]
    best, cls, ctx = 0, :live, false
    for i in eachindex(classes)
        keep(i) || continue
        s = stacks[i]
        k = length(s)
        (0 < k <= length(want) && k >= best && s == view(want, 1:k)) || continue
        c = classes[i]
        if k > best
            best, cls, ctx = k, c, false
        elseif _CLASS_RANK[c] > _CLASS_RANK[cls]
            cls = c
        end
        c === :caught && (ctx = StrictMode._join_caught(ctx, ctxs[i]))
    end
    return best, cls, ctx
end

function _is_call_through(@nospecialize(fr))
    fr isa Base.StackTraces.StackFrame || return false
    mi = _frame_mi(fr)
    return mi isa Core.MethodInstance && mi.def isa Method &&
        mi.def.name in (:_call_through, :_invoke_through) && mi.def.module === StrictMode
end

# The function and argument types a backend that takes those is handed for the item `(f, types)`:
# the item itself, or for a `StrictMode._Spec` the wrapper that runs its specialization
# (`StrictMode._spec_call`, which raises when no wrapper does).
_backend_call(@nospecialize(f), @nospecialize(types)) =
    f isa StrictMode._Spec ? StrictMode._spec_call(f, Tuple(types)) : (f, types)

# A JET entry point (`report_opt`, `report_call`) for `f(types...)`: by the signature for a callable
# object known by its type alone, and by the specialization itself for a `StrictMode._Spec`.
_jet_target(report, @nospecialize(f), @nospecialize(types); kwargs...) =
    f isa StrictMode._Spec ? report(f.mi; kwargs...) :
    f isa StrictMode._Callable ? report(StrictMode._sigtype(f, types); kwargs...) : report(f, types; kwargs...)

# `StrictMode.ignore_throw()` (default true): don't count allocations on never-taken error/throw branches
# (BoundsError etc.) — they are not on the hot path and produce false positives on
# runtime-zero-alloc code.
function _raw_allocs_unfiltered(@nospecialize(f), @nospecialize(types))
    world = Base.get_world_counter()
    # AllocCheck and the walk infer outside the compiler's cache. Inferring the entry into it makes
    # the record that lets these sites hold in a later world.
    entry() = StrictMode._base_return_types(f, types; world)
    return _kept(_SITES_MEMO, StrictMode._entry_key(f, types), world, entry) do
        dispatches, caught = _native_walk(f, types)
        vcat(_check_allocs(f, types; caught), dispatches)
    end
end

# Most of what the allocation proofs cost is reading code: AllocCheck's compile of the call graph,
# and the inference of each body the native walk visits. A signature is proved again by another
# driver or for another guarantee, and the same bodies are reached from most signatures, so each
# read is kept for the session.
#
# A kept read holds in the world it was made in. In a later world it holds while the compiler's
# record of the specialization it was read from is valid: Julia ends that record when a method or a
# binding that the inference of the specialization, or of anything it calls statically, depended on
# changes. A specialization the compiler holds no record of is read again in every new world.
# A read kept by signature also needs the signature to dispatch to the same specialization still
# (`StrictMode._read_holds`): the record of a method that was replaced stays valid. A read kept by
# specialization names its subject, and is reached only from a caller whose own record ends when the
# call resolves elsewhere.
# Every setting a proof reads (`ignore_throw`, the barriers, the exemptions) clears StrictMode's
# cache when it is changed, which advances `_GENERATION` and ends every kept read.
struct _Stamp
    read::StrictMode._ReadStamp
    generation::UInt
end

function _holds(s::_Stamp, @nospecialize(key))
    s.generation == StrictMode._GENERATION[] || return false
    key isa Core.MethodInstance || return StrictMode._read_holds(s.read, key)
    world = Base.get_world_counter()
    s.read.world == world && return true
    r = s.read.record
    return !isnothing(r) && r.min_world <= world <= r.max_world
end

const _MEMO_LOCK = ReentrantLock()
# By the entry's body key (`StrictMode._entry_key`): the sites of `_raw_allocs_unfiltered`.
const _SITES_MEMO = IdDict{Any, Tuple{_Stamp, Any}}()
# By specialization: what the native walk reads from its body (`_walk_body`), outside and inside a
# caught context.
const _WALK_MEMO = IdDict{Any, Tuple{_Stamp, Any}}()
const _WALK_CAUGHT_MEMO = IdDict{Any, Tuple{_Stamp, Any}}()

# `read()`, or what an earlier call kept under `key`, a signature type or a specialization. `world`
# is the world `read` reads in. `entry()` is called after the read and makes the compiler record the
# specialization read from, where the read itself does not. A read that raises keeps nothing.
function _kept(read, memo::IdDict, @nospecialize(key), world::UInt, entry)
    hit = @lock _MEMO_LOCK get(memo, key, nothing)
    if !isnothing(hit) && _holds(hit[1], key)
        now = Base.get_world_counter()
        hit[1].read.world == now ||
            @lock _MEMO_LOCK (memo[key] = (_Stamp(StrictMode._as_of(hit[1].read, now), hit[1].generation), hit[2]))
        return hit[2]
    end
    generation = StrictMode._GENERATION[]
    value = read()
    entry()
    mi = key isa Core.MethodInstance ? key : StrictMode._sig_instance(key, world)
    record = mi isa Core.MethodInstance && Base.get_world_counter() == world ? StrictMode._record_of(mi, world) : nothing
    @lock _MEMO_LOCK (memo[key] = (_Stamp(StrictMode._ReadStamp(world, mi, record), generation), value))
    return value
end

# The dynamic calls in the code Julia's own compiler produces for `f(types...)` and for everything
# that code invokes, each as an `AllocCheck.DynamicDispatch`.
#
# AllocCheck compiles through GPUCompiler, whose optimizer resolves every call to the specialization
# for the inferred argument types (`compilesig_invokes = false`). Julia's own optimizer resolves a
# call to the method's compilation signature, which widens an argument the method does not
# specialize on (a `Function` it only passes along, a `@nospecialize` argument), and it leaves a call
# dynamic when that signature is not one it compiles (an `Any` argument, as in the last branch of a
# union split). The first runs a body in which the widened argument is called through
# `jl_apply_generic`; the second is a `jl_apply_generic` itself. Neither is in the module AllocCheck
# analyzes, so it reports no site for them.
#
# The bodies are read as the native interpreter optimizes them: the entry's, then each `:invoke`
# target's, to the end of the call graph. A `:call` whose callee is not a builtin is compiled to
# `jl_apply_generic`. Statements that only lead to a throw are skipped under `ignore_throw()`, as
# AllocCheck skips them; a handler that can return is not one, though AllocCheck skips it too
# (`_check_allocs` puts its sites back). A body that cannot be read raises, so the verdict is
# "unproven" and not a pass.
#
# What this does not report: a value boxed to be passed to a widened callee, with no dispatch.
_native_dispatches(@nospecialize(f), @nospecialize(types)) = first(_native_walk(f, types))

# When the native walk entered the wider specialization Julia compiles for the signature
# (`StrictMode._widened_instance`) and one of `sites` was found below it, the sentence that names
# it and the fix (`StrictMode._widened_note`); empty otherwise. AllocCheck's own sites are in the
# exact specialization and do not count.
function _widened_sites_note(@nospecialize(f), @nospecialize(types), sites)
    w = StrictMode._widened_instance(f, types)
    isnothing(w) && return ""
    below(a) = hasproperty(a, :backtrace) &&
        any(fr -> fr isa Base.StackTraces.StackFrame && fr.linfo === w, a.backtrace)
    return any(below, sites) ? StrictMode._widened_note(f, types) : ""
end

# The dispatches `_native_dispatches` reports, and whether a body it read holds a statement a caught
# throw reaches (`_caught_mask`). A callee called from a try region whose handler can return is read
# in a caught context, with no statement skipped, as the scan reads it (`StrictMode._skip_mask`).
function _native_walk(@nospecialize(f), @nospecialize(types))
    CC = Base.Compiler
    world = Base.get_world_counter()
    interp = CC.NativeInterpreter(world)
    entry = f isa StrictMode._Spec ? f.mi : f isa StrictMode._Callable ?
        ccall(:jl_method_lookup_by_tt, Any, (Any, Csize_t, Any), StrictMode._sigtype(f, types), world, nothing) :
        Base.method_instance(f, types; world)
    out = Any[]
    caught = false
    entry isa Core.MethodInstance || error("the native dispatch walk found no single specialization for the signature")
    # Every caller of each body, in the order found. A backtrace is built once all are known.
    parents = IdDict{Any, Vector{Core.MethodInstance}}()
    found = Tuple{Core.MethodInstance, Symbol}[]
    visited = Set{Tuple{Core.MethodInstance, Any}}([(entry, false)])
    work = Tuple{Core.MethodInstance, Any}[(entry, false)]
    while !isempty(work)
        mi, incaught = pop!(work)
        steps, c = _walk_body(interp, world, mi, incaught)
        caught |= c | (incaught !== false)
        for step in steps
            if step isa Tuple
                callee, ctx = step
                ps = get!(() -> Core.MethodInstance[], parents, callee)
                mi in ps || push!(ps, mi)
                (callee, ctx) in visited && continue
                push!(visited, (callee, ctx))
                push!(work, (callee, ctx))
            else
                push!(found, (mi, step))
            end
        end
    end
    for (mi, name) in found
        push!(out, AllocCheck.DynamicDispatch(_native_backtrace(mi, entry, parents), name))
    end
    return out, caught
end

# The backtrace of a dispatch in the body `mi`: its callers up to `entry`, while there is one caller
# to name. A body with several callers ends it with the frame AllocCheck ends its own with there,
# "multiple call sites", so a reader places the site by the call graph and not by one of the paths.
function _native_backtrace(mi::Core.MethodInstance, entry::Core.MethodInstance, parents::IdDict)
    bt = Base.StackTraces.StackFrame[]
    m = mi
    while true
        d = m.def
        push!(
            bt, d isa Method ?
                Base.StackTraces.StackFrame(d.name, d.file, Int(d.line), m, false, false, 0) :
                Base.StackTraces.StackFrame(Symbol("top-level scope"), :none, 0, m, false, false, 0)
        )
        m === entry && break
        ps = get(parents, m, nothing)
        if isnothing(ps) || length(ps) != 1 || length(bt) > length(parents)
            push!(bt, Base.StackTraces.StackFrame("multiple call sites", "unknown", 0))
            break
        end
        m = only(ps)
    end
    return bt
end

# What the walk reads from one optimized body: in statement order, each `:invoke` as its
# specialization and whether it is called in a caught context, and the callee name of each dynamic
# call (a `Symbol`); and whether a statement read is one a caught throw reaches (`_caught_mask`). In a
# caught context (`incaught`, `StrictMode._join_caught`) that returns whatever is thrown no statement
# is an error path; in one that returns only for a type, the way to a throw known to be no such type
# still is. Each callee is read in the context of its call. A body read in a type's context is not
# kept: such a context is rare, and the memos hold the other two.
function _walk_body(interp, world::UInt, mi::Core.MethodInstance, incaught = false)
    read() = _walk_body_read(interp, mi, incaught)
    incaught isa Type && return read()
    return _kept(read, incaught ? _WALK_CAUGHT_MEMO : _WALK_MEMO, mi, world, Returns(nothing))
end

function _walk_body_read(interp, mi::Core.MethodInstance, incaught)
    src = Base.Compiler.typeinf_code(interp, mi, true)
    src isa Core.CodeInfo || error("the native dispatch walk could not read the optimized body of $(mi)")
    skip = StrictMode.ignore_throw() && incaught !== true
    dead = skip ? StrictMode._deadend_mask(src.code, src, mi.specTypes, incaught) : falses(length(src.code))
    caught = skip && any(_caught_mask(src.code, dead))
    region = skip ? StrictMode._caught_contexts(src.code, dead, src) : nothing
    steps = Any[]
    for (i, st) in pairs(src.code)
        dead[i] && continue
        if Meta.isexpr(st, :invoke) || Meta.isexpr(st, :invoke_modify)
            callee = StrictMode._invoke_mi(st.args[1])
            isnothing(callee) || push!(steps, (callee, isnothing(region) ? incaught : StrictMode._join_caught(incaught, region[i])))
        elseif Meta.isexpr(st, :call)
            ft = StrictMode._unwrap_lattice(StrictMode._stmt_arg_type(src, mi.specTypes, st.args[1]))
            ft isa Type && ft <: Union{Core.Builtin, Core.IntrinsicFunction, Core.OpaqueClosure} && continue
            c = StrictMode._static_callee(src, st.args[1])
            push!(steps, c isa Function ? nameof(c) : Symbol(ft))
        end
    end
    return (steps, caught)
end

# Statements reached only through a `catch`: not reachable from the first statement without taking an
# `EnterNode`'s edge to its handler.
function _catch_only_mask(code::Vector{Any})
    n = length(code)
    reached = falses(n)
    work = n > 0 ? [1] : Int[]
    while !isempty(work)
        i = pop!(work)
        (1 <= i <= n && !reached[i]) || continue
        reached[i] = true
        st = code[i]
        if st isa Core.GotoNode
            push!(work, st.label)
        elseif st isa Core.GotoIfNot
            push!(work, st.dest, i + 1)
        elseif !(st isa Core.ReturnNode)
            push!(work, i + 1)
        end
    end
    return map(!, reached)
end

function _raw_allocs(@nospecialize(f), @nospecialize(types))
    all = _raw_allocs_unfiltered(f, types)
    kept = filter(a -> !_is_guard_alloc(a) && !_nonallocating_runtime_call(a), all)
    # A guard calls its check through `StrictMode._guard_call`, a dynamic call on a cold branch. The
    # check's own frame is dropped above; the call itself stays, because an all-paths proof cannot
    # rule it out. Saying so is the difference between a verdict a reader can act on and one that
    # blames the kernel for StrictMode's own code.
    n = count(_in_guard_call, kept)
    if n > 0
        @warn "StrictModeTest: `$(StrictMode._func_name(f))` contains a StrictMode guard, and " *
            "$n of its $(length(kept)) remaining allocation site(s) are the guard's dynamic call " *
            "of its check (`StrictMode._guard_call`), which runs once per signature but which an " *
            "all-paths proof counts. Prove the guarded call directly " *
            "(`test_signatures([(inner, types)])`) for a verdict that is only about your kernel." maxlog = 1
    end
    return kept
end

# Runtime calls AllocCheck lists as allocating that do not allocate. `jl_hrtime` (behind `time_ns`)
# reads the system clock and returns an integer: a call measured at 0 bytes. `jl_current_exception`
# (a handler reading the exception it caught) loads it from the task's exception stack, and the
# runtime declares it `JL_NOTSAFEPOINT`, which an allocating function cannot be.
const _NONALLOCATING_RUNTIME = (:jl_hrtime, :jl_current_exception)
_nonallocating_runtime_call(@nospecialize(a)) =
    a isa AllocCheck.AllocatingRuntimeCall && Symbol(a.name) in _NONALLOCATING_RUNTIME

# Is this instance in a guard's call of its check: does its backtrace pass through
# `StrictMode._guard_call`?
_in_guard_call(@nospecialize(inst)) =
    hasproperty(inst, :backtrace) && any(inst.backtrace) do fr
    fr isa Base.StackTraces.StackFrame || return false
    mi = fr.linfo
    return mi isa Core.MethodInstance && mi.def isa Method && _is_guard_call(mi.def)
end

# Is this AllocCheck instance a *boxing* / dynamic-dispatch allocation (driven by type
# uncertainty), as opposed to a legitimate typed heap allocation (a `Vector`, `Memory`, …)?
#
# A heap object of an isbits type is a box: such a value lives in a register, on the stack or inline
# in its container, and is allocated only to be handed over as a reference (a `Float64` stored into a
# `Vector{Any}`, a struct passed to `jl_f_getfield` for a field named at run time). One made in
# Base's task, lock or condition code is not counted, as the scan does not count boxing there.
function _is_boxing(@nospecialize(inst))
    inst isa AllocCheck.DynamicDispatch && return !_c_varargs_call(inst)
    if inst isa AllocCheck.AllocatingRuntimeCall
        n = inst.name
        # jl_box_int64 (boxing a primitive), jl_get_nth_field_checked (runtime tuple/field index
        # → boxing). Excludes array-grow / string runtime calls.
        return occursin("box", lowercase(n)) || occursin("get_nth_field", n)
    end
    if inst isa AllocCheck.AllocationSite
        T = inst.type
        T === Core.Box && return true                                     # captured-variable box
        return T isa Type && isbitstype(T) && !_scheduler_site(inst)
    end
    # An instance shape this does not know is not evidence of anything, and answering "not boxing"
    # for it would make `:noboxing` go quiet on a whole class of allocation after an AllocCheck
    # release renames or adds one. Say so once; the verdict stays the conservative `false` so a
    # changed name cannot invent failures either.
    @warn "StrictModeTest: AllocCheck reported a $(typeof(inst)), which the boxing classifier " *
        "does not recognize — `:noboxing` cannot speak for it, and `:noalloc` still counts it. " *
        "If AllocCheck added or renamed an instance type, `_is_boxing` needs it." maxlog = 1
    return false
end

# A C varargs call that AllocCheck reports as a dynamic dispatch. A `ccall` whose signature has a
# required-argument count (`ccall(:printf, Cint, (Cstring, Cint...), …)`, or Base's `_string_n`, which
# calls `jl_alloc_string` that way) compiles to a call through a varargs function type, and AllocCheck
# lists a callee it cannot name as a dispatch to an unknown target. It is a call into C: nothing is
# looked up and nothing is boxed. The one in `Base.trypoptask`, a `jl_safe_printf` of a warning, is
# reached by every `wait`: counted as boxing, it fails `:noboxing` for every call that waits.
#
# The site carries no instruction to inspect, so it is judged by the function that holds it: the
# nearest frame with a specialization, whose typed body must contain a varargs `:foreigncall` and no
# dispatch of its own. Anything else stays a dispatch. A body holding both a varargs C call and a
# dispatch the scan cannot see is therefore read as the C call alone.
function _c_varargs_call(@nospecialize(inst))
    isnothing(inst.fname) || return false
    for fr in inst.backtrace
        mi = _frame_mi(fr)
        mi isa Core.MethodInstance || continue
        key = StrictMode._callee_key(mi)
        ci = StrictMode._typed_body(key)
        isnothing(ci) && return false
        any(st -> Meta.isexpr(st, :foreigncall) && st.args[4] isa Int && st.args[4] > 0, ci.code) || return false
        own = Base.IdSet{Any}()
        push!(own, key)
        return !StrictMode._scan_ci(ci, key, 0, own, :boxing)[2]
    end
    return false
end

# Barrier-aware wrapper around `_raw_allocs`. A call that reaches a one-time-init allocation barrier
# (StrictMode's `barrier` signal) keeps AllocCheck's all-paths proof; only the sites the barrier
# accounts for are dropped. A site is the barrier's when its backtrace passes through the barrier's
# own frame, or when its function is reached only through a barrier (`_only_through_barrier`). The
# second covers a function compiled once for several callers: AllocCheck ends its backtrace at
# "multiple call sites", which names no caller, so only the call graph can place it (24 of 52 sites
# on a `OncePerProcess` calibrator are the guard's lock and task internals, merged this way). A
# merged site the call also reaches outside a barrier, such as a lock wait in a stream write two
# callers share, is the call's own, and so is every site when the call graph outside the barriers
# cannot be read in full. Every other site stands, so a buffer grown later through the barrier's
# accessor is still reported where it grows; the value-free scan stops two calls deep and cannot see
# it.
# The filter applies to every site, whichever AllocCheck run found it. When the scan finds allocation,
# boxing or an abstract-eltype container and the filter leaves no site, the unfiltered proof is
# returned, so the proof is never more permissive than the scan. Returns `(allocs, exempted, unplaced)`;
# `unplaced` are the sites kept because the call graph does not name their specialization (`_off_graph`).
function _checked_allocs(@nospecialize(f), @nospecialize(types::Tuple))
    allocs = _not_own_excused(f, _raw_allocs(f, types))
    _IGNORE_BARRIER[] || return (allocs, false, empty(allocs))
    sig = StrictMode._alloc_signals(f, types)
    sig.barrier || return (allocs, false, empty(allocs))
    kept = filter(!_through_barrier, allocs)
    unplaced = empty(allocs)
    if !isempty(kept)
        nodes = Base.IdSet{Core.MethodInstance}()
        inside = _only_through_barrier(StrictMode._entry_key(f, types), nodes)
        if !isnothing(inside)
            filter!(a -> !(_site_mi(a) in inside), kept)
            unplaced = filter(a -> _off_graph(a, nodes), kept)
        end
    end
    isempty(kept) && (sig.alloc || sig.boxing || !isnothing(sig.abscontainer)) && return (allocs, false, unplaced)
    excused = length(allocs) - length(kept)
    if excused > 0
        name = something(_barrier_frame_name(allocs), :barrier)
        @info "StrictModeTest: `$(StrictMode._func_name(f))` reaches `$name`, a one-time-init allocation barrier; " *
            "$excused allocation site(s) inside it are excused, $(length(kept)) other(s) checked as " *
            "usual. Disable with set_ignore_barrier!(false)." maxlog = 1
    end
    return (kept, isempty(kept) && excused > 0, unplaced)
end

# Whether the call graph `nodes` does not name the specialization compiled around the site `a`. The
# graph is read to reproduce what AllocCheck compiles, so each site's specialization is one of its
# nodes. One that is not shows the two disagree about the code, and the graph then says nothing
# about how that site is reached.
function _off_graph(@nospecialize(a), nodes)
    hasproperty(a, :backtrace) || return false
    mi = _site_mi(a)
    return mi isa Core.MethodInstance && !(mi in nodes)
end

# What a failure says of the sites the call graph does not name.
function _unplaced_note(unplaced)
    isempty(unplaced) && return ""
    specs = unique!(String[sprint(show, _site_mi(a)) for a in unplaced])
    return " " * string(length(unplaced)) * " site(s) could not be matched to the call graph and are " *
        "counted as the call's own: the graph does not name " * join(("`" * s * "`" for s in specs), ", ") *
        ". The graph is StrictModeTest's reading of what AllocCheck compiled, so this is a defect in " *
        "that reading; please report it."
end

# Running pending finalizers is not the call's own allocation. Base's `unlock` does it on every lock,
# `Condition` and `Threads.Event`; finalizers are code registered elsewhere, and they run at other GC
# points too. A Base slow path that allocates for its own sake (a contended lock) is still judged.
# An `@strict_exempt` callee is NOT dropped here: `@test_noalloc` proves no allocation on any path.
# A call whose every site is inside one is reported as that (`_exempt_split`, SM0018), which is a
# failure unless the caller passes `allow_exempt = true`; a pool that grows on first use is
# gated on what it does once warm by `@test_steady_state`.
function _not_own_excused(@nospecialize(f), allocs)
    fin(a) = a isa AllocCheck.AllocatingRuntimeCall && Symbol(a.name) === :jl_gc_run_pending_finalizers
    kept = filter(!fin, allocs)
    nfin = length(allocs) - length(kept)
    nfin > 0 && @info "StrictModeTest: `$(StrictMode._func_name(f))`: $nfin site(s) that run pending finalizers (from Base's " *
        "`unlock`) excused: finalizers are code registered elsewhere, not this call's allocation." maxlog = 1
    return kept
end

_frame_mi(@nospecialize(fr)) = (l = fr.linfo; l isa Core.CodeInstance ? l.def : l)

# The allocation sites split by owner: `(own, by, unplaced)`, the sites that are the call's own, the exempt
# functions that account for the rest, each with the reason its exemption gave, and the own sites the
# call graph was asked about and does not name (`_off_graph`). A site is taken from
# the call only when the call graph places it in an exempt function; any other site is the call's.
# A site is an exempt function's when its
# backtrace passes through a frame whose METHOD an exemption covers for `:noalloc`: matched on the
# method's module and name, so a function of the same name elsewhere excuses nothing. Only an
# exemption declared in a module names a method. One declared with no module, from a session,
# covers by name in every module and excuses no site here, though the scan still notes it. An exempt
# callee that was inlined has no frame with a specialization of its own, so its site reads as the
# caller's and the result is an ordinary failure.
# A site reached through a function or closure the exempt function was handed is the caller's too
# (`_runs_handed_in`). A site whose backtrace has no exempt frame, as when AllocCheck ends it at a
# function compiled once for several callers, is the exempt function's when the call `sig` reaches
# its specialization only through that exempt callee (`_only_through_exempt`).
function _exempt_split(allocs, @nospecialize(sig))
    by = Pair{String, String}[]
    own = empty(allocs)
    unplaced = empty(allocs)
    inside = nothing
    nodes = Base.IdSet{Core.MethodInstance}()
    for a in allocs
        if !hasproperty(a, :backtrace)
            push!(own, a)
            continue
        end
        e = nothing
        framed = false
        for (k, fr) in enumerate(a.backtrace)
            fr isa Base.StackTraces.StackFrame || continue
            mi = _frame_mi(fr)
            mi isa Core.MethodInstance || continue
            e = StrictMode._mi_exemption(mi; declared_in_module = true)
            isnothing(e) && continue
            framed = true
            # The exemption covers the exempt function's own code and what that calls. A function
            # or closure it was HANDED is the caller's code, and what that allocates is the
            # caller's allocation, whichever frame ran it. An exempt frame further out may still
            # account for the site, so the walk goes on.
            _runs_handed_in(a, k, mi) ? (e = nothing) : break
        end
        if isnothing(e) && !framed
            isnothing(inside) && (inside = something(_only_through_exempt(sig, nodes), IdDict{Core.MethodInstance, Any}()))
            e = get(inside, _site_mi(a), nothing)
            # An empty `nodes` is a graph that was not read in full, which places no site.
            isempty(nodes) || !_off_graph(a, nodes) || push!(unplaced, a)
        end
        if isnothing(e)
            push!(own, a)
        else
            p = String(e.func) => e.reason
            p in by || push!(by, p)
        end
    end
    return own, Tuple(by), unplaced
end

# Whether the allocation site `a`, under the exempt function at backtrace frame `k`, runs code that
# function's caller handed in: a frame inside it belongs to a call the exempt code makes of a value
# loaded from one of its arguments (`StrictMode._handed_code`, the scan's own reading of the same
# signature). A frame that kept its specialization is matched on the called value's type; an inlined
# one has only a name, and is matched on the names of that type's methods. When that reading is
# incomplete (a body it could not read, or a handed value reaching a call whose target is not
# resolved), every site in or below the exempt frame counts, as in the scan.
function _runs_handed_in(@nospecialize(a), k::Int, mi::Core.MethodInstance)
    bt = a.backtrace
    found, complete = StrictMode._handed_code(StrictMode._callee_key(mi))
    complete || return true
    (isempty(found) || k <= 1) && return false
    types = Any[(Base.unwrap_unionall(StrictMode._key_sig(h))::DataType).parameters[1] for h in found]
    names = Set{Symbol}()
    for T in types
        isconcretetype(T) || continue
        ms = Base._methods_by_ftype(Tuple{T, Vararg{Any}}, -1, Base.get_world_counter())
        ms isa Vector || continue
        for match in ms
            push!(names, match.method.name)
        end
        T <: Function && isdefined(T, :instance) && push!(names, nameof(T.instance))
    end
    for j in 1:(k - 1)
        fr = bt[j]
        fr isa Base.StackTraces.StackFrame || continue
        inner = _frame_mi(fr)
        if inner isa Core.MethodInstance
            F = (inner.specTypes::DataType).parameters[1]
            any(T -> T === F, types) && return true
        elseif fr.func in names
            return true
        end
    end
    return false
end

_through_barrier(@nospecialize(a)) = any(a.backtrace) do fr
    mi = _frame_mi(fr)
    mi isa Core.MethodInstance && StrictMode._mi_is_barrier(mi)
end

# The specialization compiled around an allocation site: its first frame that was not inlined.
function _site_mi(@nospecialize(a))
    for fr in a.backtrace
        mi = _frame_mi(fr)
        mi isa Core.MethodInstance && return mi
    end
    return nothing
end

# Most bodies `_invoke_reach` reads before it gives up.
const _BARRIER_WALK_MAX = 4096

# The specializations the call `sig` (a body key, `StrictMode._entry_key`) reaches only by entering a
# barrier: reached from a barrier, and
# not from the call along any path that avoids one. A function called from several places is
# compiled once, and AllocCheck ends the backtrace of its sites at a frame named "multiple call
# sites", so the backtrace cannot say whether the barrier is on every path to it; this call graph
# can. `nothing` when the graph outside the barriers could not be read in full, since an edge the
# walk did not see may reach any site. `nodes` receives every specialization the graph names.
function _only_through_barrier(@nospecialize(sig), nodes = Base.IdSet{Core.MethodInstance}())
    root = StrictMode._key_instance(sig, Base.get_world_counter())
    root isa Core.MethodInstance || return nothing
    outside, barriers, complete = _invoke_reach(Core.MethodInstance[root], true)
    (complete && !isempty(barriers)) || return nothing
    inside, _, _ = _invoke_reach(collect(barriers), false)
    union!(nodes, outside, barriers, inside)
    return Base.IdSet{Core.MethodInstance}(mi for mi in inside if !(mi in outside))
end

# The specializations the call `sig` reaches only by entering a callee exempt from `:noalloc` whose
# handed-in code is read in full (`StrictMode._handed_code`), each mapped to that callee's exemption.
# The code it calls that its caller handed in, and all that this reaches, is the caller's, and so is
# not in the result. `nothing` when the graph could not be read in full. `nodes` receives every
# specialization the graph names, and stays empty when it could not be read in full.
function _only_through_exempt(@nospecialize(sig), nodes = Base.IdSet{Core.MethodInstance}())
    root = StrictMode._key_instance(sig, Base.get_world_counter())
    root isa Core.MethodInstance || return nothing
    excuses(mi) = !isnothing(StrictMode._mi_exemption(mi; declared_in_module = true)) &&
        StrictMode._handed_code(StrictMode._callee_key(mi))[2]
    outside, stops, complete = _invoke_reach(Core.MethodInstance[root], true; isstop = excuses)
    (complete && !isempty(stops)) || return nothing
    handed = Core.MethodInstance[]
    for ex in stops, h in first(StrictMode._handed_code(StrictMode._callee_key(ex)))
        mi = StrictMode._key_instance(h, Base.get_world_counter())
        mi isa Core.MethodInstance || return nothing
        push!(handed, mi)
    end
    if !isempty(handed)
        theirs, _, done = _invoke_reach(handed, false)
        done || return nothing
        union!(outside, theirs)
    end
    out = IdDict{Core.MethodInstance, Any}()
    seen = copy(outside)
    for ex in stops
        e = StrictMode._mi_exemption(ex; declared_in_module = true)
        reached, _, done = _invoke_reach(Core.MethodInstance[ex], true; isstop = mi -> any(x -> x === mi, handed))
        done || return nothing
        union!(seen, reached)
        for mi in reached
            mi in outside || haskey(out, mi) || (out[mi] = e)
        end
    end
    union!(nodes, seen, stops)
    return out
end

# The specializations reached from `roots` along the `:invoke` edges of their optimized bodies,
# which are the static calls AllocCheck compiles and follows. Each edge leads to the specialization
# AllocCheck compiles for it (`_compiled_callee`), so a site's specialization (`_site_mi`) is one
# the walk names. It also leads to the specialization the statement itself names, which is the
# one Julia's own compiler runs and the native walk reports a dispatch in (`_native_walk`). A call left to
# run-time dispatch is not such an edge: AllocCheck reports the dispatch itself and compiles nothing
# behind it. With `stop`, a barrier is recorded rather than entered. Returns `(reached, barriers, complete)`;
# `complete` is false when a body could not be read, when the specialization an edge leads to could
# not be determined, when a call could still be compiled statically
# without an `:invoke` (`Core.invoke` and its kin, a `@cfunction`, an opaque closure), or when the
# walk reached `_BARRIER_WALK_MAX` bodies. `isstop` names what counts as a barrier.
function _invoke_reach(roots::Vector{Core.MethodInstance}, stop::Bool; isstop = StrictMode._mi_is_barrier)
    reached = Base.IdSet{Core.MethodInstance}(roots)
    barriers = Base.IdSet{Core.MethodInstance}()
    queue = copy(roots)
    complete = true
    while !isempty(queue)
        length(reached) > _BARRIER_WALK_MAX && return (reached, barriers, false)
        mi = pop!(queue)
        ci = _reach_body(mi)
        if !(ci isa Core.CodeInfo)
            complete = false
            continue
        end
        for st in ci.code
            st isa Expr || continue
            if st.head === :invoke || st.head === :invoke_modify
                named = StrictMode._invoke_mi(st.args[1])
                callee = isnothing(named) ? nothing : _compiled_callee(ci, mi, st, named)
                if isnothing(callee)
                    complete = false
                    continue
                end
                for c in (callee, named)
                    (c in reached || c in barriers) && continue
                    if stop && isstop(c)
                        push!(barriers, c)
                    else
                        push!(reached, c)
                        push!(queue, c)
                    end
                end
            elseif st.head === :call
                v = StrictMode._sw_callee_value(st.args[1])
                v isa Core.Builtin && nameof(v) in StrictMode._SW_DYNAMIC_BUILTINS && (complete = false)
            elseif st.head in (:cfunction, :new_opaque_closure)
                complete = false
            end
        end
    end
    return (reached, barriers, complete)
end

# The optimized body of the specialization `mi`, or `nothing` when it cannot be read: the scan's
# own read of the same specialization (`StrictMode._callee_key`).
_reach_body(mi::Core.MethodInstance) = StrictMode._typed_body(StrictMode._callee_key(mi))

# The specialization AllocCheck compiles for the `:invoke` statement `st` in the body `ci` of
# `caller`, or `nothing` when it cannot be determined. Julia's own optimizer names the callee's
# compilation signature there, which widens an argument the method does not specialize on;
# AllocCheck's names the specialization for the argument types inferred at the statement
# (`_native_dispatches`), and that one holds the sites.
function _compiled_callee(ci, caller::Core.MethodInstance, st::Expr, callee::Core.MethodInstance)
    # A specialization for concrete types is the only one its call can lead to.
    Base.isdispatchtuple(callee.specTypes) && return callee
    m = callee.def
    (m isa Method && st.head === :invoke) || return nothing
    ats = Any[]
    for a in Iterators.drop(st.args, 1)
        T = if Meta.isexpr(a, :static_parameter)
            v = caller.sparam_vals[a.args[1]::Int]
            v isa TypeVar ? nothing : Core.Typeof(v)
        elseif a isa Expr
            nothing
        else
            Base.Compiler.widenconst(StrictMode._stmt_arg_type(ci, caller.specTypes, a))
        end
        T isa Type || return nothing
        push!(ats, T)
    end
    tt = Core.apply_type(Tuple, ats...)
    tt == callee.specTypes && return callee
    tt <: callee.specTypes || return nothing
    env = ccall(:jl_type_intersection_with_env, Any, (Any, Any), tt, m.sig)::Core.SimpleVector
    env[1] === Union{} && return nothing
    spec = Base.specialize_method(m, env[1], env[2]::Core.SimpleVector)
    return spec isa Core.MethodInstance ? spec : nothing
end

# The name of the first barrier frame any site passes through, for the note.
function _barrier_frame_name(allocs)
    for a in allocs, fr in a.backtrace
        mi = _frame_mi(fr)
        (mi isa Core.MethodInstance && mi.def isa Method && StrictMode._mi_is_barrier(mi)) || continue
        ps = mi.specTypes.parameters
        # A registered barrier is named by its function, or by its type for a callable object; a
        # Base once-guard by its type, since its frame is a generated init closure. A keyword call
        # reaches the registered callable through `Core.kwcall` or its keyword body, which carry it
        # past parameter 1.
        StrictMode._is_registered_callee(ps[1]) && return StrictMode._demangle(mi.def.name)
        for f in StrictMode._barrier_functions()
            any(p -> StrictMode._barrier_covers(f, p), ps) &&
                return StrictMode._demangle(StrictMode._callable_name(f))
        end
        return nameof(Base.unwrap_unionall(ps[2]))
    end
    return nothing
end

function _format_allocs(results; header = "call provably allocates")
    io = IOBuffer()
    println(io, header, " (", length(results), " site(s)):")
    for (i, a) in enumerate(results)
        print(io, "  [", i, "] ")
        # AllocCheck instances `show` with their source location and reason; reuse that.
        print(io, a)
        i < length(results) && println(io)
    end
    return String(take!(io))
end

# An allocation site that lies in Base's task, lock or condition code: on the way from the allocation out
# to the nearest frame of the package's own code, the calls pass through that code. This is what a wait,
# a yield or a lock does, and what the value-free scan reports as its own kind. A callable the
# scheduler was handed (the function given to `lock(f, l)`) is its caller's code whoever defined its
# type, so the walk ends where a scheduler frame calls one of its own arguments (`_calls_argument`).
function _scheduler_site(@nospecialize(a))
    hasproperty(a, :backtrace) || return false
    sched = false
    prev = nothing
    for fr in a.backtrace
        mi = _frame_mi(fr)
        if mi isa Core.MethodInstance && mi.def isa Method &&
                !(Base.moduleroot(mi.def.module) === Base || Base.moduleroot(mi.def.module) === Core)
            break
        end
        # An inlined frame carries no method instance, only its file. Base's own files are recorded
        # relative to the image ("./lock.jl"): any other file is the package's code (the function
        # given to `lock`, inlined into it), and the walk ends there too.
        if fr isa Base.StackTraces.StackFrame && isnothing(mi) && fr.inlined &&
                !startswith(string(fr.file), "./")
            break
        end
        if fr isa Base.StackTraces.StackFrame && basename(string(fr.file)) in StrictMode._SCHEDULER_FILES
            mi isa Core.MethodInstance && !isnothing(prev) && _calls_argument(mi, prev) && break
            sched = true
        end
        prev = fr
    end
    return sched
end

# Whether frame `inner`, just inside scheduler frame `mi`, is a call of one of `mi`'s arguments. An
# inlined frame has no method instance, only its function's name, which is matched against the methods
# of each argument type.
function _calls_argument(mi::Core.MethodInstance, @nospecialize(inner))
    imi = _frame_mi(inner)
    imi isa Core.MethodInstance && return StrictMode._calls_argument(mi.specTypes, imi.specTypes)
    inner isa Base.StackTraces.StackFrame || return false
    sig = Base.unwrap_unionall(mi.specTypes)
    sig isa DataType || return false
    world = Base.get_world_counter()
    for P in Iterators.drop(sig.parameters, 1)
        (P isa DataType && isconcretetype(P)) || continue
        ms = Base._methods_by_ftype(Tuple{P, Vararg{Any}}, -1, world)
        ms isa Vector && any(m -> m.method.name === inner.func, ms) && return true
    end
    return false
end

# First source location among allocation sites (any / boxing-only), pulled from the backtraces.
function _first_loc(allocs, boxing_only::Bool)
    for a in allocs
        boxing_only && !_is_boxing(a) && continue
        bt = a.backtrace
        isempty(bt) || return (string(bt[1].file), Int(bt[1].line))
    end
    return ("", 0)
end

# ── JET ──────────────────────────────────────────────────────────────────────────────────────────

# JET reports an optimization failure where inference gave up on a recursive cycle. Julia 1.13's
# scheduler holds one (`yield` → `wait` → `OncePerThread`), so a target that wakes or yields a task gets
# reports located entirely in Base, and they say nothing about the target's own code. Such a report is
# dropped only when its innermost frame lies in a different top-level module from the target's entry
# frame; a cycle inside the target's package still counts, and so does every other kind of report.
# See #30.
_frame_module(@nospecialize(fr)) =
    (mi = fr.linfo; mi isa Core.MethodInstance && mi.def isa Method ? Base.moduleroot(mi.def.module) : nothing)

function _is_foreign_opt_failure(@nospecialize(rep))
    rep isa JET.OptimizationFailureReport || return false
    inner = _frame_module(rep.vst[end])
    return inner !== nothing && inner !== _frame_module(rep.vst[1])
end

# The dynamic calls in the body of a frame JET could not optimize, as `MyMod.caller → callee` strings.
# JET reports dispatch from optimized IR only, so this frame's own body is invisible to it; scanning
# the unoptimized IR is the only way to cover it. An empty result means the body dispatches nowhere.
function _bail_frame_dispatches(@nospecialize(rep))
    out = String[]
    hasproperty(rep, :vst) && !isempty(rep.vst) || return out
    mi = rep.vst[end].linfo               # the frame the report is about, as `_report_location` reads it
    mi isa Core.CodeInstance && (mi = mi.def)
    mi isa Core.MethodInstance || return out
    where = mi.def isa Method ? string(mi.def.module, ".", mi.def.name) : string(mi)
    cis = try
        StrictMode._code_typed_of(StrictMode._callee_key(mi); optimize = true)
    catch
        # Unread is not clean: JET reported nothing from this frame's body either.
        return push!(out, "$where: its body could not be read")
    end
    for pair in cis
        ci = pair isa Pair ? pair.first : pair
        ci isa Core.CodeInfo || continue
        for st in ci.code
            Meta.isexpr(st, :call) || continue
            callee = StrictMode._static_callee(ci, st.args[1])
            (callee isa Core.Builtin || callee isa Core.IntrinsicFunction) && continue
            push!(out, string(where, " → ", isnothing(callee) ? "callee not statically known" : nameof(callee)))
        end
    end
    return out
end

# Where a report sits: its kind and the innermost frame, e.g. `RuntimeDispatchReport in PureBLAS.f`.
function _report_location(@nospecialize(rep))
    mi = rep.vst[end].linfo
    loc = mi isa Core.MethodInstance && mi.def isa Method ? string(mi.def.module, ".", mi.def.name) : string(mi)
    return string(nameof(typeof(rep)), " in ", loc)
end

# Wraps `JET.report_opt` so a backend failure names the check target and signature instead of
# propagating raw from inside JET (see `AnalysisError`).
function _opt_reports(target::AbstractString, @nospecialize(f), @nospecialize(types::Tuple))
    try
        return filter(r -> !_is_guard_report(r) && !_is_foreign_opt_failure(r), JET.get_reports(_jet_target(JET.report_opt, f, types)))
    catch err
        throw(AnalysisError(target, "(" * join(types, ", ") * ")", err))
    end
end

# ── JET call analysis ────────────────────────────────────────────────────────────────────────────

# `report_opt` answers "does this dispatch at run time", which is a performance question. It is
# silent on a call that cannot resolve AT ALL: a `MethodError` on a branch no test happens to take
# passes every gate here. Measured on `rare(x::Int) = x > 1000 ? x + "oops" : x + 1`, `report_opt`
# finds nothing and `report_call` finds the missing `+(::Int64, ::String)`.
#
# Only two report kinds are kept, because the rest are not actionable on real code. Measured over
# StrictMode's own 569 compiled signatures: 373 `NonBooleanCondErrorReport`s, nearly all of them a
# `Missing` arising from union-splitting a `Vector{Any}` that never holds one, against 3 distinct
# `MethodErrorReport` sites. A check whose output is 98% noise is a check nobody reads.
#
# `UncaughtExceptionReport` is excluded because it fires on a method every path of which throws —
# a deliberate error helper, not a defect. `:typestable` already accepts `Union{}` as the inferred
# return of exactly such a method, for the same reason (see #36), and `ignore_throw` already says
# throw paths do not count.
const _CALL_REPORT_KINDS = (:MethodErrorReport, :UndefVarErrorReport)

_is_call_defect(@nospecialize(rep)) = nameof(typeof(rep)) in _CALL_REPORT_KINDS

# `target_modules` confines the analysis to the module under test. Without it a call into Base
# reports Base's own union-split branches, which the caller cannot act on and did not write.
function _call_reports(
        target::AbstractString, @nospecialize(f), @nospecialize(types::Tuple), mod::Module
    )
    try
        return filter(
            _is_call_defect,
            JET.get_reports(_jet_target(JET.report_call, f, types; target_modules = (mod,)))
        )
    catch err
        throw(AnalysisError(target, "(" * join(types, ", ") * ")", err))
    end
end

# ── TrimCheck ────────────────────────────────────────────────────────────────────────────────────

# juliac includes two patch files into the target before trim inference
# (`juliac-trim-base.jl`, `juliac-trim-stdlib.jl`). They change what the verifier sees — most
# consequentially by raising `print_to_string`'s `max_args`, without which a ≥4-argument string
# interpolation on a reachable throw path despecializes to `Vararg{Any}` and the verifier rejects
# code juliac itself builds clean. That is issue #19: an ordinary
# `throw(ArgumentError("… $m×$n"))` reds the guarantee on Julia 1.13 while `juliac --trim=safe`
# produces the `.so`. Verifying without them checks a DIFFERENT PROGRAM than juliac compiles.
#
# They are OFF by default, and the reason is not caution — it is measured. `juliac-trim-base.jl`
# contains:
#
#     @eval Base.CoreLogging begin
#         # Disable logging (TypedCallable is required to support the existing dynamic
#         # logger interface, but it's not implemented yet)
#         @inline current_logger_for_env(std_level::LogLevel, group, _module) = nothing
#     end
#
# Applying that in-process SILENCES EVERY `@warn` AND `@info` for the rest of the session — which
# is the whole of StrictMode's reporting tier. Every `@assert_noalloc` would find its violations and
# say nothing: the vacuous-green shape this package exists to remove, installed by the package
# itself. Observed directly, as two `@test_logs` assertions in this suite going empty the moment the
# patches were applied by default.
#
# TrimCheck's own `validate_function` avoids this by running `init_validation` on a Distributed
# worker. The correct fix for issue #19 is the same isolation; until then this is an opt-in for a
# session that does nothing but trim verification and does not need its logging back.
const _JULIAC_PATCHES = Ref(false)
const _JULIAC_PATCHED = Ref(false)

"""
    juliac_patches() -> Bool

Whether trim verification applies juliac's own `juliac-trim-base.jl` / `juliac-trim-stdlib.jl`
patches before running the verifier. Default `false` — applying them disables logging for the whole
session. See [`set_juliac_patches!`](@ref).
"""
juliac_patches() = _JULIAC_PATCHES[]

"""
    set_juliac_patches!(b::Bool)

Set whether trim verification applies juliac's Base/stdlib patches first.

`true` makes the verifier check the same program `juliac --trim=safe` compiles, which is the only
way to avoid issue #19's false FAILs (a ≥4-argument string interpolation on a reachable throw path
is rejected without them). The patched verification runs in a **subprocess**, so the caller's
session keeps its logging: `juliac-trim-base.jl` stubs `Base.CoreLogging.current_logger_for_env`,
which silences every `@warn` and `@info` in whatever process applies it, and that process is now a
throwaway child.

The child costs a Julia start, a package load and a patch application, paid once per **gate**:
`test_signatures`, `test_compiled` and `test_registered` verify every signature they cover in a
single child. A verification outside a gate — `@test_trim_compatible`, or `proof_findings` called
directly — pays for a child of its own, which is why this is off by default rather than always on. A signature whose function cannot be reached in a fresh process —
a closure, or something defined in a module the child cannot load — falls back to unpatched
in-process verification with a warning naming the reason.

`false` (the default) verifies against stock Base in this process and accepts the false-FAIL class.
"""
set_juliac_patches!(b::Bool) = (_JULIAC_PATCHES[] = b)

# The directory holding the trim patches that `juliac` applies, or `nothing`. Through Julia 1.12
# juliac ships with Julia, in `share/julia/juliac`. From 1.13 it is the JuliaC.jl app, which
# applies its OWN copies from the package's `src/scripts`; they differ from the copies Julia keeps
# under `share/julia/test/trimming` and between JuliaC versions, so the app's pinned version is
# read from its manifest rather than any JuliaC this session can load.
function _juliac_patch_dir()
    shipped = joinpath(Sys.BINDIR, "..", "share", "julia", "juliac")
    isdir(shipped) && return shipped
    for depot in DEPOT_PATH
        manifest = joinpath(depot, "environments", "apps", "JuliaC", "Manifest.toml")
        isfile(manifest) || continue
        entry = only(TOML.parsefile(manifest)["deps"]["JuliaC"])
        haskey(entry, "path") && return joinpath(dirname(manifest), entry["path"], "src", "scripts")
        slug = Base.version_slug(Base.UUID(entry["uuid"]), Base.SHA1(entry["git-tree-sha1"]))
        for d in DEPOT_PATH
            root = joinpath(d, "packages", "JuliaC", slug)
            isdir(root) && return joinpath(root, "src", "scripts")
        end
    end
    return nothing
end

# Returns whether the patches are actually in effect. The subprocess path reports this back, so a
# verdict reached against STOCK Base is never presented as a patched one. The patch files are not
# on every machine (from 1.13 they belong to the JuliaC app), and a silent fallback would relabel
# exactly the false FAILs issue #19 is about.
function _apply_juliac_patches()
    _JULIAC_PATCHES[] || return false
    _JULIAC_PATCHED[] && return true             # already applied in this process
    _JULIAC_PATCHED[] = true                     # set first: a failed attempt must not retry per call
    files = ("juliac-trim-base.jl", "juliac-trim-stdlib.jl")
    try
        dir = _juliac_patch_dir()
        isnothing(dir) && error(
            "juliac's patch files were not found: neither Julia's own juliac directory nor an " *
                "installed JuliaC app (`]app add JuliaC`) in any depot"
        )
        for f in files
            p = joinpath(dir, f)
            isfile(p) || error("$p not found")
            Base.include(Main, p)
        end
        @info "StrictModeTest: applied juliac's trim patches ($(join(files, ", ")) from $dir) so the " *
            "verifier checks the same program `juliac --trim=safe` compiles. These mutate " *
            "process-global compiler state and are not reversible; set_juliac_patches!(false) " *
            "skips them at the cost of reinstating a false-FAIL class (issue #19)."
    catch err
        @warn "StrictModeTest: could not apply juliac's trim patches ($(sprint(showerror, err))). " *
            "Trim verification will run against STOCK Base, which rejects some code juliac builds " *
            "clean — a `@test_trim_compatible` failure may therefore be a false alarm."
        return false
    end
    return true
end

# TrimCheck's public API (`@validate` / `validate_function`) only accepts a call-expr or a
# single-method function eval'd in `Main` — it cannot check an arbitrary concrete `(f, types)`. So we
# drive its core directly: the same `hook_verify_typeinf_trim() do … typeinf_ext_toplevel(…,
# TRIM_SAFE) end` that `validate_function` runs, but for our exact signature. We reference
# TrimCheck's own `Compiler` binding (as `validate_function` does) so we hit the same verifier.
#
# `types` may be a `Type{<:Tuple}` (e.g. `Tuple{Int,Float64}`) or a plain tuple of types.
# `Compiler.typeinf_ext_toplevel` gained a fourth argument, `external_linkage::Bool`, in Julia
# 1.13.0-rc4. Dispatching on whether that method exists, rather than on a version number, keeps this
# working across the change in either direction — the argument arrived mid-release-candidate, so a
# `VERSION` bound would have to name an rc.
#
# `false` reproduces what the three-argument form did: it passed nothing through to
# `collectinvokes!`, whose own `external_linkage` keyword defaults to `false`.
function _typeinf_toplevel(Comp, methods::Vector{Any}, worlds::Vector{UInt})
    return if hasmethod(Comp.typeinf_ext_toplevel, Tuple{Vector{Any}, Vector{UInt}, UInt8, Bool})
        Comp.typeinf_ext_toplevel(methods, worlds, Comp.TRIM_SAFE, false)
    else
        Comp.typeinf_ext_toplevel(methods, worlds, Comp.TRIM_SAFE)
    end
end

# --- issue #19: verify against juliac's patched Base without poisoning this session --------------
# Applying `juliac-trim-base.jl` is what makes the verifier check the program juliac actually
# compiles, but it stubs `Base.CoreLogging.current_logger_for_env`, so the process that applies it
# stops emitting `@warn`/`@info` — the whole of StrictMode's reporting tier, silent. The isolation
# is the fix: run the patched verification in a child and read back only the verdict. TrimCheck's
# own `validate_function` runs `init_validation` on a Distributed worker for the same reason.
#
# `f` and the argument types travel by `Serialization`, which records a function by module and name
# — so the child resolves them only if it can load the defining module. A closure, or a fixture
# defined inside a `@testitem`, cannot survive that, which is why every failure path here falls back
# to unpatched in-process verification rather than erroring: an unavailable subprocess must degrade
# to the old answer, never to a FAIL.
const _TRIM_CHILD_STDERR = Ref("")

# Every module the child must load to resolve a signature. The method's own module, not the
# function's: a package that extends another package's generic has `parentmodule(f)` pointing at
# the package that DECLARED the generic, which cannot resolve an argument type the extending
# package owns — the child then dies deserializing its own input. Submodules map to their root
# package, because that is what `using` can load.
function _trim_child_modules(@nospecialize(f), argtypes::Vector)
    mods = Symbol[]
    _push_module!(mods, parentmodule(f isa Function || f isa Type ? f : StrictMode._ftype(f)))
    try
        _push_module!(mods, StrictMode._which(f, Tuple{argtypes...}).module)
    catch
    end
    for T in argtypes
        _push_type_modules!(mods, T)
    end
    return mods
end

function _push_module!(mods::Vector{Symbol}, m)
    m isa Module || return mods
    root = Base.moduleroot(m)
    (root === Main || root === Base || root === Core) && return mods
    name = nameof(root)
    name in mods || push!(mods, name)
    return mods
end

# Every module a type's spelling depends on, parameters included: `Vector{Workspace}` resolves in
# the child only if the package owning `Workspace` is loaded, and a parameter can come from a
# different package than its wrapper.
function _push_type_modules!(mods::Vector{Symbol}, @nospecialize(T), depth::Int = 0)
    depth > 8 && return mods
    T isa Type || return mods
    base = Base.unwrap_unionall(T)
    base isa DataType || return mods
    _push_module!(mods, parentmodule(base))
    for P in base.parameters
        _push_type_modules!(mods, P, depth + 1)
    end
    return mods
end

function _trim_subprocess_script(in_paths::Vector{String}, out_path::String, modnames::Vector{Symbol})
    load = join(
        [
            """
            try
                @eval using $name
            catch
            end
            """ for name in modnames
        ], "\n"
    )
    # Only `StrictModeTest` is loaded by name. `Serialization` is reached through it rather than
    # with a `using` of its own: under `Pkg.test()` the child runs in the temporary test
    # environment, where Serialization is a dependency of this package but not a direct dependency
    # of that environment — so `using Serialization` there is an ArgumentError.
    #
    # One child verifies every signature it is given. Starting Julia, loading the packages and
    # applying the patches is the whole cost, and it is the same cost for fifty signatures as for
    # one. Each signature is read from its own file inside a `try`, so a function the child cannot
    # resolve costs that one signature its verdict rather than the whole run's.
    return """
    using StrictModeTest
    $load
    StrictModeTest.set_juliac_patches!(true)
    __patched = StrictModeTest._apply_juliac_patches()
    __results = Any[]
    for __path in $(repr(in_paths))
        __r = try
            __f, __types = StrictModeTest.deserialize(__path)
            StrictModeTest._trim_validate_here(__f, __types)
        catch
            nothing
        end
        push!(__results, __r)
    end
    StrictModeTest.serialize($(repr(out_path)), (__patched, __results))
    """
end

"""
    _trim_validate_subprocess(sigs::Vector) -> Union{Nothing, Vector}

Verify every `(f, argtypes)` in `sigs` against juliac's patched Base, in ONE child process.

Returns a vector parallel to `sigs` holding each verdict, with `nothing` for a signature the child
could not resolve — or `nothing` for the whole call when the child failed outright or ran on a
build shipping no juliac patches, since that verdict would carry the very false-FAIL class this
path exists to remove.
"""
function _trim_validate_subprocess(sigs::Vector)
    isempty(sigs) && return nothing
    in_paths = String[]
    out_path, out_io = mktemp()
    close(out_io)
    try
        for (f, argtypes) in sigs
            path, io = mktemp()
            # Windows refuses to unlink a file that is still open (EBUSY), where Linux and macOS
            # allow it — so dropping `mktemp`'s IO on the floor is a leak that only ever fails on
            # one platform.
            try
                serialize(io, (f, argtypes))
            finally
                close(io)
            end
            push!(in_paths, path)
        end
        mods = Symbol[]
        for (f, argtypes) in sigs, name in _trim_child_modules(f, argtypes)
            name in mods || push!(mods, name)
        end
        script = _trim_subprocess_script(in_paths, out_path, mods)
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $script`
        # The child's stderr is kept, not discarded: when it fails, that text is the only account of
        # why, and a silent decline here reads identically to "juliac ships no patches on this
        # build" — two very different situations for whoever is reading the fallback warning.
        err = IOBuffer()
        ok = success(pipeline(ignorestatus(cmd); stdout = devnull, stderr = err))
        if !ok
            _TRIM_CHILD_STDERR[] = String(take!(err))
            return nothing
        end
        r = open(deserialize, out_path)
        r isa Tuple{Bool, Vector} || return nothing
        patched, results = r
        # The child ran, but without the patches: none could be found (`_juliac_patch_dir`).
        patched || return nothing
        length(results) == length(sigs) || return nothing
        return results
    catch
        return nothing
    finally
        for path in in_paths
            try
                rm(path; force = true)
            catch
            end
        end
        try
            rm(out_path; force = true)
        catch
        end
    end
end

# Verdicts for a whole gate, keyed by signature. `_gate` fills this before any finding is computed
# and empties it afterwards, so one child process serves every signature in the gate instead of one
# each. A miss is not a failure: the signature is then verified on its own.
const _TRIM_BATCH = Dict{Tuple{Any, Vector{Any}}, Any}()

_argtypes(@nospecialize(types)) =
    (types isa Type && types <: Tuple) ? collect(types.parameters) : collect(types)

function _trim_batch!(sigs::Vector)
    empty!(_TRIM_BATCH)
    (_JULIAC_PATCHES[] && !isempty(sigs)) || return _TRIM_BATCH
    results = _trim_validate_subprocess(sigs)
    isnothing(results) && return _TRIM_BATCH
    for (i, sig) in enumerate(sigs)
        isnothing(results[i]) || (_TRIM_BATCH[sig] = results[i])
    end
    return _TRIM_BATCH
end

"""
    _trim_validate(f, types) -> (passed, findings, sites, oracle)

`oracle` names what produced the verdict, and callers must report it rather than claim juliac:
`:patched` is the program `juliac --trim=safe` compiles, verified in a child; `:stock` is the
TrimCheck verifier against this session's own Base, which rejects some code juliac builds clean
(issue #19).
"""
function _trim_validate(@nospecialize(f), @nospecialize(types))
    f, types = _backend_call(f, _argtypes(types))
    argtypes = _argtypes(types)
    if _JULIAC_PATCHES[]
        cached = get(_TRIM_BATCH, (f, argtypes), nothing)
        isnothing(cached) || return (cached..., :patched)
        r = _trim_validate_subprocess([(f, argtypes)])
        isnothing(r) || isnothing(r[1]) || return (r[1]..., :patched)
        @warn "StrictModeTest: could not run the patched trim verification in a subprocess for " *
            "`$(StrictMode._func_name(f))` (a closure, a function the child cannot load, or a build shipping no " *
            "juliac patches). Falling back to STOCK Base in this process, which rejects some code " *
            "juliac builds clean — a failure here may be a false alarm (issue #19)." *
            (isempty(_TRIM_CHILD_STDERR[]) ? "" : "\n  child stderr: " * first(_TRIM_CHILD_STDERR[], 500)) maxlog = 3
    end
    return (_trim_validate_here(f, argtypes)..., :stock)
end

# The verification itself, in whatever process calls it. The child runs this with the patches
# applied; the parent runs it against stock Base.
function _trim_validate_here(@nospecialize(f), argtypes::Vector)
    rts = StrictMode._base_return_types(f, argtypes)
    if length(rts) != 1
        return (
            false, [
                "could not infer a single concrete return type ($(length(rts)) results); " *
                    "trim verification needs a fully-inferred signature",
            ], Tuple{String, Int}[],
        )
    end
    ret_type = rts[1]
    Comp = TrimCheck.Compiler
    try
        TrimCheck.hook_verify_typeinf_trim() do
            _typeinf_toplevel(
                Comp,
                Any[Core.svec(ret_type, StrictMode._sigtype(f, argtypes))],
                [Base.get_world_counter()],
            )
        end
        return (true, String[], Tuple{String, Int}[])
    catch err
        err isa TrimCheck.TrimVerificationErrors && return _trim_verdict(err)
        rethrow(err)
    end
end

"""
    _trim_verdict(err::TrimVerificationErrors) -> (passed, findings, sites)

Classify what the verifier raised. `err.errors` is a `Vector{Pair{Bool, Any}}` whose `Bool` is
`warn`, and **juliac's own gate fails only on the non-warning entries** — so treating every entry as
a failure reds signatures juliac itself would build (issue #20). A raise carrying nothing but
warnings is a PASS here.

`sites` carries each rejected call site as `(file, line)` so a finding can point at the construct
instead of at the signature that reached it.

Split out from `_trim_validate` so the classification can be tested against hand-built
`TrimVerificationErrors` values — provoking a warnings-only raise from a real signature is not
something a test can arrange deterministically.
"""
# Where a method is defined. Used for the frames above the failing one: their call lines would need
# the caller's optimized IR decompressed, and the API for that differs between supported Julias.
function _ci_location(ci)
    mi = ci isa Core.CodeInstance ? ci.def : nothing
    m = mi isa Core.MethodInstance ? mi.def : nothing
    return m isa Method ? (string(m.file), Int(m.line)) : ("", 0)
end

# Every frame between the rejected statement and the signature under test, innermost first. The
# innermost is the statement's own line; the rest are their methods' locations. `parents` maps a
# `CodeInstance` to the `(caller, statement)` that reached it.
function _trim_error_frames(desc, parents)
    frames = Tuple{String, Int}[]
    try
        for li in Base.IRShow.buildLineInfoNode(desc.codeinfo.debuginfo, nothing, desc.stmtidx)
            push!(frames, (string(li.file), Int(li.line)))
        end
    catch
    end
    ci = desc.codeinst
    # A cycle in the map would otherwise walk forever; no real call chain is this deep.
    for _ in 1:32
        p = get(parents, ci, nothing)
        isnothing(p) && break
        ci = first(p)
        loc = _ci_location(ci)
        first(loc) == "" || push!(frames, loc)
    end
    return frames
end

# The statement a rejection is about, as source-like text: the verifier's own description (
# "unresolved call", "dynamic dispatch") followed by the statement it rejected.
function _trim_statement(desc)
    stmt = try
        first(sprint(show, desc.codeinfo.code[desc.stmtidx]), 160)
    catch
        ""
    end
    d = string(desc.desc)
    return isempty(stmt) ? d : d * ": " * stmt
end

# `(findings, sites)` read from the error objects, or `nothing` when none of them carry the fields
# this reads — in which case the caller falls back to parsing the printed dump.
#
# `sites` names the OUTERMOST frame: the construct usually lives in a dependency, and a verdict
# pointing at the signature under test cannot say so, while a rewrite there would not change it.
# The whole path is kept, never its basename, for the same reason.
function _trim_sites(real, parents)
    findings = String[]
    sites = Tuple{String, Int}[]
    seen = Set{Tuple{String, String, Int}}()
    for (_, desc) in real
        hasproperty(desc, :codeinfo) && hasproperty(desc, :stmtidx) || continue
        frames = _trim_error_frames(desc, parents)
        stmt = _trim_statement(desc)
        file, line = isempty(frames) ? ("", 0) : last(frames)
        (stmt, file, line) in seen && continue
        push!(seen, (stmt, file, line))
        push!(findings, file == "" ? stmt : stmt * "  [" * file * ":" * string(line) * "]")
        file == "" || push!(sites, (file, line))
    end
    isempty(findings) && return nothing
    if length(findings) > 8
        extra = length(findings) - 8
        findings = vcat(findings[1:8], ["… (+$extra more call site(s))"])
    end
    return (findings, sites)
end

function _trim_verdict(err)
    real = filter(p -> !first(p), err.errors)
    nwarn = length(err.errors) - length(real)
    if isempty(real)
        nwarn > 0 && @info "StrictModeTest: juliac's trim verifier raised $nwarn warning(s) for this " *
            "signature and no errors — juliac's own gate accepts that, so this is a PASS." maxlog = 3
        return (true, String[], Tuple{String, Int}[])
    end
    # The error objects carry the statement and the caller chain, so the verdict is read from them
    # directly. Rendering them to text first and parsing that back costs the information this needs
    # and depends on a printer that reaches into `Base.Compiler.TrimVerifier` internals, which do
    # not all exist on every supported Julia.
    structural = _trim_sites(real, err.parents)
    isnothing(structural) || return (false, structural[1], structural[2])
    # Fallback for an error shape this does not recognize: TypeContracts' parser over the printed
    # dump, the same one `explain_trim` uses. Re-wrap so only the real errors reach it; otherwise a
    # warning's call site would be reported as a failing one.
    errs = try
        TrimCheck.TrimVerificationErrors(real, err.parents)
    catch
        err                                   # constructor shape changed: fall back to the whole set
    end
    raw = try
        sprint(show, errs)
    catch
        ""
    end
    tf = TypeContracts.explain_trim_failure(raw)
    if !tf.recognized || isempty(tf.sites)
        return (
            false,
            ["the trim verifier rejected this signature ($(length(real)) error(s); verifier output not recognized)"],
            Tuple{String, Int}[],
        )
    end
    findings = String[]
    sites = Tuple{String, Int}[]
    for s in tf.sites
        # frames are innermost-first ⇒ the outermost frame is the user-relevant call site. The whole
        # path is kept, not its basename: a construct reached through a dependency is otherwise
        # indistinguishable from one in the package under test, and the two call for opposite
        # responses.
        if isempty(s.frames)
            push!(findings, s.statement)
            continue
        end
        frame = last(s.frames)
        file, line = string(frame.file), Int(frame.line)
        push!(findings, s.statement * "  [" * file * ":" * string(line) * "]")
        push!(sites, (file, line))
    end
    if length(findings) > 8
        extra = length(findings) - 8
        findings = vcat(findings[1:8], ["… (+$extra more call site(s))"])
    end
    return (false, findings, sites)
end

# Name the oracle in the failure text. A verdict from stock Base is not a juliac verdict: juliac
# compiles a patched Base, so a rejection here can be a construct juliac accepts (issue #19), and a
# message claiming otherwise sends a reader to rewrite correct code.
function _trim_reason(oracle::Symbol, fnds::Vector{String})
    joined = join(fnds, "; ")
    oracle === :patched && return "trim-incompatible (juliac --trim=safe, patched Base): " * joined
    return "trim-incompatible (TrimCheck verifier, stock Base, in-process): " * joined *
        " — juliac compiles a patched Base this did not check; " *
        "`StrictModeTest.set_juliac_patches!(true)` verifies the patched program"
end

# ── the proof engine ─────────────────────────────────────────────────────────────────────────────

"""
    StrictModeTest.proof_findings(f, types; guarantees = (:typestable, :noalloc), allow_exempt = false)
        -> Vector{StrictFinding}

One [`StrictMode.StrictFinding`](@ref) per requested guarantee, computed with the proofs rather
than StrictMode's value-free scan. `f` is never called. This is the data half of the gating API;
`test_signatures`/`test_compiled`/`test_registered` add the raise.
"""
proof_findings(
    @nospecialize(f), @nospecialize(types::Tuple);
    guarantees = (:typestable, :noalloc), allow_exempt::Bool = false
) = _proof_findings(f, types, guarantees; allow_exempt)

# What a caller is told to do about an exempt-only result.
const _EXEMPT_ONLY_FIX = "every allocation is inside a function exempted from :noalloc. Accept " *
    "the exemptions listed for this check with `allow_exempt = true`, or remove the " *
    "allocation or the exemption"

function _proof_findings(
        @nospecialize(f), @nospecialize(types::Tuple), guarantees; allow_exempt::Bool = false
    )
    fn, sg, md = StrictMode._func_name(f), StrictMode._sig_string(f, types), StrictMode._mod_sym(f, types)
    target = fn * sg
    # AllocCheck runs at most once per signature even when both allocation guarantees are asked
    # for: the boxing verdict is a filter over the same instance list.
    checked, alloc_error = if :noalloc in guarantees || :noboxing in guarantees
        try
            (_checked_allocs(f, types), nothing)
        catch err
            err isa StrictViolation && rethrow()
            (nothing, sprint(showerror, err))
        end
    else
        (nothing, nothing)
    end
    allocs = isnothing(checked) ? nothing : checked[1]
    # The sites kept because the call graph does not name their specialization (`_off_graph`).
    unplaced = isnothing(checked) ? Any[] : checked[3]
    out = StrictFinding[]
    for g in guarantees
        shared = StrictMode._compiled_output_finding(g, f, types, md, fn, sg; tier = :proof)
        if !isnothing(shared)
            push!(out, shared)
        elseif g === :typestable
            push!(out, _typestable_finding(target, f, types, md, fn, sg))
        elseif g === :noalloc
            if isnothing(allocs)
                push!(out, _unproven(md, fn, sg, g, "AllocCheck could not analyze this signature: $alloc_error"))
            else
                # The sites inside functions exempt from `:noalloc` are set aside first, as the scan
                # sets them aside, and the call's own sites decide the result: none of its own is
                # the exempt-only result, own sites that all wait are a wait, anything else is an
                # allocation.
                own, by, offgraph = _exempt_split(allocs, StrictMode._entry_key(f, types))
                note = _unplaced_note(filter(a -> any(u -> u === a, unplaced) || any(u -> u === a, offgraph), own))
                file, line = _first_loc(isempty(own) ? allocs : own, false)
                nexempt = length(allocs) - length(own)
                if !isempty(own) && all(_scheduler_site, own)
                    push!(
                        out, _mkproof(
                            md, fn, sg, g, true,
                            "blocks in the task scheduler: AllocCheck reports $(length(own)) site(s)" *
                                (nexempt > 0 ? " outside functions exempt from :noalloc" : "") * ", all in " *
                                "Base's task, lock and condition code (first: $(basename(file)):$line). It " *
                                "waits for another task, so it can allocate." * note,
                            file, line,
                            "if the wait is a pool join that is expected, register the function that joins " *
                                "with `register_alloc_barrier!` or exempt it with `@strict_exempt` by name";
                            cause = :scheduler
                        )
                    )
                elseif isempty(own) && !isempty(allocs)
                    # Every site lies inside a function exempt from `:noalloc`. That is not a
                    # proof of no allocation, so it is a FAILURE with its own code: counted by
                    # `nfailures`, failed by every gate, not a pass to any reader of the status.
                    # A caller that accepts the exemptions by name gets the note in its place.
                    push!(
                        out, StrictMode.StrictFinding(
                            md, fn, sg, g, allow_exempt ? :info : :fail, file, line,
                            "allocates only inside " * (length(by) == 1 ? "a function" : "functions") *
                                " exempt from :noalloc ($(length(allocs)) site(s)): " *
                                join(("`" * n * "`" * (isempty(r) ? "" : " (" * r * ")") for (n, r) in by), ", "),
                            allow_exempt ? "" : _EXEMPT_ONLY_FIX, :proof, :SM0018, "", by
                        )
                    )
                else
                    push!(
                        out, _mkproof(
                            md, fn, sg, g, !isempty(allocs),
                            "allocates ($(length(allocs)) site(s))" * _widened_sites_note(f, types, allocs) *
                                (isempty(note) ? "" : "." * note), file, line
                        )
                    )
                end
            end
        elseif g === :noboxing
            if isnothing(allocs)
                push!(out, _unproven(md, fn, sg, g, "AllocCheck could not analyze this signature: $alloc_error"))
            else
                boxing = filter(_is_boxing, allocs)
                file, line = _first_loc(allocs, true)
                push!(
                    out, _mkproof(
                        md, fn, sg, g, !isempty(boxing),
                        "boxing / dynamic dispatch" * _widened_sites_note(f, types, boxing), file, line
                    )
                )
            end
        elseif g === :trim_compatible
            passed, fnds, sites, oracle = _trim_validate(f, Tuple{types...})
            # The rejected call site, where there is one, rather than the signature that reached it:
            # the construct frequently lives in a dependency, and a finding pointing at the function
            # under test cannot say so — a rewrite there would not change the verdict.
            m = try
                StrictMode._which(f, types)
            catch
                nothing
            end
            file = isempty(sites) ? (isnothing(m) ? "" : string(m.file)) : sites[1][1]
            line = isempty(sites) ? (isnothing(m) ? 0 : Int(m.line)) : sites[1][2]
            push!(
                out, _mkproof(
                    md, fn, sg, g, !passed, _trim_reason(oracle, fnds), file, line
                )
            )
        else
            throw(ArgumentError("unknown guarantee :$g; expected one of $(StrictMode._GUARANTEES)"))
        end
    end
    # A proof of a signature that returns on no path proved nothing about one that does.
    return StrictMode._always_throws(f, types) ? StrictMode._mark_always_throws(out) : out
end

# Two layers, both authoritative here: the inferred return type must be concrete, and JET's
# optimization analysis must be clean. StrictMode's own `:typestable` uses an IR boxing signal for
# the second layer, which is why it only warns; this is the proof that replaces it.
function _typestable_finding(target, @nospecialize(f), @nospecialize(types::Tuple), md, fn, sg)
    rts = StrictMode._base_return_types(f, types)
    if length(rts) != 1 || !StrictMode._is_typestable_return(only(rts))
        rt = isempty(rts) ? "none" : (length(rts) == 1 ? string(only(rts)) : string(rts))
        cause = StrictMode._instability_cause(f, types)
        reason = "return type $rt is not concrete (inference)"
        isnothing(cause) || (reason *= " — " * StrictMode._cause_reason(cause...))
        return _mkproof(
            md, fn, sg, :typestable, true, reason, "", 0,
            isnothing(cause) ? "" : StrictMode._cause_suggestion(cause[1]);
            cause = isnothing(cause) ? nothing : cause[1]
        )
    end
    # An optimization-failure report says one frame produced no optimized IR (typically a recursive
    # cycle). It does NOT say a type is unknown, so it is logged rather than failed — issue #30 dropped
    # the ones located in another module, and issue #31 drops the rest from the verdict.
    #
    # It does cost coverage, though: JET's dispatch analysis runs on optimized IR, so a bailed frame
    # can never report a dispatch from its own body. `_bail_frame_dispatches` scans those bodies
    # directly, and a dynamic call found there fails the guarantee like any other.
    reports = _opt_reports(target, f, types)
    bails = filter(r -> r isa JET.OptimizationFailureReport, reports)
    uncertain = filter(r -> !(r isa JET.OptimizationFailureReport), reports)
    bailsites = String[]
    for r in bails
        append!(bailsites, _bail_frame_dispatches(r))
    end
    if !isempty(bails)
        @info "StrictModeTest: $target — $(length(bails)) frame(s) produced no optimized IR " *
            "(typically a recursive cycle): $(join(unique(_report_location.(bails)), "; ")). " *
            "The types are known; this costs optimization, not type stability. Those frames' own " *
            "bodies were scanned for runtime dispatch separately." maxlog = 1 _id = Symbol(:bail, target)
    end
    if !isempty(uncertain) || !isempty(bailsites)
        cause = StrictMode._instability_cause(f, types)
        parts = String[]
        isempty(uncertain) || push!(
            parts, "$(length(uncertain)) JET report(s): " *
                join(unique(_report_location.(uncertain)), "; ")
        )
        isempty(bailsites) || push!(
            parts, "runtime dispatch in an unoptimized frame: " * join(unique(bailsites), "; ")
        )
        reason = "internal instability / runtime dispatch (" * join(parts, " | ") * ")"
        isnothing(cause) || (reason *= " — " * StrictMode._cause_reason(cause...))
        return _mkproof(
            md, fn, sg, :typestable, true, reason, "", 0,
            isnothing(cause) ? "" : StrictMode._cause_suggestion(cause[1]);
            cause = isnothing(cause) ? nothing : cause[1]
        )
    end
    # F39. JET cannot see this class at all: a union-typed local that boxes a member on the way in is
    # not dynamic dispatch, so `@report_opt` is silent at every signature. Without this the proof
    # would be WEAKER than the scan it is supposed to settle — `@assert_typestable` catches it and
    # `@test_typestable` would wave it through.
    unionphi = StrictMode._alloc_signals(f, types; depth = 0, wide = false).unionphi
    return _mkproof(
        md, fn, sg, :typestable, unionphi,
        "a union-typed local carries a member that must be boxed to flow through it " *
            "(concrete return, and invisible to JET)", "", 0
    )
end
