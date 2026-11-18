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

# A call that waits in the task scheduler, which a warning names by walking the call graph, and a
# loop that vectorizes, which `:vectorized` and `:no_spill` read from compiled code.
module PrecompileWorkloadKernels
    const ready = Threads.Condition()
    block() = (
        lock(ready); try
            wait(ready)
        finally
            unlock(ready)
        end; nothing
    )
    function axpy!(y::Ptr{Float64}, x::Ptr{Float64}, n::Int)
        @simd for i in 1:n
            unsafe_store!(y, muladd(2.0, unsafe_load(x, i), unsafe_load(y, i)), i)
        end
        return nothing
    end
end

# A module also defines `eval` and `include`, which are not what the workload is about and do not pass.
const _WORKLOAD_FUNCTIONS = (:helper, :kernel)

function _precompile_workload()
    # The compiler methods the scan specializes on its interpreter belong in this image (`_window_open`).
    _KEEP_SCAN_SPECIALIZATIONS[] = true
    try
        _run_workload()
    finally
        _KEEP_SCAN_SPECIALIZATIONS[] = false
    end
    return nothing
end

function _run_workload()
    # A workload that printed would print at every install of StrictMode, so nothing it reports is shown.
    # The global logger is replaced for the duration. `with_logger` takes a closure, and Base's
    # logger scope specialized on a closure of this function is a `CodeInstance` this method roots.
    logger = Base.CoreLogging.global_logger(Base.CoreLogging.NullLogger())
    try
        for gs in ((:typestable, :noalloc), (:noboxing,), (:noalloc, :noboxing), (:owned,))
            findings(PrecompileWorkload.kernel, (Vector{Float64}, Int); guarantees = gs)
            findings(PrecompileWorkloadAllocating.grow, (Int,); guarantees = gs)
        end
        items = _module_load_items(PrecompileWorkload, (:typestable, :noalloc); only = _WORKLOAD_FUNCTIONS)
        _map_findings(_scan_findings, items)
        _auto_check_module(PrecompileWorkload, (:typestable, :noalloc); only = _WORKLOAD_FUNCTIONS)
        _auto_check_module(PrecompileWorkload, (:typestable, :trim_compatible); only = _WORKLOAD_FUNCTIONS)
        # What a `@verify_strict` block runs for each call it lists, on a call that passes, one that
        # allocates and one that blocks, so the warnings and the walk that words them are compiled too.
        for (f, types) in (
                (PrecompileWorkload.kernel, (Vector{Float64}, Int)),
                (PrecompileWorkloadAllocating.grow, (Int,)), (PrecompileWorkloadKernels.block, ()),
            )
            _check_stable_once("workload", f, types)
            _strict_scan("workload", f, types)
        end
        findings(PrecompileWorkloadKernels.block, (); guarantees = (:noalloc,))
        findings(
            PrecompileWorkloadKernels.axpy!, (Ptr{Float64}, Ptr{Float64}, Int);
            guarantees = (:vectorized, :no_spill)
        )
        # Nothing the workload leaves behind may outlive it: the memos hold the toy modules' bodies.
        clear_cache!()
    finally
        Base.CoreLogging.global_logger(logger)
    end
    return nothing
end

@setup_workload begin
    @compile_workload begin
        _precompile_workload()
    end
end
