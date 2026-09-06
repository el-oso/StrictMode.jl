# The consumer layout built as a real `juliac --trim=safe` binary.
#
# `Pkg.test` runs ConsumerPkg in an ordinary process, where `__init__` is never a trim root and
# nothing forces StrictMode's load path to be statically resolvable. That is why issue #28 shipped
# twice: a load banner written with `printstyled` broke the build of every consumer shipping a
# trimmed artifact, and no test here could see it.
#
# The entry deliberately calls nothing. `using ConsumerPkg` — which is `using StrictMode` plus two
# `@strict_function` declarations — is the whole exposure being tested. `@main` must be at top
# level: juliac looks for it in the module it includes this file into.

using ConsumerPkg

(@main)(args::Vector{String})::Cint = Cint(0)
