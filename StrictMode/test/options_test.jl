# A name an entry point does not know is an error naming it, never a setting silently left at its
# default.

@testitem "a macro rejects an option it does not have, at expansion" begin
    using StrictMode

    opt_kernel(x::Vector{Float64}) = sum(x)
    opt_kernel!(y::Vector{Float64}, x::Vector{Float64}) = (y .= x; y)

    # Every macro that takes `key = value` options, with the options it accepts.
    accepted = Dict(
        "@assert_noalloc" => "`static`, `types`", "@assert_noboxing" => "`types`",
        "@assert_typestable" => "`types`", "@assert_owned" => "`types`, `depth`",
        "@assert_noescape" => "`types`", "@assert_inlined" => "`types`",
        "@assert_vectorized" => "`types`", "@assert_no_scalar_loops" => "`types`",
        "@assert_no_spill" => "`types`, `scope`", "@assert_trim_compatible" => "`types`",
        "@assert_trusted" => "`types`", "@assert_concurrency_safe" => "`self`, `max_depth`, `types`",
        "@assert_no_threadid_state" => "`types`", "@assert_effects" => "`types`",
        "@assert_mca" => "`types`, `mcpu`, `region`, `max_rthroughput`, `min_ipc`",
        "@assert_memsafe" => "`align`, `using_module`, `timeout`, `reuse`",
        "@strict" => "`types`", "@kernel" => "`types`", "@explain" => "`types`",
    )
    for (name, opts) in accepted
        call = Expr(:macrocall, Symbol(name), LineNumberNode(1), :(bogus_option = 1), :(opt_kernel([1.0])))
        @test_throws "$name: unknown option `bogus_option`. Accepted options: $opts." macroexpand(@__MODULE__, call)
    end
    # The expansion raises, so the call is never run with the option dropped.
    @test_throws "unknown option `isolate`" @eval @assert_noalloc isolate = false opt_kernel([1.0])
    @test_throws "@assert_noalias: unknown option `mutate`. Accepted options: `mutates`." @eval @assert_noalias mutate = (1,) opt_kernel!([1.0], [2.0])
    @test_throws "@strict_function: unknown option `guarantee`. Accepted options: `signatures`, `guarantees`." @eval @strict_function guarantee = (:noalloc,) opt_def(x::Int) = x
    @test_throws "@strict_exempt: unknown option `reasons`. Accepted options: `guarantees`, `reason`, `types`." @eval @strict_exempt reasons = "cold" opt_def2(x::Int) = x
    @test_throws "@strict_policy: unknown option `checks`. Accepted options: `check`, `only`, `exempt`." @eval @strict_policy checks = false :noalloc
    @test_throws "@strict_stable: unknown option `types`. It takes no options." @eval @strict_stable types = (Int,) opt_def3(x) = x
    @test_throws "@assert_reaches: unknown option `stop`. It takes no options." @eval @assert_reaches opt_kernel([1.0]) sum stop = (:x,)
    @test_throws "@assert_reaches: unknown option `stop`" @eval @assert_reaches opt_kernel([1.0]) stop = (:x,)
    @test_throws "@verify_strict: unknown option `guarantee`. Accepted options: `guarantees`." @eval @verify_strict Int guarantee = (:noalloc,) begin
        opt_kernel([1.0])
    end
    @test_throws "@golden: unknown keyword `ulp`; expected `ulps`, `dir`, `validator`, or `record`" @eval @golden "n" opt_kernel([1.0]) ulp = 1

    # A removed option keeps its own message, and is not listed as accepted.
    @test_throws "the `isolate` option was removed" @eval @assert_memsafe isolate = false opt_kernel([1.0])

    # The accepted options still parse.
    @test (@assert_noalloc types = (Vector{Float64},) opt_kernel([1.0])) == 1.0
    @test (@assert_concurrency_safe self = 2 opt_kernel!([0.0], [2.0])) == [2.0]
end

@testitem "an option value that names nothing is rejected" begin
    using StrictMode

    module OptValues
    k(x::Vector{Float64}) = sum(x)
    k!(y::Vector{Float64}, x::Vector{Float64}) = (y .= x; y)
    end
    sig = (Vector{Float64},)

    # A guarantee name, in a single check and in a sweep. The module has nothing compiled, so
    # the sweep reaches no method: the name is checked before it starts.
    @test_throws "unknown guarantee :noaloc; expected one of" findings(OptValues.k, sig; guarantees = (:noaloc,))
    @test_throws "unknown guarantee :noaloc; expected one of" audit(OptValues; guarantees = (:noaloc,))
    @test_throws "unknown guarantee :noaloc; expected one of" audit(:registered; guarantees = (:noaloc,))
    @test_throws "unknown guarantee :noaloc" StrictMode.register_strict!(OptValues.k, sig; guarantees = (:noaloc,))
    @test_throws "unknown guarantee :noaloc" @eval @strict_policy :noaloc
    @test_throws "unknown guarantee :noaloc" @eval @strict_exempt guarantees = (:noaloc,) opt_val_def(x::Int) = x
    @test_throws "unknown effect :nothrows; expected :nothrow" @assert_effects OptValues.k([1.0]) (:nothrows,)
    @test_throws "scope must be one of (:loops, :innermost, :function), got :loop" @eval @assert_no_spill scope = :loop OptValues.k([1.0])
    @test_throws "unknown format jsn; expected one of (:text, :json, :jsonlines, :github)" format_findings(StrictFinding[]; format = :jsn)
    @test_throws "audit target must be :registered or a Module" audit(:registred)
    @test_throws "unknown diagnostic code :SM9999" StrictMode.explain(:SM9999)

    # The shared argument of the concurrency scan: a position the call does not have.
    @test_throws "self = 3 is out of range for a call with 2 positional argument(s)" @eval @assert_concurrency_safe self = 3 OptValues.k!([0.0], [1.0])
    @test_throws "self_arg = 3 is out of range" StrictMode.concurrency_findings(OptValues.k!, (Vector{Float64}, Vector{Float64}); self_arg = 3)
    @test_throws "self_arg = 0 is out of range" StrictMode.concurrency_findings(OptValues.k!, (Vector{Float64}, Vector{Float64}); self_arg = 0)
    # A method with no argument still sweeps: there is nothing it could share.
    noargs() = 1
    noargs()
    @test only(findings(noargs, (); guarantees = (:concurrency_safe,))).status === :pass

    # A keyword a function does not have is Julia's own error, which names it.
    @test_throws "isolate" findings(OptValues.k, sig; isolate = false)
    @test_throws MethodError audit(OptValues; isolate = false)
    @test_throws MethodError kernel_report(OptValues.k, sig; isolate = false)
    @test_throws "the `isolate` option was removed" StrictMode.memsafe_report(OptValues.k, [1.0]; isolate = false)
end

@testitem "an only, exempt or stop entry that matches no function is rejected" begin
    using StrictMode

    module FilterNames
    hot(x::Vector{Float64}) = sum(x)
    cold(x::Vector{Float64}) = string(length(x))
    withkw(x::Vector{Float64}; scale = 1.0) = scale * sum(x)
    Base.show(io::IO, ::Val{:filter_names}) = print(io, "v")
    end
    FilterNames.hot([1.0]); FilterNames.cold([1.0]); FilterNames.withkw([1.0]; scale = 2.0)

    # A misspelled `only` scopes the sweep to nothing, which returns the clean result of a module
    # with nothing wrong in it.
    @test_throws "`only` names `hto`, which matches no function with a method in `FilterNames`" audit(FilterNames; sweep = true, only = (:hto,))
    @test_throws "A sweep scoped to nothing checks nothing" audit(FilterNames; sweep = true, only = (:hto,))
    @test_throws "`only` names r\"^nothing_matches\$\"" unsafe_report(FilterNames; only = r"^nothing_matches$")
    @test_throws "`exempt` names `colt`" unsafe_report(FilterNames; exempt = (:colt,))
    @test_throws "An exemption that matches nothing exempts nothing" dispatch_report(FilterNames; exempt = [:colt])
    @test_throws "`only` names `hto`" StrictMode.module_methods(FilterNames; only = [:hot, :hto])
    @test_throws "`only` names `hto`" StrictMode.throw_report(FilterNames; only = [:hto])
    @test_throws "`exempt` names `colt`" audit(FilterNames; require = :public, exempt = (:colt,))

    # Entries that do match are taken as before: a name, a function, a regex, a keyword method by
    # its written name, a method the module adds to another module's function, and a predicate.
    @test length(first(StrictMode.module_methods(FilterNames; only = (:hot,)))) == 1
    @test length(first(StrictMode.module_methods(FilterNames; only = (FilterNames.hot, :cold)))) == 2
    @test length(first(StrictMode.module_methods(FilterNames; only = r"^(hot|cold)$"))) == 2
    @test !isempty(first(StrictMode.module_methods(FilterNames; only = (:withkw,))))
    @test length(first(StrictMode.module_methods(FilterNames; only = (:show,)))) == 1
    @test isempty(first(StrictMode.module_methods(FilterNames; only = f -> false)))
    @test audit(FilterNames; sweep = true, only = (:hot,), exempt = (:cold,)) isa Vector{StrictFinding}

    # `stop` names a hub to cut the walk at. One the call never reaches cut nothing.
    @noinline leaf(x) = x + 1
    @noinline hub(x) = leaf(x) * 2
    entry(x) = hub(x) - 1
    other(x) = x
    sig = (Int,)
    @test StrictMode.reaches(StrictMode.reach_report(entry, sig; stop = (hub,)), hub)
    @test !StrictMode.reaches(StrictMode.reach_report(entry, sig; stop = (hub,)), leaf)
    @test_throws "reach_report: `stop` names `other`, which entry(Int64) does not reach" StrictMode.reach_report(entry, sig; stop = (other,))
    @test_throws "nothing was cut there" StrictMode.reach_report(entry, sig; stop = (hub, other))
    # Two routes: a hub only one of them reaches is the difference being reported.
    direct(x) = leaf(x)
    @test StrictMode.route_parity(entry => sig, direct => sig; stop = (hub,)) isa StrictMode.RouteParity
    @test_throws "route_parity: `stop` names `other`, which neither" StrictMode.route_parity(entry => sig, direct => sig; stop = (other,))
end
