# Results that depend on the process's history: a call whose bits change after other calls have run
# in the same process. Two halves. `history_report` measures it, by running the call, then calls
# that move state, then the call again, and comparing bits. `state_branch_report` finds where it can
# start: a branch whose condition reads mutable global state, so that which code runs — and, when the
# two sides compute differently, which bits come out — depends on what ran before.

"""
    StrictMode.HistoryReport

What [`history_report`](@ref) measured. `status` is `:same` (the same bits after the movers),
`:different` (different bits after the movers, with the same bits between two calls run back to
back), `:first_call` (the first call differs from the second and third, which agree: the first call
leaves state behind that changes the result), or `:nondeterministic` (every call differs, so a
difference after the movers cannot be put down to them). `difference` names where the first differing bit was found.
"""
struct HistoryReport
    target::String
    status::Symbol
    movers::Int
    difference::String
end

function Base.getproperty(r::HistoryReport, s::Symbol)
    s === :same && return getfield(r, :status) === :same
    return getfield(r, s)
end

function Base.show(io::IO, ::MIME"text/plain", r::HistoryReport)
    print(io, "HistoryReport: ", r.target, " — ")
    if r.status === :same
        print(io, "the same bits after ", r.movers, " state mover(s)")
    elseif r.status === :different
        print(
            io, "DIFFERENT bits after ", r.movers, " state mover(s), at ", r.difference,
            ": the result depends on what ran before it in this process"
        )
    elseif r.status === :first_call
        print(
            io, "the FIRST call differs from the calls after it, at ", r.difference,
            ": the first call leaves state behind that changes the result"
        )
    else
        print(
            io, "not deterministic: two calls with nothing between them already differ, at ",
            r.difference, ", so the movers cannot be judged"
        )
    end
end

# Where two values first differ, bit for bit, or `nothing`. Floating-point values compare by their
# bits, so `-0.0` and `0.0` differ and a `NaN` equals itself; a `BigFloat` by value, sign and
# precision, since its limbs live behind a pointer; a pointer by its address; a dictionary by key, so
# its iteration order does not count; a struct field by field.
function _first_difference(@nospecialize(a), @nospecialize(b), path::String = "the result", depth::Int = 0)
    typeof(a) === typeof(b) || return path * " (type $(typeof(a)) vs $(typeof(b)))"
    depth > 32 && return nothing
    if isbits(a)
        return a === b ? nothing : path
    elseif a isa BigFloat
        same = precision(a) == precision(b) && (isnan(a) ? isnan(b) : (a == b && signbit(a) == signbit(b)))
        return same ? nothing : path
    elseif a isa Union{BigInt, AbstractString, Symbol, Module, Function, Type}
        return isequal(a, b) ? nothing : path
    elseif a isa AbstractArray
        size(a) == size(b) || return path * " (size)"
        for i in eachindex(a, b)
            (isassigned(a, i) == isassigned(b, i)) || return path * "[$i]"
            isassigned(a, i) || continue
            d = _first_difference(a[i], b[i], path * "[$i]", depth + 1)
            isnothing(d) || return d
        end
        return nothing
    elseif a isa AbstractDict
        length(a) == length(b) || return path * " (length)"
        for (k, v) in a
            haskey(b, k) || return path * " (key $(repr(k)))"
            d = _first_difference(v, b[k], path * "[$(repr(k))]", depth + 1)
            isnothing(d) || return d
        end
        return nothing
    end
    for i in 1:nfields(a)
        isdefined(a, i) == isdefined(b, i) || return path * ".$(fieldname(typeof(a), i))"
        isdefined(a, i) || continue
        d = _first_difference(getfield(a, i), getfield(b, i), path * ".$(fieldname(typeof(a), i))", depth + 1)
        isnothing(d) || return d
    end
    return nothing
end

"""
    history_report(f, args...; movers = ()) -> HistoryReport

Whether `f(args...)` gives the same bits after other calls have run in the same process.

It calls `f` twice back to back on fresh copies of the arguments, as a control, then each function
in `movers` (calls that change state the package keeps between calls — a thread count, a tuning
knob, a large call that grows a pool or moves a measured threshold), then `f` once more, and
compares the result and the arguments afterwards, bit for bit. When the two control calls already
differ, a third call tells why. If it repeats the second, the status is `:first_call`: the first
call left state behind that changes the result, such as a workspace created on first use. If it
differs again — a result built from `rand()`, an `objectid`, a timer, a reduction whose order
varies — the status is `:nondeterministic`, and the movers cannot be judged.

The arguments are copied with `deepcopy` before each call, so state a call keeps in its own
arguments starts fresh each time; a mover that should move such state must change the original
arguments it closes over.

[`threadcount_invariant_report`](@ref) runs each thread count in a fresh process, so a result that
depends on the history of its own process looks invariant there. This one runs everything in one
process, which is where such a dependence shows.

Value-based: it runs the call, like [`steady_state_report`](@ref). The gating form is
`StrictModeTest.test_history_invariant`.

```julia
history_report(gemm!, C, A, B; movers = (() -> gemm!(Cbig, Abig, Bbig),))
```
"""
function history_report(@nospecialize(f), args...; movers = ())
    target = _func_name(f) * _sig_string(map(Core.Typeof, args))
    call() = (a = deepcopy(args); r = f(a...); (r, a))
    # The result, then each argument as the call left it, so a difference is named by where it is.
    function differ(x, y)
        local d = _first_difference(x[1], y[1], "the result")
        isnothing(d) || return d
        for k in eachindex(x[2])
            d = _first_difference(x[2][k], y[2][k], "argument $k")
            isnothing(d) || return d
        end
        return nothing
    end
    first_run = call()
    control = call()
    d = differ(first_run, control)
    if !isnothing(d)
        # A third call tells the two apart: when it repeats the second, only the first call differed,
        # so the first call left state behind that changes the result. When it differs again, the
        # result is not a function of its inputs at all.
        third = call()
        repeat = isnothing(differ(control, third))
        return HistoryReport(target, repeat ? :first_call : :nondeterministic, length(movers), d)
    end
    for m in movers
        m()
    end
    after = call()
    d = differ(control, after)
    return HistoryReport(target, isnothing(d) ? :same : :different, length(movers), something(d, ""))
end

# ── where history can enter: branches on mutable global state ───────────────────────────────────

# A global of the package whose value can change between calls: a non-constant binding, or a
# constant holding mutable state anywhere inside it — a `Ref`, an atomic, an array, a `OncePer*` guard,
# a mutable struct, or an immutable struct carrying one. Base's and Core's own globals are not the
# package's history.
function _package_state_global(@nospecialize(a))
    a isa GlobalRef || return nothing
    root = Base.moduleroot(a.mod)
    (root === Base || root === Core) && return nothing
    isdefined(a.mod, a.name) || return nothing
    v = getglobal(a.mod, a.name)
    (v isa Type || v isa Module) && return nothing
    isconst(a.mod, a.name) || return (v isa Function ? nothing : a.name)
    return _holds_mutable(v) ? a.name : nothing
end

function _holds_mutable(@nospecialize(v), depth::Int = 0)
    (v isa String || v isa Symbol || v isa Module || v isa Type) && return false
    ismutable(v) && return true                    # an immutable function (a plain one) is not
    (depth < 3 && !isbits(v)) || return false
    return any(i -> isdefined(v, i) && _holds_mutable(getfield(v, i), depth + 1), 1:nfields(v))
end

# The package's mutable globals a lowered value depends on, through SSA values, local variables and,
# `depth` levels deep, the return values of the package's own callees.
function _state_reads!(out::Set{Symbol}, src::Core.CodeInfo, @nospecialize(x), seen::Set{Any}, depth::Int)
    x in seen && return out
    push!(seen, x)
    g = _package_state_global(x)
    isnothing(g) || return push!(out, g)
    # `M.name` on a module lowers to `getproperty(M, :name)`: the same global read.
    if Meta.isexpr(x, :call) && length(x.args) == 3 && src isa Core.CodeInfo
        c = _lowered_callee(src.code, x.args[1])
        if c === getproperty || c === getfield
            M = _lowered_callee(src.code, x.args[2])
            nm = x.args[3] isa QuoteNode ? x.args[3].value : x.args[3]
            if M isa Module && nm isa Symbol
                g = _package_state_global(GlobalRef(M, nm))
                isnothing(g) || return push!(out, g)
            end
        end
    end
    if x isa Core.SSAValue
        _state_reads!(out, src, src.code[x.id], seen, depth)
    elseif x isa Core.SlotNumber
        for st in src.code
            Meta.isexpr(st, :(=)) && st.args[1] == x && _state_reads!(out, src, st.args[2], seen, depth)
        end
    elseif x isa Expr
        for a in x.args
            _state_reads!(out, src, a, seen, depth)
        end
        if x.head === :call && depth > 0 && !isempty(x.args)
            callee = _lowered_callee(src.code, x.args[1])
            if callee isa Function
                root = Base.moduleroot(parentmodule(callee))
                if !(root === Base || root === Core)
                    for m in methods(callee)
                        Base.moduleroot(m.module) === root || continue
                        csrc = try
                            Base.uncompressed_ast(m)
                        catch
                            continue
                        end
                        for st in csrc.code
                            (st isa Core.ReturnNode && isdefined(st, :val)) || continue
                            _state_reads!(out, csrc, st.val, Set{Any}(), depth - 1)
                        end
                    end
                end
            end
        end
    end
    return out
end

"""
    state_branch_report(mod::Module; only = nothing, exempt = ()) -> Vector{StrictFinding}

Every method in `mod` with a branch whose condition reads mutable global state the package owns: a
`Ref`, an atomic, a global array, a `OncePer*` value, or a callee of the package returning one. One
`:info` finding per method, naming the globals.

Such a branch makes which code runs depend on what ran before in the process. That is harmless when
both sides compute the same bits, as when the branch only decides whether to use threads, and it is
a reproducibility defect when they do not, as when it picks between two kernels that round
differently. The IR cannot tell those apart, so this lists every such branch for review rather than
failing. [`history_report`](@ref) measures whether a given call's bits actually change.

Read from lowered code, with the package's own callees followed two levels for the value the
condition uses.

```julia
state_branch_report(MyBLAS)
```
"""
function state_branch_report(mod::Module; only = nothing, exempt = ())
    out = StrictFinding[]
    ms, _ = module_methods(mod; only, exempt)
    for m in ms
        isdefined(m, :generator) && continue
        src = try
            Base.uncompressed_ast(m)
        catch
            continue
        end
        reads = Set{Symbol}()
        for st in src.code
            st isa Core.GotoIfNot || continue
            _state_reads!(reads, src, st.cond, Set{Any}(), 2)
        end
        isempty(reads) && continue
        names = join(("`" * String(n) * "`" for n in sort!(collect(reads))), ", ")
        push!(
            out, StrictFinding(
                nameof(mod), string(_demangle(m.name)), string(m.sig), :state_branch, :info,
                string(m.file), Int(m.line),
                "branches on mutable global state ($names): which code runs depends on what ran " *
                    "before in this process",
                "if the two sides compute differently, decide the route from the arguments and " *
                    "constants only, and keep measured state for decisions that do not change the " *
                    "bits; `history_report` measures whether a call's result moves",
                :report, _code(:state_branch, nothing)
            )
        )
    end
    return out
end
