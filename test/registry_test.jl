@testitem "register_strict! + check_all aggregate findings" begin
    using StrictMode
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

    fs = check_all(; fail = :none)
    @test StrictMode.nfailures(fs) ≥ 1                 # boxy allocates
    @test_throws StrictViolation check_all(; fail = :error)
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
    boxy(t::Tuple{Int, Float64, Float32}) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    StrictMode.register_strict!(boxy, (Tuple{Int, Float64, Float32},))
    @test_throws StrictViolation StrictMode._auto_check_module(@__MODULE__)
end

@testitem "check_compiled sweeps actually-compiled instances" begin
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

    fs = check_compiled(Swept; guarantees = (:noalloc, :noboxing))
    @test any(f -> f.func == "g" && f.status === :fail, fs)
    @test any(f -> f.func == "f" && f.status === :pass, fs)
end
