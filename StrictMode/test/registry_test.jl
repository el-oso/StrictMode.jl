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
    @test Set(sets[:all]) == Set(StrictMode.guarantee_names())

    # A name expands wherever a guarantee may be written, so it composes with individual ones.
    @test StrictMode._check_guarantees(:default) == sets[:default]
    @test Set(StrictMode._check_guarantees((:default, :vectorized))) ==
        Set((sets[:default]..., :vectorized))
    @test_throws ArgumentError StrictMode._check_guarantees(:kernel)   # not a set, not a guarantee
end
