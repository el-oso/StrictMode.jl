# The scan, run once on a toy module while StrictMode itself is precompiled, so that a consumer's own
# precompile (where `@strict_policy` and `@strict_function` run the scan) does not compile the scan
# first: the code it needs is already in this package's image. Measured on an 80-method module, the
# first call of the module check took 1.6 s, and the same call with the code compiled took 0.07 s.
module PrecompileWorkload
    @noinline helper(v::Vector{Float64}, n::Int) = v[mod1(n, length(v))] * 2.0
    function kernel(v::Vector{Float64}, n::Int)
        s = 0.0
        for i in 1:n
            s += helper(v, i) + sin(s)
        end
        return s
    end
    grow(n::Int) = (a = Float64[]; push!(a, n); a)
end

# Nothing the workload leaves behind may outlive it: the memos hold the toy module's bodies.
@setup_workload begin
    @compile_workload begin
        for _gs in ((:typestable, :noalloc), (:noboxing,), (:noalloc, :noboxing), (:owned,))
            findings(PrecompileWorkload.kernel, (Vector{Float64}, Int); guarantees = _gs)
            findings(PrecompileWorkload.grow, (Int,); guarantees = _gs)
        end
        _items = _module_load_items(PrecompileWorkload, (:typestable, :noalloc))
        _map_findings(_scan_findings, _items)
        _auto_check_module(PrecompileWorkload, (:typestable, :noalloc))
        clear_cache!()
    end
end
