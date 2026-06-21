# Precompile workload. The first interactive use of the assert/explain macros otherwise pays a
# large one-time cost (~10s) compiling JET's analyzer and AllocCheck's GPUCompiler pipeline.
# Running those paths here bakes that compilation into StrictMode's cached image, so the first
# real call is already warm.
#
# Gated on `CHECKS_ENABLED`: a production build (checks off) never runs the analyzers, so it must
# not pay to compile them in — the workload then does nothing and precompilation stays fast.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    wk_dot(a, b) = @inbounds a[1] * b[1] + a[2] * b[2]
    A = (1.0, 2.0)
    B = (3.0, 4.0)
    types = (typeof(A), typeof(B))
    @compile_workload begin
        if CHECKS_ENABLED
            # Warm AllocCheck (static no-alloc proof) and its empirical fallback.
            try
                _assert_noalloc("warmup", wk_dot, types, () -> wk_dot(A, B); static = true)
            catch
            end
            # Warm JET (@report_opt) and the full @explain aggregation (+ @code_warntype).
            try
                opt = JET.@report_opt wk_dot(A, B)
                _explain("warmup", wk_dot, types, opt)
            catch
            end
        end
    end
end
