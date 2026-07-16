@testitem "OncePerProcess-memoized calibrator passes :full @assert_noalloc (issue #14 acceptance)" begin
    using StrictMode, AllocCheck, JET
    # The `ger!` DRAM-path repro shape: a per-process calibration measured once via
    # Base.OncePerProcess, alloc-free on every steady-state call thereafter.
    _measure_np() = length(rand(4))
    const _NP_ONCE = Base.OncePerProcess{Int}(_measure_np)
    @inline _ger_np() = _NP_ONCE()
    steady(x::Int) = x + _ger_np()

    sig = StrictMode._alloc_signals(steady, (Int,))
    @test sig.barrier
    @test !sig.alloc
    @test !sig.boxing

    val = @assert_noalloc steady(1)
    @test val == 5
end

@testitem "set_ignore_barrier!(false) reverts to strict AllocCheck (barrier no longer exempted)" begin
    using StrictMode, AllocCheck, JET
    _measure_np2() = length(rand(4))
    const _NP_ONCE2 = Base.OncePerProcess{Int}(_measure_np2)
    steady2(x::Int) = x + _NP_ONCE2()

    old = StrictMode.ignore_barrier()
    StrictMode.set_ignore_barrier!(false)
    try
        @test_throws StrictViolation (@assert_noalloc steady2(1))
    finally
        StrictMode.set_ignore_barrier!(old)
    end
    # restored: exemption active again
    @test (@assert_noalloc steady2(2)) == 6
end

@testitem "register_alloc_barrier! exempts a hand-rolled memoization pattern" begin
    using StrictMode, AllocCheck, JET
    const _HANDROLLED = Ref{Union{Nothing, Int}}(nothing)
    @noinline function _handrolled_calibrator()
        v = _HANDROLLED[]
        v === nothing || return v
        v2 = length(rand(4))
        _HANDROLLED[] = v2
        return v2
    end
    hr(x::Int) = x + _handrolled_calibrator()

    # Not registered yet — reds like any other allocating steady state.
    @test_throws StrictViolation (@assert_noalloc hr(1))

    memoized = _handrolled_calibrator()   # warm it up so the expected value is known
    StrictMode.register_alloc_barrier!(_handrolled_calibrator)
    try
        @test (@assert_noalloc hr(1)) == 1 + memoized
    finally
        empty!(StrictMode._ALLOC_BARRIERS)
        StrictMode.clear_cache!()
    end
end

@testitem "a genuinely-allocating steady state (no barrier involved) still fails unconditionally" begin
    using StrictMode, AllocCheck, JET
    really_allocates(x::Int) = x + length(rand(4))
    @test_throws StrictViolation (@assert_noalloc really_allocates(1))

    sig = StrictMode._alloc_signals(really_allocates, (Int,))
    @test !sig.barrier
    @test sig.alloc
end

@testitem "a user function merely TAKING a once-guard as an argument is not itself a barrier" begin
    using StrictMode, AllocCheck, JET
    # `_mi_is_barrier` matches OncePerProcess/OncePerThread at parameter 2 because that's where
    # Base's OWN cold-path init closure carries it (init_perprocesss(closure, once, state)) — but
    # a USER function with that exact parameter shape (a once-guard as its own 2nd argument) is
    # NOT that closure, and must not be silently treated as one: this function genuinely allocates
    # on every call, real bug this test pins down (a prior version wrongly reported it clean via
    # `mi.def.module` not being checked).
    const _NPBP_ONCE = Base.OncePerProcess{Int}(() -> 1)
    @noinline helper(o::Base.OncePerProcess{Int}, n::Int) = o() + length(Vector{Float64}(undef, n))
    caller(n::Int) = helper(_NPBP_ONCE, n)

    sig = StrictMode._alloc_signals(caller, (Int,))
    @test sig.barrier         # the OncePerProcess call inside `caller` is still correctly recognized
    @test sig.alloc           # but `helper`'s OWN allocation must NOT be hidden by that recognition

    @test_throws StrictViolation (@assert_noalloc caller(4))
end

@testitem "a barrier call that ALSO reads an abstract-eltype container is not exempted (:full must not be laxer than :fast)" begin
    using StrictMode, AllocCheck, JET
    # Without also checking `abscontainer`, the exemption gate would pass :full while :fast's own
    # `_findings_fast` correctly fails via `sig.abscontainer !== nothing` (check.jl) — a barrier
    # call with an UNRELATED abstract-container risk must still be caught by :full.
    _measure_ac() = length(rand(4))
    const _AC_ONCE = Base.OncePerProcess{Int}(_measure_ac)
    struct AbsContainerHolder
        v::Vector{Real}
    end
    lenplus(h::AbsContainerHolder) = length(h.v) + _AC_ONCE()

    sig = StrictMode._alloc_signals(lenplus, (AbsContainerHolder,))
    @test sig.barrier
    @test !sig.alloc
    @test !sig.boxing
    @test sig.abscontainer !== nothing

    @test_throws StrictViolation (@assert_noalloc lenplus(AbsContainerHolder(Real[1, 2])))
end

@testitem "OncePerThread is also recognized end-to-end (not just the bare type predicate)" begin
    using StrictMode, AllocCheck, JET
    # Exercise the REAL detection path (_alloc_signals -> _mi_is_barrier), not just
    # _is_base_barrier_type in isolation — a bare type-predicate pass doesn't prove the :invoke
    # scan actually recognizes it (this gap is exactly what let OncePerTask ship un-detected
    # despite `_is_base_barrier_type` trivially returning true for it).
    _measure_pt() = length(rand(4))
    const _PT_ONCE = Base.OncePerThread{Int}(_measure_pt)
    pt_steady(x::Int) = x + _PT_ONCE()

    sig = StrictMode._alloc_signals(pt_steady, (Int,))
    @test sig.barrier
    @test !sig.alloc
    @test !sig.boxing
    @test (@assert_noalloc pt_steady(1)) == 1 + _PT_ONCE()
end

@testitem "OncePerTask is NOT auto-recognized (different Base implementation, no detectable :invoke)" begin
    using StrictMode, AllocCheck, JET
    # OncePerTask is implemented via the current task's `.storage` IdDict (jl_eqtable_get/put),
    # fully inlined into the caller — there is no non-inlined callee boundary for the :invoke-based
    # mechanism to detect, unlike OncePerProcess/OncePerThread's cold-path init closure. Pin this
    # down explicitly so a future "let's add OncePerTask to _BASE_BARRIER_TYPES" doesn't silently
    # ship a barrier that's never actually detected (that's exactly how it shipped wrong the first
    # time — the only prior test checked the bare `_is_base_barrier_type` predicate, not real
    # detection through `_alloc_signals`).
    _measure_ptk() = length(rand(4))
    const _PTK_ONCE = Base.OncePerTask{Int}(_measure_ptk)
    ptk_steady(x::Int) = x + _PTK_ONCE()

    @test !StrictMode._is_base_barrier_type(Base.OncePerTask{Int, typeof(_measure_ptk)})
    sig = StrictMode._alloc_signals(ptk_steady, (Int,))
    @test !sig.barrier
    # Documents the workaround: wrap it in a registered function instead.
    @noinline _ptk_wrapper() = _PTK_ONCE()
    ptk_wrapped(x::Int) = x + _ptk_wrapper()
    StrictMode.register_alloc_barrier!(_ptk_wrapper)
    try
        @test (@assert_noalloc ptk_wrapped(1)) == 1 + _PTK_ONCE()
    finally
        empty!(StrictMode._ALLOC_BARRIERS)
        StrictMode.clear_cache!()
    end
end

@testitem "OncePerProcess/OncePerThread type predicate; Int is not a barrier type" begin
    using StrictMode
    @test StrictMode._is_base_barrier_type(Base.OncePerProcess{Int, typeof(identity)})
    @test StrictMode._is_base_barrier_type(Base.OncePerThread{Int, typeof(identity)})
    @test !StrictMode._is_base_barrier_type(Int)
end

@testitem "the founding runtime-tuple-index boxing trap still flags (getfield exemption is index-const-only)" begin
    using StrictMode
    # t[i] with a RUNTIME i on a heterogeneous Tuple lowers to Core.getfield(t, i, ...) with a
    # non-constant field argument — must NOT be caught by the getfield-is-always-safe exemption
    # added for OncePerProcess's named-field reads (a compile-time-constant field argument).
    boxy(t::Tuple{Int, Float64, Float32}) = (
        s = 0.0; for i in 1:3
            s += t[i]
        end; s
    )
    sig = StrictMode._alloc_signals(boxy, (Tuple{Int, Float64, Float32},))
    @test sig.boxing
end

@testitem "the barrier exemption is consistent across every :full noalloc entry point" begin
    using StrictMode, AllocCheck, JET
    # _checked_allocs was originally wired into @assert_noalloc/@assert_noboxing/findings/check
    # only — @strict_function (a SEPARATE :full noalloc entry point, at module-load time) and
    # divergence_report's diagnostic signal labels (a separate, auxiliary raw-AllocCheck call,
    # NOT the .diverged comparison itself — that already went through `findings`/`_checked_allocs`)
    # both still called `_be_check_allocs` directly, so a barrier-exempted function could pass
    # @assert_noalloc/check while still reding at @strict_function load time, or showing a phantom
    # "full:alloc-sites=N" label in a divergence_report that no longer actually diverges.
    _measure_cc() = length(rand(4))
    const _CC_ONCE = Base.OncePerProcess{Int}(_measure_cc)
    steady_cc(x::Int) = x + _CC_ONCE()

    @strict_function steady_cc2(x::Int) = x + _CC_ONCE()   # would previously red at load time
    @test steady_cc2(1) == 1 + _CC_ONCE()

    d = divergence_report(steady_cc, (Int,); guarantees = (:noalloc,))
    @test isempty(d)
    @test !any(l -> startswith(l, "full:alloc-sites="), d.full_signals)
end
