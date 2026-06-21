@testitem "@strict_exempt records cold functions (def + name forms)" begin
    using StrictMode
    empty!(StrictMode.exempt_strict())

    @strict_exempt xcold(n::Int) = collect(1:n)          # definition form
    @test :xcold in StrictMode.exempt_strict()
    @test xcold(3) == [1, 2, 3]

    @strict_exempt :xbyname                              # name form
    @test :xbyname in StrictMode.exempt_strict()
end

@testitem "exempt functions are skipped by check_all" begin
    using StrictMode
    empty!(StrictMode.exempt_strict())
    empty!(StrictMode.registered_strict())

    # a hot, boxing function: reported by default
    xboxy(t::Tuple{Int, Float64, Float32}) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    StrictMode.register_strict!(xboxy, (Tuple{Int, Float64, Float32},))
    @test nfailures(check_all(; fail = :none)) ≥ 1

    StrictMode._exempt!(:xboxy)                          # opt it out
    @test nfailures(check_all(; fail = :none)) == 0

    empty!(StrictMode.exempt_strict())                  # don't leak into other test items
    empty!(StrictMode.registered_strict())
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
