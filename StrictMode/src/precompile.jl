# The scan, run once on a toy module while StrictMode itself is precompiled, so that a consumer's own
# precompile (where `@strict_policy` and `@strict_function` run the scan) does not compile the scan
# first: the code it needs is already in this package's image. Measured on an 80-method module, the
# first call of the module check took 1.6 s, and the same call with the code compiled took 0.07 s.
#
# The module that is checked holds only methods that pass, so the check reports nothing; the one that
# allocates is read through `findings`, which returns its verdict and prints none.
module PrecompileWorkload
    @noinline helper(v::Vector{Float64}, n::Int) = v[mod1(n, length(v))] * 2.0
    function kernel(v::Vector{Float64}, n::Int)
        s = 0.0
        for i in 1:n
            s += helper(v, i) + sin(s)
        end
        return s
    end
end

module PrecompileWorkloadAllocating
    grow(n::Int) = (a = Float64[]; push!(a, n); a)
end

# A module also defines `eval` and `include`, which are not what the workload is about and do not pass.
const _WORKLOAD_FUNCTIONS = (:helper, :kernel)

function _precompile_workload()
    # A workload that printed would print at every install of StrictMode, so nothing it reports is shown.
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        for gs in ((:typestable, :noalloc), (:noboxing,), (:noalloc, :noboxing), (:owned,))
            findings(PrecompileWorkload.kernel, (Vector{Float64}, Int); guarantees = gs)
            findings(PrecompileWorkloadAllocating.grow, (Int,); guarantees = gs)
        end
        items = _module_load_items(PrecompileWorkload, (:typestable, :noalloc); only = _WORKLOAD_FUNCTIONS)
        _map_findings(_scan_findings, items)
        _auto_check_module(PrecompileWorkload, (:typestable, :noalloc); only = _WORKLOAD_FUNCTIONS)
        # Nothing the workload leaves behind may outlive it: the memos hold the toy modules' bodies.
        clear_cache!()
    end
    return nothing
end

@setup_workload begin
    @compile_workload begin
        _precompile_workload()
    end
end
