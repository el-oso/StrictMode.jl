# The heavy-analysis backend. Loaded only when both AllocCheck and JET are present in the
# environment (they are weak dependencies of StrictMode). This is the only place that touches
# AllocCheck / JET — it fills in the four backend functions declared in `src/backend.jl` and
# flips `backend_available()` on.

module StrictModeAnalysisExt

using StrictMode
using AllocCheck
using JET
using PrecompileTools: @setup_workload, @compile_workload

# --- backend seam implementations ---

StrictMode._be_check_allocs(@nospecialize(f), @nospecialize(types)) = AllocCheck.check_allocs(f, types)

StrictMode._be_opt_result(@nospecialize(f), @nospecialize(types)) = JET.report_opt(f, types)

StrictMode._be_opt_reports(@nospecialize(r)) = JET.get_reports(r)

# Is this AllocCheck instance a *boxing* / dynamic-dispatch allocation (driven by type
# uncertainty), as opposed to a legitimate typed heap allocation (a `Vector`, `Memory`, …)?
function StrictMode._be_is_boxing(@nospecialize(inst))
    inst isa AllocCheck.DynamicDispatch && return true
    if inst isa AllocCheck.AllocatingRuntimeCall
        n = inst.name
        # jl_box_int64 (boxing a primitive), jl_get_nth_field_checked (runtime tuple/field index
        # → boxing). Excludes array-grow / string runtime calls.
        return occursin("box", lowercase(n)) || occursin("get_nth_field", n)
    end
    inst isa AllocCheck.AllocationSite && return inst.type === Core.Box   # captured-variable box
    return false
end

# Warm JET + AllocCheck into this extension's precompile image so the first interactive check is
# fast — but only when checks are enabled (otherwise nobody runs them).
@setup_workload begin
    wk_dot(a, b) = @inbounds a[1] * b[1] + a[2] * b[2]
    A = (1.0, 2.0)
    B = (3.0, 4.0)
    types = (typeof(A), typeof(B))
    @compile_workload begin
        if StrictMode.CHECKS_ENABLED
            StrictMode._BACKEND_AVAILABLE[] = true
            try
                StrictMode.check(wk_dot, types; guarantees = (:typestable, :noalloc, :noboxing, :inlined), fail = :none)
                StrictMode._strict_report("warmup", wk_dot, types)   # warms @explain (+ @code_warntype)
            catch
            finally
                StrictMode._BACKEND_AVAILABLE[] = false               # reset; __init__ sets it at load
            end
        end
    end
end

function __init__()
    StrictMode._BACKEND_AVAILABLE[] = true
    return nothing
end

end # module StrictModeAnalysisExt
