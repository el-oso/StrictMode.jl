# Cthulhu visibility escape hatch. Cthulhu is heavy and interactive, so it's an optional weak
# dependency: loading it wires up `StrictMode.descend(f, types)` to drop into Cthulhu's interactive
# descent (inlining / effects / type-stability / LLVM / native) for the scheduling-bound kernels
# StrictMode can surface but not control.

module StrictModeCthulhuExt

using StrictMode
using Cthulhu

function __init__()
    StrictMode._CTHULHU_DESCEND[] = (@nospecialize(f), @nospecialize(types)) -> Cthulhu.descend(f, types)
    return nothing
end

end # module StrictModeCthulhuExt
