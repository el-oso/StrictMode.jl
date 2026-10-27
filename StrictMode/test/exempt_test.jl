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

@testitem "a narrowed exemption protects a workspace allocator's return type" begin
    using StrictMode
    StrictMode.clear_declarations!()

    struct WsOk
        buf::Vector{Float64}
    end
    struct WsF32
        buf::Vector{Float32}
    end

    # Both allocators must allocate, so both are excused for it. The concrete return type is the
    # whole reason their callers can be fast, so `:typestable` stays on — and catches the one that
    # picks its element type from a VALUE, whose callers would get a `Union` and dispatch on it.
    # Exempting the function outright would hide exactly that.
    @strict_exempt :noalloc reason = "allocates the workspace once" begin
        ws_good(n::Int) = WsOk(Vector{Float64}(undef, n))
        ws_sloppy(n::Int) = n > 8 ? WsOk(zeros(n)) : WsF32(zeros(Float32, n))
    end
    StrictMode.register_strict!(ws_good, (Int,); guarantees = (:typestable, :noalloc))
    StrictMode.register_strict!(ws_sloppy, (Int,); guarantees = (:typestable, :noalloc))

    fs = StrictMode._findings_all()
    noalloc = filter(f -> f.guarantee === :noalloc, fs)
    @test length(noalloc) == 2
    @test all(f -> f.status === :info, noalloc)                      # excused, and visibly so
    @test all(f -> occursin("allocates the workspace once", f.reason), noalloc)

    @test only(f for f in fs if f.guarantee === :typestable && f.func == "ws_good").status === :pass
    @test only(f for f in fs if f.guarantee === :typestable && f.func == "ws_sloppy").status === :fail

    StrictMode.clear_declarations!()
end

@testitem "an exemption covers the closures the exempted function defines" begin
    using StrictMode
    # A closure is a separate method with a mangled name (`#path##0`), so a name exemption that
    # did not demangle it left the allocation it was written to excuse reported anyway.
    mktemp() do path, io
        write(
            io, """
            module ClosureExempt
            using StrictMode
            confpath() = get(() -> joinpath(homedir(), "a", "b.toml"), ENV, "CLOSURE_EXEMPT_PATH")
            @strict_exempt :noalloc confpath reason = "builds a path"
            @strict_policy :default
            end
            """
        )
        close(io)
        @test_logs include(path)          # no warning: the closure answers to confpath's exemption
    end

    @test StrictMode._demangle(Symbol("#confpath##0")) === :confpath   # closure
    @test StrictMode._demangle(Symbol("#confpath#12")) === :confpath   # kwsorter
    @test StrictMode._demangle(Symbol("#confpath#inner")) === :confpath  # @strict_stable body
    @test StrictMode._demangle(:confpath) === :confpath
end

@testitem "a macro that emits a definition keeps its docstring" begin
    using StrictMode
    # `@doc` can only document a bare definition. A macro expanding to a block must mark which
    # subexpression carries the docstring, or the definition cannot be documented at all.
    load(name, line) = include_string(
        Main, "module $name\nusing StrictMode\n\"Doc of it.\"\n$line\nend", "docstring_test"
    )
    cases = (
        ("DocEx1", "@strict_exempt :noalloc reason = \"r\" d1() = [1]", :d1),
        ("DocEx2", "@strict_function d2(x::Int) = x + 1", :d2),
        ("DocEx3", "@strict_stable d3(x::Int) = x + 1", :d3),
        ("DocEx4", "@strict_exempt :noalloc reason = \"r\" begin\n d4() = [1]\nend", :d4),
    )
    for (name, line, fname) in cases
        mod = load(name, line)
        doc = string(Base.Docs.doc(Base.Docs.Binding(mod, fname)))
        @test occursin("Doc of it.", doc)
    end
end
