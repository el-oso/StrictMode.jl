# Coverage gate: audit(mod; require = :public) fails for public functions with no registered
# guarantee, so "every kernel declares its guarantees" is a red test, not a convention.

@testitem "coverage gate flags unregistered public functions" begin
    using StrictMode

    module CovPkg
    export covered, uncovered, coldpub
    covered(x::Float64) = x + 1.0
    uncovered(x::Float64) = x * 2.0
    coldpub(x::Float64) = [x]          # cold by design — exempted below
    _private(x::Float64) = x - 1.0     # not public: never flagged
    end

    StrictMode.clear_declarations!()
    StrictMode.register_strict!(CovPkg.covered, (Float64,); guarantees = (:typestable,))

    # uncovered + coldpub flagged; covered (registered) and _private (not public) are not.
    fs = audit(CovPkg; require = :public)
    @test nfailures(fs) == 2
    @test Set(f.func for f in fs if f.guarantee === :coverage) == Set(["uncovered", "coldpub"])
    @test all(f.status === :fail for f in fs if f.guarantee === :coverage)
    @test all(f.line > 0 for f in fs if f.guarantee === :coverage)

    # The exempt kwarg is a visible opt-out.
    fs = audit(CovPkg; require = :public, exempt = (:coldpub,))
    @test nfailures(fs) == 1
    @test only(f for f in fs if f.guarantee === :coverage).func == "uncovered"

    # @strict_exempt is honored too.
    StrictMode._exempt!(:coldpub)
    fs = audit(CovPkg; require = :public)
    @test [f.func for f in fs if f.guarantee === :coverage] == ["uncovered"]

    # JSON output carries the gate for agents.
    s = format_findings(audit(CovPkg; require = :public); format = :json)
    @test occursin("\"coverage\"", s) && occursin("register_strict!", s)

    StrictMode.clear_declarations!()
end

@testitem "coverage gate: clean module passes; bad kwargs throw" begin
    using StrictMode

    module CovClean
    export k
    k(x::Int) = x + 1
    end

    StrictMode.clear_declarations!()
    StrictMode.register_strict!(CovClean.k, (Int,); guarantees = (:typestable,))
    @test nfailures(audit(CovClean; require = :public)) == 0

    @test_throws ArgumentError audit(CovClean; require = :exported)
    @test_throws ArgumentError audit(:registered; require = :public)
    StrictMode.clear_declarations!()
end

@testitem "the census sees methods a binding walk cannot: foreign functions" begin
    using StrictMode

    module CensusPkg
    struct Holder
        v::Vector{Float64}
    end
    Base.size(h::Holder) = size(h.v)          # a method on a FOREIGN function, owned here
    Base.getindex(h::Holder, i::Int) = h.v[i] # …and another: often the hottest code there is
    own(x::Float64) = x + 1.0
    end

    ms, skipped = StrictMode.module_methods(CensusPkg)
    names_found = Set(String(StrictMode._demangle(m.name)) for m in ms)
    @test "own" in names_found
    @test "size" in names_found               # the point of the census
    @test "getindex" in names_found

    # A walk over the module's own bindings cannot see them: the names live in Base.
    bound = Set{String}()
    for nm in names(CensusPkg; all = true)
        isdefined(CensusPkg, nm) || continue
        v = getfield(CensusPkg, nm)
        v isa Function && parentmodule(v) === CensusPkg || continue
        push!(bound, String(nameof(v)))
    end
    @test "own" in bound
    @test !("size" in bound) && !("getindex" in bound)

    # The struct's constructors are left out, and that is reported rather than silent.
    @test get(skipped, :constructor, 0) >= 1
end

@testitem "require = :all is default-deny over methods, and exempt is the visible way out" begin
    using StrictMode

    module DenyPkg
    struct Thing end
    Base.length(::Thing) = 1
    hot(x::Int) = x + 1
    cold(n::Int) = collect(1:n)
    end

    StrictMode.clear_declarations!()

    # Nothing declared: every method is reported, including the one on `Base.length`.
    fs = audit(DenyPkg; require = :all)
    failed = filter(f -> f.guarantee === :coverage && StrictMode._failed(f), fs)
    @test Set(f.func for f in failed) == Set(["length", "hot", "cold"])
    @test all(f.line > 0 for f in failed)          # the method's own location, not its function's
    # The exclusion tally is visible as an :info finding, never a silent drop.
    @test any(f -> f.guarantee === :coverage && f.status === :info, fs)

    # Declaring one removes exactly one.
    StrictMode.register_strict!(DenyPkg.hot, (Int,); guarantees = (:typestable,))
    fs = audit(DenyPkg; require = :all)
    @test Set(f.func for f in fs if f.guarantee === :coverage && StrictMode._failed(f)) ==
        Set(["length", "cold"])

    # Exempting is the other way out, and it is visible in the source.
    StrictMode._exempt!(:cold)
    fs = audit(DenyPkg; require = :all)
    @test Set(f.func for f in fs if f.guarantee === :coverage && StrictMode._failed(f)) ==
        Set(["length"])

    StrictMode.clear_declarations!()
end

@testitem "coverage is per compiled signature, not per method" begin
    using StrictMode

    module SigPkg
    gen(x::T) where {T <: Real} = x * 2      # one method, one signature per argument type
    end

    StrictMode.clear_declarations!()

    SigPkg.gen(1.0)                           # two concrete signatures now exist
    SigPkg.gen(Int32(2))

    # Declaring ONE instantiation leaves the other reported: it was never checked, and a method
    # counted as covered on the strength of a sibling signature would hide exactly that.
    StrictMode.register_strict!(SigPkg.gen, (Float64,); guarantees = (:typestable,))
    fs = audit(SigPkg; require = :all)
    failed = filter(f -> f.guarantee === :coverage && StrictMode._failed(f), fs)
    sigs = Set(f.signature for f in failed if f.func == "gen")
    @test "(Int32)" in sigs
    @test !("(Float64)" in sigs)

    # Declaring the second one clears it.
    StrictMode.register_strict!(SigPkg.gen, (Int32,); guarantees = (:typestable,))
    fs = audit(SigPkg; require = :all)
    @test isempty(filter(f -> f.guarantee === :coverage && StrictMode._failed(f), fs))

    StrictMode.clear_declarations!()
end

@testitem "the census covers a package's loaded extensions" begin
    using StrictMode, Revise          # loading Revise activates StrictModeReviseExt

    ext = Base.get_extension(StrictMode, :StrictModeReviseExt)
    @test !isnothing(ext)

    # An extension is a ROOT module: `parentmodule` on it returns itself, so walking up from a
    # method defined there never reaches the package. Its methods are the package's code all the
    # same, and a gate that skipped them would be narrower than it claims without saying so.
    @test parentmodule(ext) === ext
    @test StrictMode._scope_modules(StrictMode) ⊇ [StrictMode, ext]

    ms, _ = StrictMode.module_methods(StrictMode)
    @test count(m -> m.module === ext, ms) > 0
end
