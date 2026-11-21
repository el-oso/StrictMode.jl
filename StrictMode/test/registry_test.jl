@testitem "register_strict! + the registry sweep aggregate findings" begin
    using StrictMode, StrictModeTest
    StrictMode.clear_declarations!()
    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    boxy(t::Tuple{Int, Float64, Float32}) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )

    StrictMode.register_strict!(clean, (NTuple{3, Float64}, NTuple{3, Float64}))
    StrictMode.register_strict!(boxy, (Tuple{Int, Float64, Float32},))
    @test length(StrictMode.declarations()) == 2

    fs = StrictMode._findings_all()
    @test StrictMode.nfailures(fs) ≥ 1                 # boxy allocates
    @test_throws StrictViolation test_registered()
end

@testitem "register_strict! skips non-concrete signatures" begin
    using StrictMode
    StrictMode.clear_declarations!()
    g(x::Number) = x + one(x)
    StrictMode.register_strict!(g, (Number,))           # abstract → skipped with a warning
    @test isempty(StrictMode.declarations())
end

@testitem "@strict module rewrites the body to register its methods" begin
    using StrictMode
    # (`@strict module … end` must run at true top level — script/REPL/package — so test the
    # rewriting at the expression level here; end-to-end is covered by the docs/smoke examples.)
    modexpr = :(
        module K
        dot3(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1]
        end
    )
    out = StrictMode._strict_module(modexpr)
    inner = Meta.isexpr(out, :escape) ? out.args[1] : out
    @test Meta.isexpr(inner, :module)
    s = string(inner)
    @test occursin("register_strict!", s)        # a registration was injected
    @test occursin("_auto_check_module", s)       # auto-check-at-load was injected
end

@testitem "_auto_check_module raises on a violation (the load-time gate)" begin
    using StrictMode
    StrictMode.clear_declarations!()
    unstable(x::Int) = x > 0 ? 1 : "negative"
    StrictMode.register_strict!(unstable, (Int,); guarantees = (:typestable,))
    @test_throws StrictViolation StrictMode._auto_check_module(@__MODULE__)
end

@testitem "register_strict! accepts a ::Type{T} argument signature (F37)" begin
    using StrictMode
    # `isconcretetype(Type{Float64})` is `false` (a real Julia quirk) even though `Type{Float64}`
    # is a fully-specified, singleton dispatch signature — `all(isconcretetype, tt)` would treat
    # every `::Type{T}`-argument function as "non-concrete" and silently skip it.
    StrictMode.clear_declarations!()
    typed_alloc(::Type{T}, n::Int) where {T} = Vector{T}(undef, n)
    StrictMode.register_strict!(typed_alloc, (Type{Float64}, Int))
    @test length(StrictMode.declarations()) == 1
end

@testitem "the compiled sweep reaches a ::Type{T}-argument specialization (F37)" begin
    using StrictMode
    module SweptTyped
    ws(::Type{T}) where {T} = Vector{T}(undef, 0)
    end
    SweptTyped.ws(Float64)                         # compile a Type{Float64}-argument specialization

    fs = StrictMode._findings_compiled(SweptTyped; guarantees = (:noalloc,))
    @test any(f -> f.func == "ws", fs)
end

@testitem "the compiled sweep reaches actually-compiled instances" begin
    using StrictMode
    module Swept
    f(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    g(t) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    end
    Swept.f((1.0, 2.0, 3.0), (4.0, 5.0, 6.0))     # compile a clean instance
    Swept.g((1, 2.0, 3.0f0))                       # compile a boxing instance

    fs = StrictMode._findings_compiled(Swept; guarantees = (:noalloc, :noboxing))
    @test any(f -> f.func == "g" && StrictMode._failed(f), fs)
    @test any(f -> f.func == "f" && f.status === :pass, fs)
end

@testitem "no declarations in scope warns loudly instead of reporting a silent green" begin
    using StrictMode, StrictModeTest
    # A sweep over nothing returns zero findings and passes, which renders exactly like a sweep that
    # proved everything. That is the failure this package exists to remove, so both tiers say it out
    # loud. `clear_declarations!` empties every store, not just the one this session registered into
    # — a sibling test item's declarations live in this worker's `Main` and would otherwise count.
    StrictMode.clear_declarations!()
    @test isempty(@test_logs (:warn,) match_mode = :any StrictMode._findings_all())
    @test isempty(@test_logs (:warn,) match_mode = :any test_registered())
    StrictMode.clear_declarations!()
end

@testitem "@strict module keeps parametric definitions loadable" begin
    using StrictMode

    # A `where` method is ordinary Julia. The registry cannot check it — its signature is never a
    # dispatch tuple — but the module must still load, and the skip must be named once.
    @test_logs (:warn,) match_mode = :any (
        @eval @strict module _SMParam
        h(x::T) where {T <: Real} = x * 2
        g(x::T) where {T} = x
        k(v::Vector{T}) where {T <: Real} = sum(v)
        m(x::T, y::S) where {T, S} = (x, y)
        # The `where` binds to the return type in `n(x::T)::T where {T}`, so the long form is the
        # only spelling that annotates a parametric return.
        function n(x::T)::T where {T <: Real}
            return x * 2
        end
        hot(x::Int) = x + 1                      # concrete: still registered
        end
    )

    @test _SMParam.h(2.0) == 4.0
    @test _SMParam.k([1.0, 2.0]) == 3.0
    @test _SMParam.n(3.0) == 6.0

    # The concrete definition registered; no parametric one did.
    names = Set(String(StrictMode._demangle(nameof(f))) for (f, _) in keys(StrictMode.declarations()))
    @test "hot" in names
    @test isempty(intersect(names, Set(["h", "g", "k", "m", "n"])))
end

@testitem "the load check reads the module's methods, so include'd definitions are covered" begin
    using StrictMode

    # The hole a statement rewrite leaves: `include(path)` is one statement, and the definitions
    # inside it are never seen by a macro that rewrites the module body.
    path, io = mktemp()
    write(io, "inc_unstable(x::Int) = x > 0 ? 1 : \"a string\"\n")   # heap-allocating union
    close(io)

    StrictMode.clear_declarations!()
    try
        @test_throws StrictMode.StrictViolation (
            @eval @strict module _IncHole
            inline_ok(x::Int) = x + 1
            include($path)
            end
        )

        # …and the clean case still loads, so the check is not simply rejecting everything.
        path2, io2 = mktemp()
        write(io2, "inc_ok(x::Int) = x + 1\n")
        close(io2)
        try
            @eval @strict module _IncClean
            inline_ok(x::Int) = x + 1
            include($path2)
            end
            @test Base.@invokelatest(_IncClean.inc_ok(1)) == 2
        finally
            rm(path2; force = true)
        end
    finally
        rm(path; force = true)
        StrictMode.clear_declarations!()
    end
end

@testitem "@strict_policy declares a module policy without wrapping `module`" begin
    using StrictMode

    StrictMode.clear_declarations!()

    # The policy is recorded, and submodules inherit it by lookup rather than by copy.
    @eval module _PolParent
    using StrictMode
    @strict_policy (:typestable, :noalloc) check = false
    module _PolChild end
    end
    @test StrictMode.module_policy(_PolParent) == (:typestable, :noalloc)
    @test StrictMode.module_policy(_PolParent._PolChild) == (:typestable, :noalloc)
    @test StrictMode.module_policy(@__MODULE__) == StrictMode.policy_sets()[:default]   # unset → :default

    # Nesting is flattened, so a shared policy can be spliced in from elsewhere.
    @eval module _PolNest
    using StrictMode
    @strict_policy (:typestable, (:noalloc, :noboxing)) check = false
    end
    @test StrictMode.module_policy(_PolNest) == (:typestable, :noalloc, :noboxing)

    # A misspelled guarantee is an error, not a no-op: it would otherwise check nothing while
    # reading as though it checked something.
    @test_throws ArgumentError (
        @eval module _PolTypo
        using StrictMode
        @strict_policy (:typestabel,) check = false
        end
    )

    StrictMode.clear_declarations!()
end

@testitem "a declaration names only guarantees that exist" begin
    using StrictMode
    StrictMode.clear_declarations!()
    f(x::Int) = x + 1

    @test_throws ArgumentError StrictMode.register_strict!(f, (Int,); guarantees = (:typestabel,))
    @test isempty(StrictMode.declarations())           # nothing was recorded

    # Nested collections are accepted and flattened; duplicates collapse.
    StrictMode.register_strict!(f, (Int,); guarantees = (:typestable, (:typestable, :noalloc)))
    @test only(values(StrictMode.declarations())).guarantees == (:typestable, :noalloc)
    @test :typestable in StrictMode.guarantee_names()

    StrictMode.clear_declarations!()
end

@testitem "a finding names the rule that required the guarantee" begin
    using StrictMode
    StrictMode.clear_declarations!()

    # Only a macro can know the line that asked for a guarantee — a function cannot see its caller —
    # so the macros record it and a finding carries it. A reader who can see the rule can narrow it,
    # turn it off, or exempt the method; one who cannot has to go looking.
    @strict_function pol_leaky(n::Int) = collect(1:n)
    fs = StrictMode._findings_all()
    @test !isempty(fs)
    @test all(f -> occursin("@strict_function at", f.policy), fs)
    @test all(f -> occursin("registry_test.jl", f.policy), fs)
    @test occursin("required by @strict_function", format_findings(fs; format = :text))
    @test occursin("\"policy\":\"@strict_function", format_findings(fs; format = :json))

    # A declaration made by the plain function carries none, because there is no caller line to
    # read. An empty field is the honest answer, not a guessed one.
    StrictMode.clear_declarations!()
    pol_plain(x::Float64) = x > 0 ? 1 : "s"
    StrictMode.register_strict!(pol_plain, (Float64,); guarantees = (:typestable,))
    @test all(f -> f.policy == "", StrictMode._findings_all())

    StrictMode.clear_declarations!()
end

@testitem "a named policy set is one word for a list" begin
    using StrictMode

    sets = StrictMode.policy_sets()
    @test sets[:default] == (:typestable, :noalloc, :noboxing)
    # The name has to match the behavior: `:default` IS what an unmarked module gets.
    @test StrictMode.module_policy(Main) == sets[:default]
    @test issubset(sets[:default], sets[:hot])          # :hot adds to it rather than replacing
    @test :vectorized in sets[:hot]
    # `:all` is every guarantee that is safe to ENFORCE on a whole module, which is not every
    # guarantee the engine can compute: this policy runs at the consumer's own precompile. The one
    # exclusion is named here rather than derived, so widening or narrowing it is a deliberate edit
    # in two places.
    @test issubset(Set(sets[:all]), Set(StrictMode.guarantee_names()))
    @test setdiff(Set(StrictMode.guarantee_names()), Set(sets[:all])) == Set((:concurrency_safe,))
    # A sweep reads argument 1, and a `!` method writes argument 1 by convention, so enforcing it
    # module-wide would fail correct code. It stays available to `audit` and to an explicit request.
    @test :concurrency_safe in StrictMode.guarantee_names()

    # A name expands wherever a guarantee may be written, so it composes with individual ones.
    @test StrictMode._check_guarantees(:default) == sets[:default]
    @test Set(StrictMode._check_guarantees((:default, :vectorized))) ==
        Set((sets[:default]..., :vectorized))
    @test_throws ArgumentError StrictMode._check_guarantees(:kernel)   # not a set, not a guarantee
end

@testitem "a narrower declaration satisfies coverage without an exemption" begin
    using StrictMode

    # An allocator under a declaration that does not claim `:noalloc`. Nothing is excused, because
    # nothing was claimed — and the coverage gate asks whether a declaration EXISTS, not whether it
    # names any particular guarantee. This is the route for a pool that allocates by design.
    module Owned
    mutable struct WS
        buf::Vector{Float64}
    end
    const POOL = WS(Float64[])
    grow!(p::WS, n::Int) = (length(p.buf) < n && (p.buf = Vector{Float64}(undef, n)); p.buf)
    function driver!(C::Matrix{Float64}, n::Int)
        s = grow!(POOL, n)
        for i in 1:n
            s[i] = i
        end
        C[1, 1] = s[n]
        return C
    end
    end

    StrictMode.register_strict!(
        Owned.driver!, (Matrix{Float64}, Int);
        guarantees = (:typestable, :noboxing), mod = Owned
    )
    StrictMode.register_strict!(
        Owned.grow!, (Owned.WS, Int);
        guarantees = (:typestable, :noboxing), mod = Owned
    )
    Owned.driver!(zeros(2, 2), 8)         # compile, so the census has a signature to find

    # No exemption names either method, so the coverage pass below is satisfied by the declarations
    # alone. Scoped to these two names because the exemption store is session-global and other
    # items on the same worker write to it.
    @test !any(e -> e.func in (:driver!, :grow!), StrictMode.exemptions())
    cov = StrictMode.audit(Owned; require = :all, guarantees = (:typestable, :noboxing))
    @test !any(f -> StrictMode._failed(f) && occursin("declar", lowercase(f.reason)), cov)

    StrictMode.clear_declarations!()
end

@testitem "only a module's own initializer counts as running in __init__" begin
    using StrictMode

    # The loader calls this one: the zero-argument `__init__` of the module that defines it.
    module RealInit
    using StrictMode
    const SEEN = Ref(false)
    __init__() = (SEEN[] = StrictMode._called_from_init(); nothing)
    end
    @test RealInit.SEEN[]

    # A function that merely has the name is not an initializer.
    module NamedLikeInit
    using StrictMode
    function outer()
        __init__() = StrictMode._called_from_init()
        return __init__()
    end
    struct Builder end
    __init__(b::Builder) = StrictMode._called_from_init()
    __init__() = nothing
    end
    @test !NamedLikeInit.outer()
    @test !NamedLikeInit.__init__(NamedLikeInit.Builder())
    @test !StrictMode._called_from_init()
end

@testitem "a module sweep covers the methods it adds to another module's function" begin
    using StrictMode

    module ForeignMethods
    using StrictMode
    struct MyT
        v::Int
    end
    # A method of `Base.getproperty`, written here. It reads the payload outside any boundary.
    Base.getproperty(u::Untrusted{MyT}, s::Symbol) = getfield(u, :x)
    struct Grows
        n::Int
    end
    Base.collect(g::Grows) = zeros(g.n)
    own(x::Int) = x + 1
    end
    F = ForeignMethods
    u = Untrusted(F.MyT(7))
    u.x; collect(F.Grows(3)); F.own(1)

    swept(; kw...) = audit(F; sweep = true, dispatch_suggest = false, kw...)
    fs = swept(; guarantees = (:trusted,))
    read = only(f for f in fs if f.func == "getproperty")
    @test StrictMode._failed(read)
    # Named after the module that wrote the method, not the one that owns the function.
    @test read.mod === :ForeignMethods
    @test only(findings(getproperty, (Untrusted{F.MyT}, Symbol); guarantees = (:trusted,))).mod === :ForeignMethods
    @test occursin("reads an `Untrusted` payload", read.reason)
    @test any(f -> f.func == "own" && f.status === :pass, fs)
    # Only the method written here: `getproperty` has many others, and they are Base's.
    @test count(f -> f.func == "getproperty", fs) == 1
    @test any(f -> f.func == "collect" && f.guarantee === :noalloc && f.status !== :pass, swept(; guarantees = (:noalloc,)))
    # The filters name it as they name the module's own functions.
    @test !any(f -> f.func == "getproperty", swept(; guarantees = (:trusted,), exempt = (:getproperty,)))
    scoped = swept(; guarantees = (:trusted,), only = (:getproperty,))
    @test !isempty(scoped)
    @test all(f -> f.func == "getproperty", scoped)
    Base.delete_method(which(getproperty, (Untrusted{F.MyT}, Symbol)))
end

@testitem "a module sweep covers the methods written in that module only" begin
    using StrictMode

    module Nested
    using StrictMode
    pf(x::Int) = x + 1
    module Sub
    using StrictMode
    import ..pf
    struct MyT
        v::Int
    end
    struct Tracker
        v::Vector{Float64}
    end
    Tracker(; n::Int = 3) = Tracker(zeros(n))
    @strict_exempt :noalloc Tracker
    Base.getproperty(u::Untrusted{MyT}, s::Symbol) = getfield(u, :x)
    subf(x::Int) = x + 1
    pf(x::Float64) = x + 1          # a method of the parent's function, written here
    end
    struct Grows
        n::Int
    end
    Base.collect(g::Grows) = zeros(g.n)
    end
    N = Nested
    Untrusted(N.Sub.MyT(1)).x; N.Sub.Tracker(; n = 2); N.Sub.subf(1); N.pf(1); N.pf(1.0)
    collect(N.Grows(3))

    sweep(m) = audit(m; sweep = true, guarantees = (:trusted, :noalloc), dispatch_suggest = false)
    parent, sub = sweep(N), sweep(N.Sub)
    # The census still counts every method in the package, the submodule's among them.
    census = first(StrictMode.module_methods(N))
    @test count(m -> m.module === N.Sub, census) >= 4
    # The parent's sweep has no row for a method the submodule wrote.
    @test !isempty(parent)
    @test all(f -> f.mod === :Nested, parent)
    @test !any(f -> f.func == "pf" && occursin("Float64", f.signature), parent)
    # A foreign method the parent wrote is still swept.
    @test any(f -> f.func == "collect" && f.guarantee === :noalloc && StrictMode._failed(f), parent)
    @test any(f -> f.func == "pf" && occursin("Int", f.signature), parent)
    # The submodule's own sweep has them, once each, with its exemption applied.
    @test all(f -> f.mod === :Sub, sub)
    @test count(f -> f.func == "getproperty" && f.guarantee === :trusted && StrictMode._failed(f), sub) == 1
    @test any(f -> f.func == "subf", sub)
    @test count(f -> f.func == "pf" && occursin("Float64", f.signature) && f.guarantee === :noalloc, sub) == 1
    tr = [f for f in sub if occursin("Tracker", f.func) && f.guarantee === :noalloc]
    @test !isempty(tr)
    @test all(f -> f.status === :info && startswith(f.reason, "exempt"), tr)
    Base.delete_method(which(getproperty, (Untrusted{N.Sub.MyT}, Symbol)))
end

@testitem "a module sweep covers a callable that subtypes Function and has no binding" begin
    using StrictMode
    module UnboundCallable
    struct K <: Function end                 # a singleton with no `const k = K()` in the module
    (::K)(x::Int) = x > 0 ? x : "neg"
    struct KF <: Function                    # one with a field, so it has no instance
        a::Int
    end
    (k::KF)(x::Int) = x > k.a ? x : "neg"
    bound(x::Int) = x > 0 ? x : "neg"        # bound to a name: walked once, not twice
    end
    U = UnboundCallable
    U.K()(1); U.KF(0)(1); U.bound(1)
    fs = audit(U; sweep = true, guarantees = (:typestable,), dispatch_suggest = false)
    @test StrictMode._failed(only(f for f in fs if f.func == "K"))
    @test StrictMode._failed(only(f for f in fs if f.func == "KF"))
    @test count(f -> f.func == "bound", fs) == 1
    items = StrictMode._compiled_items(U; guarantees = (:typestable,))
    @test length(items) == 3
end

@testitem "a declaration on another module's function is scoped by the module that wrote the method" begin
    using StrictMode
    StrictMode.clear_declarations!()
    module DeclForeign
    struct Foo
        x::Int
    end
    Base.getproperty(f::Foo, s::Symbol) = s === :y ? Any[1][1] : getfield(f, s)
    bar(x::Int) = x > 0 ? x : "neg"
    end
    D = DeclForeign
    StrictMode.register_strict!(Base.getproperty, (D.Foo, Symbol); guarantees = (:typestable,))
    StrictMode.register_strict!(D.bar, (Int,); guarantees = (:typestable,))
    fs = audit(D)
    @test StrictMode._failed(only(f for f in fs if f.func == "getproperty"))
    @test StrictMode._failed(only(f for f in fs if f.func == "bar"))
    @test Set(nameof(first(i)) for i in StrictMode._registry_items(; modules = [D])) == Set([:getproperty, :bar])
    # A module that wrote neither method is not handed them.
    @test isempty(StrictMode._registry_items(; modules = [Base]))
    @test StrictMode._registry_breakdown(StrictMode._registry_items()) == [:DeclForeign => 2]
    load = StrictMode._module_load_items(D, (:noalloc,))
    @test only(i[3] for i in load if first(i) === Base.getproperty) == (:typestable,)
    StrictMode.clear_declarations!()
    Base.delete_method(which(getproperty, (D.Foo, Symbol)))
end

@testitem "a keyword body answers to the constructor or callable it belongs to" begin
    using StrictMode
    module KwBodies
    using StrictMode
    struct Tracker{T}                        # its inner constructor's keyword body has no name
        a::Vector{T}
        Tracker{T}(x; c = 1) where {T} = new{T}(T[x + c])
    end
    Tracker(x::T; c = 1) where {T} = Tracker{T}(x; c)
    struct Scaled                            # a callable object with a keyword method
        k::Int
    end
    (s::Scaled)(x; by = 2) = [s.k * x * by]
    struct Unit end                          # a singleton callable with a keyword method
    (::Unit)(x; by = 2) = [x * by]
    struct Plain                             # its keyword body is held to the guarantee
        k::Int
    end
    (p::Plain)(x; by = 2) = [p.k * x * by]
    @strict_exempt :noalloc Tracker
    @strict_exempt :noalloc Scaled
    @strict_exempt :noalloc Unit
    end
    K = KwBodies
    K.Tracker(1.0); K.Tracker{Float32}(1; c = 2); K.Scaled(1)(2; by = 3); K.Unit()(2); K.Plain(1)(2)
    fs = audit(K; sweep = true, guarantees = (:noalloc,), dispatch_suggest = false)
    # Every row is named after something an exemption can name, and the exempted ones are exempt.
    @test !any(f -> f.func == "_" || startswith(f.func, "#_#"), fs)
    for name in ("Tracker", "Scaled", "Unit")
        rows = [f for f in fs if f.func == name || startswith(f.func, "#$name#")]
        @test !isempty(rows)
        @test all(f -> f.status === :info && startswith(f.reason, "exempt"), rows)
    end
    plain = [f for f in fs if f.func == "Plain"]
    @test !isempty(plain) && all(StrictMode._failed, plain)
    # `only` and `exempt` reach the same bodies by the same names.
    sweep(; kw...) = audit(K; sweep = true, guarantees = (:noalloc,), dispatch_suggest = false, kw...)
    @test isempty(sweep(; exempt = (:Plain,), only = (:Plain,)))
    @test all(f -> f.func == "Plain", sweep(; only = (:Plain,)))
end
