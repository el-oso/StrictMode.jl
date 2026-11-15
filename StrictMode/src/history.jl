# Results that depend on the process's history: a call whose bits change after other calls have run
# in the same process. Two halves. `history_report` measures it, by running the call, then calls
# that move state, then the call again, and comparing bits. `state_branch_report` finds where it can
# start: a branch whose condition reads mutable global state, so that which code runs — and, when the
# two sides compute differently, which bits come out — depends on what ran before.

"""
    StrictMode.HistoryReport

What [`history_report`](@ref) measured. `same` is whether the result and the arguments matched,
bit for bit, before and after the movers ran; `first_bytes` and `after_bytes` are the sizes of the
two serialized results, so a mismatch in size is visible without a byte dump.
"""
struct HistoryReport
    target::String
    same::Bool
    movers::Int
    first_bytes::Int
    after_bytes::Int
end

function Base.show(io::IO, ::MIME"text/plain", r::HistoryReport)
    print(io, "HistoryReport: ", r.target, " — ")
    return if r.same
        print(io, "the same bits after ", r.movers, " state mover(s)")
    else
        print(
            io, "DIFFERENT bits after ", r.movers, " state mover(s): the result depends on what ran ",
            "before it in this process (", r.first_bytes, " B then ", r.after_bytes, " B serialized)"
        )
    end
end

# The bits of a value, as Serialization writes them: floating-point values bit for bit, structure
# included. Two results compare equal here only if every bit does.
function _history_bits(@nospecialize(x))
    io = IOBuffer()
    serialize(io, x)
    return take!(io)
end

"""
    history_report(f, args...; movers = ()) -> HistoryReport

Whether `f(args...)` gives the same bits after other calls have run in the same process.

It calls `f` on a copy of the arguments, then each function in `movers` (calls that change state the
package keeps between calls — a thread count, a tuning knob, a large call that grows a pool or
moves a measured threshold), then `f` on a fresh copy again, and compares the result and the
arguments afterwards, bit for bit.

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
    a1 = deepcopy(args)
    r1 = f(a1...)
    first = _history_bits((r1, a1))
    for m in movers
        m()
    end
    a2 = deepcopy(args)
    r2 = f(a2...)
    after = _history_bits((r2, a2))
    target = _func_name(f) * _sig_string(map(Core.Typeof, args))
    return HistoryReport(target, first == after, length(movers), length(first), length(after))
end

# ── where history can enter: branches on mutable global state ───────────────────────────────────

# A constant global of the package holding a mutable value: a `Ref`, an atomic, an array, a
# `OncePer*` guard, any mutable struct. Base's and Core's own globals are not the package's history.
function _package_state_global(@nospecialize(a))
    a isa GlobalRef || return nothing
    root = Base.moduleroot(a.mod)
    (root === Base || root === Core) && return nothing
    (isdefined(a.mod, a.name) && isconst(a.mod, a.name)) || return nothing
    v = getglobal(a.mod, a.name)
    (v isa Function || v isa Type || v isa Module || v isa String || v isa Symbol) && return nothing
    return ismutable(v) ? a.name : nothing
end

# The package's mutable globals a lowered value depends on, through SSA values, local variables and,
# `depth` levels deep, the return values of the package's own callees.
function _state_reads!(out::Set{Symbol}, src::Core.CodeInfo, @nospecialize(x), seen::Set{Any}, depth::Int)
    x in seen && return out
    push!(seen, x)
    g = _package_state_global(x)
    isnothing(g) || return push!(out, g)
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
                nameof(mod), string(m.name), string(m.sig), :state_branch, :info,
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
