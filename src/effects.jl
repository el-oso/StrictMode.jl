# Cheap, value-free analysis built only on Base inference — no AllocCheck/JET backend. This is
# what makes `:fast` mode a quick all-properties triage: a `code_typed` IR scan for allocation /
# boxing signals, plus `Base.infer_effects`. `:full` mode keeps AllocCheck's rigorous proof.
#
# The heuristic is intentionally approximate (the user opted into "fast triage, may rarely
# miss/over-flag"): it catches explicit heap allocation and the boxing/dispatch class, which
# covers the common cases, but cannot match AllocCheck's LLVM-level precision.

# Runtime-call targets that allocate (matched as substrings, case-insensitive).
const _ALLOC_FFI = ("alloc", "gc_pool", "gc_big", "jl_box", "ijl_box", "new_array", "alloc_string")

_nonconcrete(@nospecialize T) = T isa Type && !Base.isconcretetype(T) && T !== Union{} && !(T <: Type)

"""
    _alloc_signals(f, types) -> (; alloc, boxing, file, line)

Value-free allocation heuristic from optimized typed IR (no execution, no backend). `alloc` flags
explicit heap allocation (`:new` of a mutable/Array/`Core.Box` type, or a GC/box `:foreigncall`);
`boxing` flags the boxing / dynamic-dispatch subclass (a `:call`/`:invoke` with a non-concrete
result type — e.g. a runtime tuple index). Location is the method's definition site.
"""
function _alloc_signals(@nospecialize(f), @nospecialize(types::Tuple))
    cts = Base.code_typed(f, types; optimize = true)
    isempty(cts) && return (; alloc = false, boxing = false, file = "", line = 0)
    ci, _ = first(cts)
    alloc = false
    boxing = false
    for (i, st) in enumerate(ci.code)
        local T = ci.ssavaluetypes[i]
        if Meta.isexpr(st, :foreigncall)
            tgt = lowercase(string(st.args[1]))
            any(p -> occursin(p, tgt), _ALLOC_FFI) && (alloc = true)
        elseif Meta.isexpr(st, :new)
            nt = st.args[1]
            (nt isa Type && (ismutabletype(nt) || nt <: Array || nt <: Memory || nt === Core.Box)) && (alloc = true)
        elseif Meta.isexpr(st, :call) && _nonconcrete(T)
            # A *dynamic* call / builtin (e.g. a runtime `getfield` on a heterogeneous tuple, or
            # an `Any`-typed dispatch) with a non-concrete result genuinely boxes. A resolved
            # `:invoke` returning a small `Union` is union-split, not boxing — don't flag it
            # (that over-reported on type-stable SIMD/pointer kernels).
            boxing = true
        end
        alloc && boxing && break
    end
    m = try
        which(f, types)
    catch
        nothing
    end
    file = m === nothing ? "" : string(m.file)
    line = m === nothing ? 0 : Int(m.line)
    return (; alloc, boxing, file, line)
end

# --- Base.infer_effects layer (cheap; basis for @assert_effects in Phase 3) -------------------

"""
    StrictMode.effects(f, types) -> Core.Compiler.Effects

The compiler's inferred effects for `f`'s signature — a cheap (inference-only) read of whether a
method is `:nothrow`, `:effect_free`, `:terminates`, `:consistent`, etc. Used by the `:fast`
triage and by `@assert_effects`.
"""
effects(@nospecialize(f), @nospecialize(types::Tuple)) = Base.infer_effects(f, types)

# Predicate by symbol, so callers can ask `effect_holds(eff, :nothrow)`.
function effect_holds(eff, sym::Symbol)
    sym === :nothrow && return Core.Compiler.is_nothrow(eff)
    sym === :effect_free && return Core.Compiler.is_effect_free(eff)
    sym === :terminates && return Core.Compiler.is_terminates(eff)
    sym === :consistent && return Core.Compiler.is_consistent(eff)
    sym === :nonoverlayed && return Core.Compiler.is_nonoverlayed(eff)
    throw(ArgumentError("unknown effect :$sym; expected :nothrow, :effect_free, :terminates, :consistent, or :nonoverlayed"))
end
