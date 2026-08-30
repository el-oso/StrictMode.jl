# The MCA backend. Loaded only when `LLVM_full_jll` is present (an *independent* weak dependency —
# a ~680MiB artifact, never a test/CI default). This is the only place that touches LLVM_full_jll —
# it fills `StrictMode._be_mca_run`/`_be_mca_cpus` and flips `mca_available()` on.

module StrictModeMcaExt

using StrictMode
using LLVM_full_jll

function StrictMode._be_mca_cpus()
    err = IOBuffer()
    run(pipeline(`$(LLVM_full_jll.llvm_mca_path) -mcpu=help`; stdout = devnull, stderr = err))
    text = String(take!(err))   # `-mcpu=help`'s listing goes to stderr, not stdout
    return [String(m[1]) for m in eachmatch(r"^\s{2}(\S+)\s+- Select the"m, text)]
end

function StrictMode._be_mca_run(sanitized_asm::AbstractString, mcpu::AbstractString)
    path, io = mktemp()
    try
        write(io, sanitized_asm)
        close(io)
        out, err = IOBuffer(), IOBuffer()
        proc = run(pipeline(`$(LLVM_full_jll.llvm_mca_path) -mcpu=$mcpu $path`; stdout = out, stderr = err); wait = false)
        wait(proc)
        proc.exitcode == 0 || error("llvm-mca exited $(proc.exitcode): " * String(take!(err)))
        return String(take!(out))
    finally
        rm(path; force = true)
    end
end

function __init__()
    StrictMode._MCA_AVAILABLE[] = true
    return nothing
end

end # module StrictModeMcaExt
