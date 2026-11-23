# A generated corpus for `:noalloc`: every combination of a wrapper (none, an exempt function, a
# registered barrier, a `OncePerProcess` or `OncePerThread` guard, or two of them nested), the way the
# wrapper reaches a helper, whether the caller also calls the helper itself, whether the helper is
# compiled for one caller or several, and what the helper does. A second set gives the helper's
# caller, or the wrapper, each of the declaration and call shapes in `SHAPES`. The expected verdict of each case is
# computed from the documented rules alone (`expected`), never from either engine, and both engines
# and `divergence_report` are compared against it. Where the helper is reached by `invoke`, a module
# sweep of the helper's function is compared too (R10).
@testmodule NoallocCorpus begin
    using StrictMode, StrictModeTest

    const WRAPPERS = (:none, :exempt, :barrier, :oncep, :oncet)
    const REACHES = (:direct, :inside, :handed, :lock_inner, :lock_outer)
    const REPEATS = (:once, :after, :before)
    const COMPS = (:single, :multi)
    const EFFECTS = (:alloc, :iowait, :throw, :caught, :none)
    const NESTS = (:bar_in_ex, :ex_in_bar)
    # How a function is declared and called (`shaped`). Each is a call whose callee Julia compiles for
    # a signature other than the argument types at the call, or reaches by a route other than an
    # ordinary positional call.
    const SHAPES = (:any, :absvec, :vararg, :invoke, :nospec, :typespec, :typewide, :callable, :kw, :pair, :pair2)
    const POSITIONS = (:helper, :wrapper)
    const SHAPE_EFFECTS = (:alloc, :iowait, :caught, :none)

    # The helper's body for each effect: `h(w::W, n::Int)::Float64`.
    const EFFECT_SRC = Dict(
        :alloc => "sum(zeros(n))",
        :iowait => "(write(w.io, w.a); 0.0)",
        :throw => "n < 0 ? throw(ArgumentError(\"bad n = \$n\")) : Float64(n)",
        :caught => "try\n        n < 0 && throw(ArgumentError(\"bad n = \$n\"))\n        Float64(n)\n    catch\n        0.0\n    end",
        :none => "Float64(n) + 1.0",
    )

    struct Case
        name::String
        wrapper::Symbol     # one of WRAPPERS, or :nested
        nest::Symbol        # one of NESTS when wrapper === :nested, else :none
        reach::Symbol
        repeat::Symbol
        comp::Symbol
        effect::Symbol
        shape::Symbol       # one of SHAPES, or :plain
        pos::Symbol         # which function has the shape: one of POSITIONS, or :none
    end

    meaningful(w, r, rep) =
        !(w === :none && r in (:inside, :lock_inner)) &&     # no wrapper to be inside of
        !(w in (:oncep, :oncet) && r === :handed) &&          # a once-guard's initializer takes no argument
        !(r === :direct && rep !== :once)                     # a direct call repeated is the same case

    function cases()
        out = Case[]
        for w in WRAPPERS, r in REACHES, rep in REPEATS, c in COMPS, e in EFFECTS
            meaningful(w, r, rep) || continue
            push!(out, Case(join(("c", w, r, rep, c, e), "_"), w, :none, r, rep, c, e, :plain, :none))
        end
        for nst in NESTS, rep in REPEATS, c in COMPS, e in EFFECTS
            push!(out, Case(join(("n", nst, rep, c, e), "_"), :nested, nst, :inside, rep, c, e, :plain, :none))
        end
        return out
    end

    # Every shape, as the helper's caller under each wrapper and as the wrapper itself.
    function shape_cases()
        out = Case[]
        for s in SHAPES, w in WRAPPERS, rep in (:once, :after), c in COMPS, e in SHAPE_EFFECTS
            r = w === :none ? :direct : :inside
            meaningful(w, r, rep) || continue
            push!(out, Case(join(("s", s, w, rep, c, e), "_"), w, :none, r, rep, c, e, s, :helper))
        end
        for s in SHAPES, w in (:exempt, :barrier), c in COMPS, e in SHAPE_EFFECTS
            s in (:pair, :pair2) && continue        # two helpers, and there is one wrapper
            push!(out, Case(join(("sw", s, w, c, e), "_"), w, :none, :inside, :once, c, e, s, :wrapper))
        end
        return out
    end

    # The definition of `name` in shape `s`, running `inner` (an expression in `w` and `n`), and the
    # call of it from a scope that has `w::W` and `n::Int`.
    function shaped(s::Symbol, name::String, inner::String)
        def(sig, body = inner) = "@noinline function $sig\n    $body\nend"
        s === :any && return def("$name(w::Any, n::Real)"), "$name(w, n)"
        s === :absvec && return def("$name(w, v::AbstractVector, n::Integer)"), "$name(w, w.a, n)"
        s === :vararg && return def("$name(xs...)", "w, n = xs[1], xs[2]\n    $inner"), "$name(w, n, 1, 2.0, 0x03)"
        s === :invoke && return def("$name(w, n::Integer)") * "\n@noinline $name(w, n::Int) = -1.0",
            "invoke($name, Tuple{W, Integer}, w, n)"
        s === :nospec && return def("$name(w, @nospecialize(x), n)"), "$name(w, w.a, n)"
        s === :typespec && return def("$name(::Type{T}, w, n) where {T}", "$inner + zero(T)"), "$name(Float64, w, n)"
        s === :typewide && return def("$name(T, w, n)"), "$name(Float64, w, n)"
        s === :callable && return "struct $(name)_T\n    k::Int\nend\n" * def("(m::$(name)_T)(w, n)", "$inner + m.k") *
            "\nconst $name = $(name)_T(0)", "$name(w, n)"
        s === :kw && return def("$name(w, n; k::Int = 0)", "$inner + k"), "$name(w, n; k = 0)"
        a, b = s === :pair ? (:nospec, :kw) : (:vararg, :typewide)
        da, ca = shaped(a, name * "a", inner)
        db, cb = shaped(b, name * "b", inner)
        return da * "\n" * db, "($ca + $cb)"
    end

    function source(k::Case)
        io = IOBuffer()
        println(io, "module M_", k.name)
        println(io, "using StrictMode")
        println(
            io, """
            mutable struct W
                io::IOStream
                a::Vector{Float64}
            end
            const LK = ReentrantLock()
            @noinline function h(w::W, n::Int)
                $(EFFECT_SRC[k.effect])
            end"""
        )
        hcall = "h(w, n)"
        if k.pos === :helper
            defs, hcall = shaped(k.shape, "mid", "h(w, n)")
            println(io, defs)
        end
        if k.comp === :single
            println(io, "@noinline site(w::W, n::Int) = $hcall")
        else
            println(io, "@noinline ha(w::W, n::Int) = $hcall")
            println(io, "@noinline hb(w::W, n::Int) = $hcall + 0.5")
            println(io, "@noinline site(w::W, n::Int) = ha(w, n) + hb(w, n)")
        end
        println(io, "const TW = W(open(tempname(), \"w\"), zeros(4))")
        w, r = k.wrapper, k.reach
        # What the wrapper runs, in terms of `w` and `n`.
        body = r === :direct ? "1.0" :
            r === :lock_inner ? "lock(() -> site(w, n), LK)" : "site(w, n)"
        call = ""
        if w === :nested
            inner = k.nest === :bar_in_ex ? "bar" : "ex"
            outer = k.nest === :bar_in_ex ? "ex" : "bar"
            println(io, "@noinline $inner(w::W, n::Int) = site(w, n)")
            println(io, "@noinline $outer(w::W, n::Int) = $inner(w, n)")
            println(io, "@strict_exempt :noalloc reason = \"corpus\" ex")
            call = "$outer(w, n)"
        elseif w === :none
            if r === :direct
                call = "site(w, n)"
            elseif r === :handed
                println(io, "@noinline wr(g::G, w::W, n::Int) where {G} = g(w, n)")
                call = "wr(site, w, n)"
            else
                call = "lock(() -> site(w, n), LK)"
            end
        elseif w in (:exempt, :barrier)
            if r === :handed
                println(io, "@noinline wr(g::G, w::W, n::Int) where {G} = g(w, n)")
                call = "wr(site, w, n)"
            elseif k.pos === :wrapper
                defs, call = shaped(k.shape, "wr", body)
                println(io, defs)
            else
                println(io, "@noinline wr(w::W, n::Int) = $body")
                call = r === :lock_outer ? "lock(() -> wr(w, n), LK)" : "wr(w, n)"
            end
            # A callable's method is named for its type.
            exname = k.pos === :wrapper && k.shape === :callable ? "wr_T" : "wr"
            w === :exempt && println(io, "@strict_exempt :noalloc reason = \"corpus\" $exname")
            r === :direct && (call = "wr(w, n) + site(w, n)")
        else
            T = w === :oncep ? "OncePerProcess" : "OncePerThread"
            ibody = replace(body, "(w, n)" => "(TW, 4)")
            println(io, "const ONCE = Base.$T{Float64}(() -> $ibody)")
            println(io, "wr(w::W, n::Int) = ONCE()")
            call = r === :lock_outer ? "lock(() -> wr(w, n), LK)" : "wr(w, n)"
            r === :direct && (call = "wr(w, n) + site(w, n)")
        end
        call = k.repeat === :after ? "$call + h(w, n)" :
            k.repeat === :before ? "h(w, n) + $call" : call
        println(io, "caller(w::W, n::Int) = $call")
        println(io, "end")
        return String(take!(io))
    end

    # A cause is an allocation or a wait, in the caller's own code, inside an exempt function, or
    # guarded by a barrier.
    #
    # R1 An uncaught throw is excused under `ignore_throw()`; a throw a returning catch handles
    #    allocates the message it builds. A stream write takes the stream's lock, which is a wait.
    # R2 A barrier (a once-guard's accessor, or a registered function) excuses what it guards,
    #    a function it is handed included.
    # R3 An exemption excuses what is inside the exempt function: a note from the scan, SM0018 from
    #    the proof, a failure there unless `allow_exempt = true`.
    # R4 Code handed to an exempt function and called by it is the caller's.
    # R5 A lock or stream the exempt function only uses, and a closure it defines around one, stay
    #    exempt.
    # R6 The wait of a `lock(f, l)` in the caller is the caller's.
    # R7 A helper the caller also calls itself is the caller's there.
    # R8 Any counted allocation is SM0002; counted causes that are all waits are SM0017; with no
    #    counted cause, exempt ones are R3.
    # R9 A callee is the method the call runs, however the call names it: the method `invoke` selects
    #    with a signature wider than its arguments is read, excused and counted as that method, not
    #    as the more specific one its argument types would dispatch to.
    # R10 A module sweep checks each specialization it lists as an entry point. The helper's wider
    #    method, compiled only through `invoke`, is one row, named `via invoke of` that method, and
    #    its causes are the helper's own effect. The specific method, `-1.0`, passes wherever it has
    #    a row; it has one when anything inferred a call of it, the analysis itself included. A
    #    declaration or a `types` exemption names the one method its signature selects: declaring
    #    `(W, Int)` leaves the wider row the only undeclared one, exempting `(W, Int)` leaves its
    #    verdict as it is, and exempting `(W, Integer)` turns it into an `:info` note in both tiers.
    #    The definition form records a method's own signature: of the specific method it leaves the
    #    wider row's verdict as it is, and of the wider method it makes that row a note.
    effect_cause(e) = e in (:alloc, :caught) ? :alloc : e === :iowait ? :wait : nothing

    # What a sweep of the helper's function reports, for a case whose helper is reached by `invoke`
    # (R10): the scan's and the proof's verdict of the `invoke` row, and of every other row.
    function expected_sweep(k::Case)
        (k.shape === :invoke && k.pos === :helper) || return nothing
        c = effect_cause(k.effect)
        v = c === :alloc ? (:fail, :SM0002) : c === :wait ? (:fail, :SM0017) : (:pass, nothing)
        return (;
            scan = v, proof = v, others = :pass, undeclared = [true],
            narrow = (; scan = v, proof = v), wide = (; scan = (:info, :SM0002), proof = (:info, :SM0002)),
            defnarrow = (; scan = v, proof = v), defwide = (; scan = (:info, :SM0002), proof = (:info, :SM0002)),
        )
    end

    function causes(k::Case)
        cs = Tuple{Symbol, Symbol}[]
        ec = effect_cause(k.effect)
        add!(c, ctx) = isnothing(c) || push!(cs, (c, ctx))
        w, r = k.wrapper, k.reach
        ctxw = w === :none ? :caller : w === :exempt ? :exempt : :guarded
        if r === :direct
            add!(ec, :caller)
        elseif r === :handed
            add!(ec, w === :exempt ? :caller : ctxw)
        elseif r === :inside
            add!(ec, ctxw)
        elseif r === :lock_inner
            add!(ec, ctxw)
            add!(:wait, ctxw)
        else
            add!(ec, ctxw)
            add!(:wait, :caller)
        end
        k.repeat === :once || add!(ec, :caller)
        return cs
    end

    # `(status, code)` for the scan, the proof, and the proof with `allow_exempt = true`; then whether
    # `divergence_report` lists a different verdict, and a different cause.
    function expected(k::Case)
        cs = causes(k)
        counted = [c for (c, ctx) in cs if ctx === :caller]
        exempt = any(((c, ctx),) -> ctx === :exempt, cs)
        s, p, pa = if :alloc in counted
            (:fail, :SM0002), (:fail, :SM0002), (:fail, :SM0002)
        elseif :wait in counted
            (:fail, :SM0017), (:fail, :SM0017), (:fail, :SM0017)
        elseif exempt
            (:info, :SM0002), (:fail, :SM0018), (:info, :SM0018)
        else
            (:pass, nothing), (:pass, nothing), (:pass, nothing)
        end
        # The scan's note and the proof's SM0018 name the same exempt callee, so they agree.
        sfail = s[1] === :fail
        pfail = p[1] === :fail && !(p[2] === :SM0018 && s[1] === :info)
        return (;
            name = k.name, scan = s, proof = p, proof_ae = pa,
            diverged = sfail != pfail, cause = sfail && p[1] === :fail && s[2] !== p[2],
            sweep = expected_sweep(k),
        )
    end

    verdict(f) = f.status === :pass ? (:pass, nothing) : (f.status, f.code)

    function observe(k::Case, M::Module)
        k.wrapper === :barrier && register_alloc_barrier!(M.wr isa Function ? M.wr : typeof(M.wr))
        k.wrapper === :nested && register_alloc_barrier!(M.bar)
        tt = (M.W, Int)
        try
            M.caller(M.TW, 2)
            scan = verdict(only(StrictMode.findings(M.caller, tt; guarantees = (:noalloc,))))
            proof = verdict(only(StrictModeTest.proof_findings(M.caller, tt; guarantees = (:noalloc,))))
            proof_ae = verdict(only(StrictModeTest.proof_findings(M.caller, tt; guarantees = (:noalloc,), allow_exempt = true)))
            d = divergence_report(M.caller, tt; guarantees = (:noalloc,))
            sweep = nothing
            if !isnothing(expected_sweep(k))
                sf = StrictMode._findings_compiled(M; guarantees = (:noalloc,), only = [:mid])
                pf = StrictModeTest.proof_findings(M; guarantees = (:noalloc,), only = [:mid])
                wide(x) = occursin(" via invoke of ", x.signature)
                row(fs) = (r = filter(wide, fs); length(r) == 1 ? verdict(only(r)) : (:rows, length(r)))
                others = all(x -> wide(x) || x.status === :pass, vcat(sf, pf)) ? :pass : :fail
                # The coverage gate and a `types` exemption, each naming the specific method or the
                # wider one.
                A = (M.W, Int)
                StrictMode.register_strict!(M.mid, A; guarantees = (:noalloc,))
                undeclared = try
                    map(wide, filter(StrictMode._failed, StrictMode._coverage_all_findings(M; only = [:mid])))
                finally
                    delete!(StrictMode.STRICT_REGISTRY, (M.mid, A))
                end
                function exempted(types)
                    StrictMode._exempt!(:mid; types, guarantees = (:noalloc,))
                    try
                        return (;
                            scan = row(StrictMode._findings_compiled(M; guarantees = (:noalloc,), only = [:mid])),
                            proof = row(StrictModeTest.proof_findings(M; guarantees = (:noalloc,), only = [:mid])),
                        )
                    finally
                        filter!(e -> e.func !== :mid, StrictMode.STRICT_EXEMPT)
                    end
                end
                sweep = (;
                    scan = row(sf), proof = row(pf), others, undeclared,
                    narrow = exempted(A), wide = exempted((M.W, Integer)),
                    defnarrow = exempted(StrictMode._method_exempt_types(which(M.mid, A))),
                    defwide = exempted(StrictMode._method_exempt_types(which(M.mid, (M.W, Integer)))),
                )
            end
            return (; name = k.name, scan, proof, proof_ae, diverged = !isempty(d), cause = !isempty(d.cause_diverged), sweep)
        finally
            path = M.TW.io.name[7:(end - 1)]     # "<file PATH>"
            close(M.TW.io)
            rm(path; force = true)
        end
    end

    observed(k::Case, into::Module) =
        Base.invokelatest(observe, k, Base.include_string(into, source(k), k.name * ".jl")::Module)
    # Every case of one wrapper, as `(expected, observed)`. The barriers the cases register are
    # dropped again afterwards.
    function run(wrapper::Symbol, into::Module; from = cases)
        saved = copy(StrictMode._ALLOC_BARRIERS)
        try
            return [(expected(k), observed(k, into)) for k in from() if k.wrapper === wrapper]
        finally
            empty!(StrictMode._ALLOC_BARRIERS)
            union!(StrictMode._ALLOC_BARRIERS, saved)
            StrictMode.clear_cache!()
        end
    end
end

@testitem "noalloc corpus: no wrapper" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:none, @__MODULE__)
        @test o == e
    end
end

@testitem "noalloc corpus: exempt function" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:exempt, @__MODULE__)
        @test o == e
    end
end

@testitem "noalloc corpus: registered barrier" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:barrier, @__MODULE__)
        @test o == e
    end
end

@testitem "noalloc corpus: OncePerProcess guard" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:oncep, @__MODULE__)
        @test o == e
    end
end

@testitem "noalloc corpus: OncePerThread guard" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:oncet, @__MODULE__)
        @test o == e
    end
end

@testitem "noalloc corpus: exemption and barrier nested" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:nested, @__MODULE__)
        @test o == e
    end
end

@testitem "noalloc corpus: callee shapes, no wrapper" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:none, @__MODULE__; from = NoallocCorpus.shape_cases)
        @test o == e
    end
end

@testitem "noalloc corpus: callee shapes, exempt function" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:exempt, @__MODULE__; from = NoallocCorpus.shape_cases)
        @test o == e
    end
end

@testitem "noalloc corpus: callee shapes, registered barrier" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:barrier, @__MODULE__; from = NoallocCorpus.shape_cases)
        @test o == e
    end
end

@testitem "noalloc corpus: callee shapes, OncePerProcess guard" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:oncep, @__MODULE__; from = NoallocCorpus.shape_cases)
        @test o == e
    end
end

@testitem "noalloc corpus: callee shapes, OncePerThread guard" setup = [NoallocCorpus] begin
    for (e, o) in NoallocCorpus.run(:oncet, @__MODULE__; from = NoallocCorpus.shape_cases)
        @test o == e
    end
end
