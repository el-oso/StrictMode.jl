# The `llvm-mca` seam. `LLVM_full_jll` ships `llvm-mca` as an ~680MiB artifact, so it is a weak
# dependency and `StrictModeMcaExt` fills the two functions below.
#
# This is the only seam left in StrictMode. The analysis TIER is not a seam: `StrictMode` runs one
# engine — a value-free scan of typed IR and inferred return types — and the proofs (AllocCheck,
# JET, TrimCheck) live in `StrictModeTest`, which depends on them directly. Nothing here reaches
# for a backend that may or may not be loaded, which is what made a missing backend able to report
# success for every method in a sweep.

const _MCA_AVAILABLE = Ref(false)

"""
    mca_available() -> Bool

Whether the `LLVM_full_jll` extension (`StrictModeMcaExt`) is loaded — i.e. whether
[`mca_report`](@ref)/`@assert_mca` can actually run `llvm-mca`. `LLVM_full_jll` is a heavy
(~680MiB) weak dependency, so this defaults `false`; add it to your dev environment to use these.
"""
mca_available() = _MCA_AVAILABLE[]

function _require_mca()
    _MCA_AVAILABLE[] && return nothing
    error(
        "StrictMode: mca_report/@assert_mca need LLVM_full_jll (an optional, ~680MiB weak " *
            "dependency that ships llvm-mca) — add it to this environment to use them. Not " *
            "needed for any other StrictMode guarantee."
    )
end

function _be_mca_run end   # (sanitized_asm::String, mcpu::String) -> raw llvm-mca stdout::String
function _be_mca_cpus end  # () -> Vector{String} of -mcpu names llvm-mca recognizes on this host
