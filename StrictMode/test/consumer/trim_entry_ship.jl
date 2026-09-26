# The shipping half of the trim gate: an embedded call-site macro inside code the binary compiles and
# runs, built with checks disabled. `--trim` verifies reachable code only, so this entry must actually
# CALL the guarded function — a declaration alone proves nothing about the macro's expansion.

using ConsumerPkg

function (@main)(args::Vector{String})::Cint
    v = ConsumerPkg.guarded((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))
    return Cint(v == 32.0 ? 0 : 1)
end
