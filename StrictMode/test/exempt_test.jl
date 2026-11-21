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

    @test_throws StrictMode.StrictViolation (
        @eval module PolNoFilter
        using StrictMode
        kernel_hot(x::Float64) = x * 2.0
        plan_cold(n::Int) = n > 0 ? collect(1:n) : "none"
        @strict_policy :default
        end
    )

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
        logs, _ = Test.collect_test_logs() do
            include(path)
        end
        # Only `:noalloc` was excused, and only that guarantee may fall silent: what else the
        # closure trips is platform-dependent (`joinpath(homedir(), …)` boxes on Windows).
        @test !occursin("noalloc", join(string(r.message) for r in logs))
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

@testitem "a caller whose only allocation is an exempt callee is a note" begin
    using StrictMode, Test
    # Names unique to this item: an exemption is matched by function name in every loaded module.
    module ExemptCallers
    using StrictMode
    const BUF = Ref(Float64[])
    @noinline function xgrow_note!(n::Int)
        length(BUF[]) < n && (BUF[] = zeros(n))
        return BUF[]
    end
    const BOXES = Any[1]
    @noinline xbox_note!(n::Int) = BOXES[1] + n
    StrictMode._exempt!(:xgrow_note!; guarantees = (:noalloc,), reason = "grows to a high-water mark")
    StrictMode._exempt!(:xbox_note!; guarantees = (:noalloc,), reason = "boxes")
    @noinline xbox_typed!(n::Int) = (BOXES[1] + n)::Int
    StrictMode._exempt!(:xbox_typed!; guarantees = (:noalloc,), reason = "boxes")
    only_grows(n::Int) = (b = xgrow_note!(n); b[1])
    also_allocs(n::Int) = (b = xgrow_note!(n); sum(zeros(n)) + b[1])
    calls_boxer(n::Int) = xbox_note!(n) + 1
    calls_typed_boxer(n::Int) = xbox_typed!(n) + 1
    end
    E = ExemptCallers
    E.only_grows(4); E.also_allocs(4); E.calls_boxer(1); E.calls_typed_boxer(1)
    noalloc(fn) = only(StrictMode.findings(fn, (Int,); guarantees = (:noalloc,)))

    r = noalloc(E.only_grows)
    @test r.status === :info
    @test occursin("xgrow_note!", r.reason)
    @test !StrictMode._failed(r)

    # Its own allocation is not excused by reaching an exempt one.
    @test StrictMode._failed(noalloc(E.also_allocs))
    noboxing(fn) = only(StrictMode.findings(fn, (Int,); guarantees = (:noboxing,)))
    # `:noboxing` is not excused by a `:noalloc` exemption.
    @test StrictMode._failed(noboxing(E.calls_boxer))
    @test StrictMode._failed(noboxing(E.calls_typed_boxer))
    # Under `:noalloc` a box is an allocation, so the callee's boxing is excused…
    r = noalloc(E.calls_typed_boxer)
    @test r.status === :info && occursin("xbox_typed!", r.reason)
    # …and the caller's own is not: it adds 1 to the callee's `Any` result by dispatch.
    @test StrictMode._failed(noalloc(E.calls_boxer))

    logs = Test.collect_test_logs() do
        @strict E.only_grows(4)
    end[1]
    @test !any(l -> l.level === Base.CoreLogging.Warn, logs)
end

@testitem "an exempt callee is a note whether or not its throw is caught" begin
    using StrictMode, Test
    # Names unique to this item: an exemption is matched by function name in every loaded module.
    module ExemptCaught
    using StrictMode
    # Its only allocation is the exception of a throw that its own handler catches and returns from.
    @noinline function xcaught_note!(n::Int)
        try
            n < 0 && throw(ArgumentError("negative"))
        catch
            return 0
        end
        return n
    end
    @noinline xplain_note!(n::Int) = n < 0 ? length(zeros(n)) : n
    # The message of its caught throw is built by `print` over a `Vararg{Any}` tuple, which boxes.
    @noinline function xcaught_box!(n::Int)
        try
            n < 0 && throw(ArgumentError(string("negative: ", n)))
        catch
            return 0
        end
        return n
    end
    const LATE = Any[1]
    @noinline xlate_box(n::Int) = (LATE[1] + n)::Int
    # Allocates first, then calls a callee that boxes.
    @noinline function xgrow_then_box!(n::Int)
        v = zeros(n)
        return xlate_box(n) + length(v)
    end
    for name in (:xcaught_note!, :xplain_note!, :xcaught_box!, :xgrow_then_box!)
        StrictMode._exempt!(name; guarantees = (:noalloc,), reason = "grows")
    end
    caught_caller(n::Int) = xcaught_note!(n) + 1
    plain_caller(n::Int) = xplain_note!(n) + 1
    own_caller(n::Int) = xcaught_note!(n) + sum(zeros(n))
    boxed_caller(n::Int) = xcaught_box!(n) + 1
    late_caller(n::Int) = xgrow_then_box!(n) + 1
    end
    E = ExemptCaught
    for fn in (E.caught_caller, E.plain_caller, E.own_caller, E.boxed_caller, E.late_caller)
        fn(1)
    end
    noalloc(fn) = only(StrictMode.findings(fn, (Int,); guarantees = (:noalloc,)))
    reaches_box(fn, name) = any(
        o -> occursin(name, string(o.signature)) || any(p -> occursin(name, string(p)), o.path),
        StrictMode._signal_origin(fn, (Int,); mode = :boxing)
    )

    for (fn, callee) in ((E.caught_caller, "xcaught_note!"), (E.plain_caller, "xplain_note!"))
        r = noalloc(fn)
        @test r.status === :info
        @test !StrictMode._failed(r)
        @test occursin(callee, r.reason)
    end
    # Its own allocation is not excused by reaching an exempt one.
    @test StrictMode._failed(noalloc(E.own_caller))
    # Under `:noalloc` the exemption excuses the callee's boxing too, wherever in the callee it lies.
    # Under `:noboxing` it excuses nothing, and the walk that names an origin finds the boxing there.
    noboxing(fn) = only(StrictMode.findings(fn, (Int,); guarantees = (:noboxing,)))
    for (fn, callee) in ((E.boxed_caller, "xcaught_box!"), (E.late_caller, "xgrow_then_box!"))
        r = noalloc(fn)
        @test r.status === :info && occursin(callee, r.reason)
        @test StrictMode._failed(noboxing(fn))
        @test reaches_box(fn, callee)
    end
    @test reaches_box(E.late_caller, "xlate_box")
end

@testitem "an exempt function does not excuse a callable it was handed, in the scan" begin
    using StrictMode, Test
    # The same fixture as StrictModeTest's proof item, so the two tiers can be compared.
    module ExemptHanded
    using StrictMode
    const POOL = Ref(Float64[])
    @noinline function xh_grow!(n::Int)
        length(POOL[]) < n && (POOL[] = zeros(n))
        return POOL[]
    end
    @strict_exempt :noalloc reason = "pool" xh_grow!
    @noinline xh_withbuf(f::F, n) where {F} = f(xh_grow!(n))
    @strict_exempt :noalloc reason = "borrows the pool" xh_withbuf
    @noinline mk(n) = zeros(n)
    const BOXES = Any[1.0]
    cb(n::Int) = xh_withbuf(b -> sum(mk(n)) + b[1], n)
    cb_inline(n::Int) = xh_withbuf(b -> sum(zeros(n)) + b[1], n)
    named_cb(b) = sum(zeros(length(b))) + b[1]
    cb_named(n::Int) = xh_withbuf(named_cb, n)
    cb_box(n::Int) = xh_withbuf(b -> (BOXES[1] + b[1])::Float64, n)
    struct Cb2
        n::Int
    end
    (c::Cb2)(b::Vector{Float64}) = sum(zeros(c.n)) + b[1]
    (c::Cb2)(b::Vector{Float64}, k::Int) = b[k]
    cb_struct2(n::Int) = xh_withbuf(Cb2(n), n)
    @noinline xh_withbufs(fs::Vector{F}, n) where {F} = fs[1](xh_grow!(n))
    @strict_exempt :noalloc reason = "vec" xh_withbufs
    const FS = [b -> sum(zeros(length(b))) + b[1]]
    cb_vec(n::Int) = xh_withbufs(FS, n)
    @noinline xh_withhooks(hooks::Vector{Function}, n::Int) = (
        b = xh_grow!(n); for h in hooks
            h(b)
        end; b[1]
    )
    @strict_exempt :noalloc reason = "runs hooks" xh_withhooks
    const HOOKS = Function[b -> sum(zeros(length(b)))]
    cb_hooks(n::Int) = xh_withhooks(HOOKS, n)
    struct Hook
        f::Function
    end
    @noinline xh_withhook(h::Hook, n::Int) = (b = xh_grow!(n); h.f(b); b[1])
    @strict_exempt :noalloc reason = "runs a hook" xh_withhook
    const HOOK = Hook(b -> sum(zeros(length(b))))
    cb_field(n::Int) = xh_withhook(HOOK, n)
    @noinline xh_withany(@nospecialize(f), n::Int) = (b = xh_grow!(n); f(b); b[1])
    @strict_exempt :noalloc reason = "nospecialize" xh_withany
    const ANYCB = Ref{Any}(b -> sum(zeros(length(b))))
    cb_any(n::Int) = xh_withany(ANYCB[], n)
    # Callables nested three and five levels deep in tuples.
    @noinline xh_run3(h, n::Int) = h[1][1][1](xh_grow!(n))
    @strict_exempt :noalloc reason = "runs" xh_run3
    const H3A = (((b -> sum(zeros(length(b))) + b[1],),),)
    const H3B = (((b -> (BOXES[1] + b[1])::Float64,),),)
    cb_deep3(n::Int) = xh_run3(H3A, n)
    cb_deep3box(n::Int) = xh_run3(H3B, n)
    @noinline xh_run5(h, n::Int) = h[1][1][1][1][1](xh_grow!(n))
    @strict_exempt :noalloc reason = "runs" xh_run5
    const H5A = (((((b -> sum(zeros(length(b))) + b[1],),),),),)
    cb_deep5(n::Int) = xh_run5(H5A, n)
    # A callable struct held in a field of an abstract type that `Function` does not intersect, and
    # a closure held in a field declared `Any`.
    abstract type AbsCb end
    struct CbImpl <: AbsCb end
    (::CbImpl)(b::Vector{Float64}) = sum(zeros(length(b))) + b[1]
    struct AbsHook
        f::AbsCb
    end
    @noinline xh_withabs(h::AbsHook, n::Int) = (b = xh_grow!(n); h.f(b); b[1])
    @strict_exempt :noalloc reason = "runs a hook" xh_withabs
    const ABSHOOK = AbsHook(CbImpl())
    cb_absfield(n::Int) = xh_withabs(ABSHOOK, n)
    struct AnyHook
        f::Any
    end
    @noinline xh_withanyf(h::AnyHook, n::Int) = (b = xh_grow!(n); h.f(b); b[1])
    @strict_exempt :noalloc reason = "runs a hook" xh_withanyf
    const ANYHOOK = AnyHook(b -> sum(zeros(length(b))))
    cb_anyfield(n::Int) = xh_withanyf(ANYHOOK, n)
    # The callback allocates and boxes nothing: every site is the exempt functions' own code.
    cb_clean(n::Int) = xh_withbuf(b -> b[1], n)
    plain(n::Int) = (b = xh_grow!(n); b[1])
    # Plain data nested five levels deep holds no callable.
    @noinline xh_data(d, n::Int) = (b = xh_grow!(n); b[1] + d[1][1][1][1][1])
    @strict_exempt :noalloc reason = "pool" xh_data
    const D5 = (((((1.0,),),),),)
    data_deep(n::Int) = xh_data(D5, n)
    end
    E = ExemptHanded
    noalloc(fn) = only(StrictMode.findings(fn, (Int,); guarantees = (:noalloc,)))
    for fn in (
            E.cb, E.cb_inline, E.cb_named, E.cb_box, E.cb_struct2, E.cb_vec, E.cb_hooks, E.cb_field, E.cb_any,
            E.cb_deep3, E.cb_deep3box, E.cb_deep5, E.cb_absfield, E.cb_anyfield,
        )
        fn(3)
        @test StrictMode._failed(noalloc(fn))
    end
    for fn in (E.cb_clean, E.plain, E.data_deep)
        fn(3)
        r = noalloc(fn)
        @test r.status === :info && !StrictMode._failed(r)
    end
    # A signature with a `Vararg` tail, as a callee called with a splat has: its element type is what
    # an argument carries.
    @test StrictMode._handed_types(Tuple{typeof(E.plain), Vararg{Union{Char, String}}}) == Any[]
    @test StrictMode._handed_types(Tuple{typeof(E.plain), Int, Vararg{typeof(E.named_cb)}}) == Any[typeof(E.named_cb)]
end

@testitem "an allocation barrier excuses allocation only; its other causes are reported at it" begin
    using StrictMode, Test
    module BarrierRule
    const OPT = Base.OncePerTask{Vector{Float64}}(() -> zeros(16))
    @noinline acc(::Type{Float64}) = OPT()            # a task-local lookup on every call
    entry(x::Vector{Float64}) = (w = acc(Float64); w[1] = x[1]; w[1])
    const D = Dict{Symbol, Vector{Float64}}(:a => zeros(4))
    @noinline own_lookup() = D[:a]
    mixed(x::Vector{Float64}) = (w = acc(Float64); v = own_lookup(); w[1] + v[1])
    end
    x = [1.0]
    BarrierRule.entry(x); BarrierRule.mixed(x)
    saved = copy(StrictMode._ALLOC_BARRIERS)
    try
        StrictMode.register_alloc_barrier!(BarrierRule.acc)
        owned(f, T) = only(StrictMode.findings(f, T; guarantees = (:owned,)))
        # Reported once, at the barrier.
        @test StrictMode._failed(owned(BarrierRule.acc, (Type{Float64},)))
        # A caller whose only cause is inside the barrier points there: neither failed nor passed.
        e = owned(BarrierRule.entry, (Vector{Float64},))
        @test e.status === :info && occursin("reaches `acc`", e.reason)
        # A cause of the caller's own is still judged.
        @test StrictMode._failed(owned(BarrierRule.mixed, (Vector{Float64},)))
        # The macro says the same at the call site.
        @test_logs (:info, r"reaches `acc`") @assert_owned BarrierRule.entry(x)
        @test_throws "per task or per thread" @assert_owned BarrierRule.acc(Float64)
    finally
        empty!(StrictMode._ALLOC_BARRIERS); union!(StrictMode._ALLOC_BARRIERS, saved)
        StrictMode.clear_cache!()
    end
end

@testitem "a package's :noalloc exemption covers that package's methods only" begin
    using StrictMode
    module Scoped6
    using StrictMode
    struct Stack; v::Vector{Int}; end
    @strict_exempt :noalloc reason = "debug" Base.string(s::Stack) = "Stack"
    shower(n::Int) = length(string(n))
    @noinline mine(n::Int) = zeros(n)
    @strict_exempt :noalloc reason = "setup" :mine
    uses_mine(n::Int) = (mine(n); nothing)
    end
    Scoped6.shower(3); Scoped6.uses_mine(3)
    nf(f) = only(StrictMode.findings(f, (Int,); guarantees = (:noalloc,)))
    @test StrictMode._failed(nf(Scoped6.shower))          # an unrelated `string` is not excused
    @test nf(Scoped6.uses_mine).status === :info           # its own callee is
end

@testitem "an exemption of a method on another module's function excuses only that method" begin
    using StrictMode

    # Two modules add methods to the same function, `Base.length`, and one of them also extends a
    # function the other owns. Only the module that wrote `@strict_exempt` has a method excused.
    module SweptOwner
    struct Grows
        n::Int
    end
    Base.length(g::Grows) = length(zeros(g.n))
    owned(g::Grows) = length(zeros(g.n))
    end
    module Exempter
    using StrictMode
    import ..SweptOwner
    struct Foo end
    @strict_exempt Base.length(::Foo) = 1
    @strict_exempt SweptOwner.owned(::Foo) = 2
    end
    B, A = SweptOwner, Exempter
    length(B.Grows(3)); B.owned(B.Grows(3))

    fs = audit(B; sweep = true, guarantees = (:noalloc,), dispatch_suggest = false)
    @test count(f -> f.func == "length", fs) == 1
    @test count(f -> f.func == "owned", fs) == 1
    ms, skipped = StrictMode.module_methods(B)
    @test count(m -> m.name === :length, ms) == 1
    @test count(m -> m.name === :owned, ms) == 1
    # The exempting module's own methods are still excused.
    ms, skipped = StrictMode.module_methods(A)
    @test !any(m -> m.name in (:length, :owned), ms)
    @test get(skipped, :exempt, 0) == 2
end
