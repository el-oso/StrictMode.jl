@testitem "register_strict! + the registry sweep aggregate findings" begin
    using StrictMode, StrictModeTest
    empty!(StrictMode.registered_strict())
    clean(a::NTuple{3, Float64}, b::NTuple{3, Float64}) = a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
    boxy(t::Tuple{Int, Float64, Float32}) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )

    StrictMode.register_strict!(clean, (NTuple{3, Float64}, NTuple{3, Float64}))
    StrictMode.register_strict!(boxy, (Tuple{Int, Float64, Float32},))
    @test length(StrictMode.registered_strict()) == 2

    fs = StrictMode._findings_all()
    @test StrictMode.nfailures(fs) ≥ 1                 # boxy allocates
    @test_throws StrictViolation test_registered()
end

@testitem "register_strict! skips non-concrete signatures" begin
    using StrictMode
    empty!(StrictMode.registered_strict())
    g(x::Number) = x + one(x)
    StrictMode.register_strict!(g, (Number,))           # abstract → skipped with a warning
    @test isempty(StrictMode.registered_strict())
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
    empty!(StrictMode.registered_strict())
    unstable(x::Int) = x > 0 ? 1 : "negative"
    StrictMode.register_strict!(unstable, (Int,); guarantees = (:typestable,))
    @test_throws StrictViolation StrictMode._auto_check_module(@__MODULE__)
end

@testitem "register_strict! accepts a ::Type{T} argument signature (F37)" begin
    using StrictMode
    # `isconcretetype(Type{Float64})` is `false` (a real Julia quirk) even though `Type{Float64}`
    # is a fully-specified, singleton dispatch signature — `all(isconcretetype, tt)` would treat
    # every `::Type{T}`-argument function as "non-concrete" and silently skip it.
    empty!(StrictMode.registered_strict())
    typed_alloc(::Type{T}, n::Int) where {T} = Vector{T}(undef, n)
    StrictMode.register_strict!(typed_alloc, (Type{Float64}, Int))
    @test length(StrictMode.registered_strict()) == 1
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

@testitem "an empty registry warns loudly instead of reporting a silent green" begin
    using StrictMode, StrictModeTest
    # The registry is a plain Dict populated at declaration time, and `@strict_function` runs at its
    # own module's precompile — a cross-package mutation that is DISCARDED on a cached pkgimage
    # load. So a consumer's test process sees an empty registry however many declarations its src/
    # carries, and a registry sweep would then return zero findings and pass: a green that proves
    # nothing. That must be audible from both tiers.
    old = copy(StrictMode.STRICT_REGISTRY)
    try
        empty!(StrictMode.STRICT_REGISTRY)
        @test isempty(@test_logs (:warn,) match_mode = :any StrictMode._findings_all())
        @test isempty(@test_logs (:warn,) match_mode = :any test_registered())
    finally
        merge!(StrictMode.STRICT_REGISTRY, old)
    end
end
