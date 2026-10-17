@testitem "@strict_exempt records cold functions (def + name forms)" begin
    using StrictMode
    StrictMode.clear_declarations!()

    @strict_exempt xcold(n::Int) = collect(1:n)          # definition form
    @test xcold(3) == [1, 2, 3]
    @test StrictMode._is_exempt(xcold)

    @strict_exempt :xbyname                              # name form
    @test any(e -> e.func === :xbyname, StrictMode.exemptions())

    # An exemption records WHERE it is written, so a report can send a reader to the line.
    e = only(x for x in StrictMode.exemptions() if x.func === :xcold)
    @test endswith(e.file, "exempt_test.jl") && e.line > 0
    @test isnothing(e.guarantees) && isnothing(e.types)   # the whole function, every guarantee
end

@testitem "exempt functions are skipped by the registry sweep" begin
    using StrictMode
    StrictMode.clear_declarations!()
    StrictMode.clear_declarations!()

    # a hot, boxing function: reported by default
    xboxy(t::Tuple{Int, Float64, Float32}) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    StrictMode.register_strict!(xboxy, (Tuple{Int, Float64, Float32},))
    @test nfailures(StrictMode._findings_all()) ≥ 1

    StrictMode._exempt!(:xboxy)                          # opt it out
    @test nfailures(StrictMode._findings_all()) == 0

    StrictMode.clear_declarations!()                    # do not leak into other test items
end

@testitem "@strict module inlines @strict_exempt (no unresolved macrocall in the module)" begin
    using StrictMode
    modexpr = :(
        module K
        hot(x::Int) = x * 2
        @strict_exempt cold(x::Int) = collect(1:x)
        end
    )
    out = StrictMode._strict_module(modexpr)
    inner = Meta.isexpr(out, :escape) ? out.args[1] : out
    s = string(inner)
    @test occursin("register_strict!", s)               # the hot def is registered
    @test occursin("_exempt!", s)                       # the cold def is exempted inline
    @test !occursin("@strict_exempt", s)                # …not left as a macrocall to resolve
end

@testitem "a narrowed exemption silences only the guarantee it names" begin
    using StrictMode
    StrictMode.clear_declarations!()

    # Allocates AND is type-unstable: two different guarantees have something to say.
    both(n::Int) = n > 0 ? collect(1:n) : "no"
    StrictMode.register_strict!(both, (Int,); guarantees = (:typestable, :noalloc))

    fs = StrictMode._findings_all()
    @test Set(f.guarantee for f in fs if StrictMode._failed(f)) == Set([:typestable, :noalloc])

    # Excuse only the allocation. Type stability must still be held against it — an opt-out that
    # quietly widened to everything would be the opposite of what was asked for.
    StrictMode._exempt!(:both; guarantees = (:noalloc,), reason = "builds the plan once")
    fs = StrictMode._findings_all()
    failed = Set(f.guarantee for f in fs if StrictMode._failed(f))
    @test :typestable in failed
    @test !(:noalloc in failed)

    # …and the exemption is VISIBLE in the output, carrying its reason, rather than silently absent.
    note = only(f for f in fs if f.guarantee === :noalloc)
    @test note.status === :info
    @test occursin("builds the plan once", note.reason)

    # A narrow exemption is not a whole-function one, so the sweeps do not skip the function.
    @test !StrictMode._is_exempt(both)

    StrictMode.clear_declarations!()
end

@testitem "@strict_exempt accepts a method on a foreign function" begin
    using StrictMode
    StrictMode.clear_declarations!()

    # The census counts methods a package adds to Base functions, so there must be a way to opt one
    # out. Before, this spelling threw `unsupported definition`.
    module ForeignEx
    using StrictMode
    struct Holder end
    @strict_exempt Base.length(::Holder) = 1
    end

    @test any(e -> e.func === :length, StrictMode.exemptions())
    @test Base.@invokelatest(length(ForeignEx.Holder())) == 1

    # …and the coverage gate honors it: the method is excused, not reported.
    fs = audit(ForeignEx; require = :all)
    @test !any(
        f -> f.guarantee === :coverage && StrictMode._failed(f) && f.func == "length", fs
    )

    StrictMode.clear_declarations!()
end

@testitem "@strict_exempt takes a block, a guarantee, and an include" begin
    using StrictMode
    StrictMode.clear_declarations!()

    # A block is one visible marker for a cold region instead of one per function. Each definition
    # still records this line, so a report points at the function and at the region that excused it.
    @strict_exempt reason = "plan-time setup" begin
        blk_a(n::Int) = collect(1:n)
        blk_b(x) = Dict(:k => x)
    end
    @test blk_a(2) == [1, 2]
    @test StrictMode._is_exempt(blk_a) && StrictMode._is_exempt(blk_b)
    @test all(
        e -> e.reason == "plan-time setup",
        filter(e -> e.func in (:blk_a, :blk_b), StrictMode.exemptions())
    )

    # A leading guarantee narrows the block: the subject is the LAST positional, which is what
    # keeps `@strict_exempt :foo` meaning the function `foo` rather than the guarantee `foo`.
    @strict_exempt :noalloc reason = "a factory must allocate" begin
        blk_factory(n::Int) = Vector{Float64}(undef, n)
    end
    @test !StrictMode._is_exempt(blk_factory)                            # not whole-function
    @test StrictMode._is_exempt(blk_factory, (Int,), :noalloc)
    @test !StrictMode._is_exempt(blk_factory, (Int,), :typestable)       # still held to that

    # An `include` exempts what the file defines, found by comparing the module's methods on either
    # side of the call — so a definition inside a file that file includes is covered too, which an
    # AST rewrite would have had to chase.
    dir = mktempdir()
    write(joinpath(dir, "outer.jl"), "cold_outer(n::Int) = collect(1:n)\ninclude(joinpath(@__DIR__, \"inner.jl\"))\n")
    write(joinpath(dir, "inner.jl"), "cold_inner(x) = Dict(:k => x)\n")
    @eval module IncExempt
        using StrictMode
        hot_kept(x::Int) = x + 1
        @strict_exempt reason = "plan-time file" include($(joinpath(dir, "outer.jl")))
    end
    @test !StrictMode._is_exempt(IncExempt.hot_kept)
    @test StrictMode._is_exempt(IncExempt.cold_outer)
    @test StrictMode._is_exempt(IncExempt.cold_inner)                    # the NESTED include

    # A block with no definitions is a mistake worth naming rather than a silent no-op.
    @test_throws LoadError @eval @strict_exempt begin
        x = 1
    end

    StrictMode.clear_declarations!()
end

@testitem "@strict_policy scopes by name, so a mixed file needs no submodule" begin
    using StrictMode
    StrictMode.clear_declarations!()

    # `only` keeps the cold helper out of scope, so the module loads; without it the same module is
    # rejected. Scoping by NAME rather than by region composes with the census instead of adding a
    # scope the census does not model.
    @eval module PolOnly
        using StrictMode
        kernel_hot(x::Float64) = x * 2.0
        plan_cold(n::Int) = n > 0 ? collect(1:n) : "none"
        @strict_policy :default only = r"^kernel_"
    end
    @test PolOnly.kernel_hot(1.0) == 2.0

    @test_throws StrictMode.StrictViolation (@eval module PolNoFilter
        using StrictMode
        kernel_hot(x::Float64) = x * 2.0
        plan_cold(n::Int) = n > 0 ? collect(1:n) : "none"
        @strict_policy :default
    end)

    StrictMode.clear_declarations!()
end
