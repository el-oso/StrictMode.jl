# The interference-proof core: run guarantees on a `(function, types)` pair with no macro parsing
# and no execution. Everything else (the macros via `@explain`, the registry, the agent audit, the
# Revise loop) reuses this. Every guarantee is computed from `(f, types)` alone.

_sig_string(@nospecialize(types::Tuple)) = "(" * join(types, ", ") * ")"
_func_name(@nospecialize(f)) = try
    string(nameof(f))
catch
    string(f)
end
_mod_sym(@nospecialize(f)) = try
    nameof(parentmodule(f))
catch
    :Main
end

# Build the underlying `StrictReport` from `(f, types)`, calling JET (via the backend) in its
# function form.
function _strict_report(target, @nospecialize(f), @nospecialize(types::Tuple))
    _require_backend()
    opt = try
        _be_opt_result(f, types)
    catch
        nothing
    end
    return _explain(target, f, types, opt)
end

# First source location among allocation sites (any / boxing-only), pulled from the backtraces.
function _first_loc(allocs, boxing_only::Bool)
    allocs === nothing && return ("", 0)
    for a in allocs
        boxing_only && !_be_is_boxing(a) && continue
        bt = a.backtrace
        isempty(bt) || return (string(bt[1].file), Int(bt[1].line))
    end
    return ("", 0)
end

_mkfinding(md, fn, sg, g, fail::Bool, reason, file, line) = StrictFinding(
    md, fn, sg, g, fail ? :fail : :pass, file, line, fail ? reason : "", fail ? _suggestion(g) : ""
)

function _build_finding(g::Symbol, @nospecialize(f), @nospecialize(types::Tuple), rep, md, fn, sg)
    if g === :typestable
        fail = would_fail_typestable(rep)
        return _mkfinding(md, fn, sg, g, fail, "return type $(rep.return_type) is not concrete / internal instability", "", 0)
    elseif g === :noalloc
        fail = would_fail_noalloc(rep)
        file, line = _first_loc(rep.allocs, false)
        n = rep.allocs === nothing ? "?" : string(length(rep.allocs))
        return _mkfinding(md, fn, sg, g, fail, "allocates ($n site(s))", file, line)
    elseif g === :noboxing
        fail = would_fail_noboxing(rep)
        file, line = _first_loc(rep.allocs, true)
        return _mkfinding(md, fn, sg, g, fail, "boxing / dynamic dispatch", file, line)
    elseif g === :inlined
        fail = _inlined_survives(f, types) === true
        return _mkfinding(md, fn, sg, g, fail, "not inlined (survives as :invoke)", "", 0)
    end
    throw(ArgumentError("unknown guarantee :$g; expected :typestable, :noalloc, :noboxing, or :inlined"))
end

"""
    findings(f, types; guarantees = (:typestable, :noalloc)) -> Vector{StrictFinding}

Analyze `f` for the concrete signature `types` and return one [`StrictFinding`](@ref) per
requested guarantee. Pure analysis — `f` is never called.
"""
function findings(@nospecialize(f), @nospecialize(types::Tuple); guarantees = (:typestable, :noalloc))
    fn, sg, md = _func_name(f), _sig_string(types), _mod_sym(f)
    rep = _strict_report(fn * sg, f, types)
    return StrictFinding[_build_finding(g, f, types, rep, md, fn, sg) for g in guarantees]
end

"""
    check(f, types; guarantees = (:typestable, :noalloc), fail = fail_mode()) -> Vector{StrictFinding}

Check the guarantees for `f`'s concrete signature `types` and return the findings. A plain
function call — it never parses syntax, so unlike the macros it cannot collide with broadcasting,
nested macros, or keyword arguments. Use it as the robust escape hatch and as the programmatic
entry point for automation.

`fail = :error` (the default outside `:warn` mode) throws a [`StrictViolation`](@ref) aggregating
the failures; `:warn` logs them; `:none` returns the findings without raising.

```julia
check(dot3, (NTuple{3,Float64}, NTuple{3,Float64}))          # ok → all :pass
check(boxy, (Tuple{Int,Float64,Float32},); guarantees=(:noboxing,))   # throws StrictViolation
```
"""
function check(@nospecialize(f), @nospecialize(types::Tuple); guarantees = (:typestable, :noalloc), fail::Symbol = fail_mode())
    fs = findings(f, types; guarantees)
    failed = filter(_failed, fs)
    if !isempty(failed) && fail !== :none
        msg = sprint(io -> format_findings(io, failed; format = :text))
        fail === :error ? throw(StrictViolation(:check, _func_name(f) * _sig_string(types), msg)) : @warn msg
    end
    return fs
end
