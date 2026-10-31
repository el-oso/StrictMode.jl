@testitem "_sanitize_asm_for_mca drops the semicolon Function-Signature comment and non-ASCII lines" begin
    using StrictMode
    asm = """
    \t.text
    julia_f_1:                         # @julia_f_1
    ; Function Signature: f(Int64)
    # %bb.0:                                # %top
    \tmovq\t%rdi, %rax
    \tretq
    """
    clean = StrictMode._sanitize_asm_for_mca(asm)
    @test !occursin("Function Signature", clean)
    @test occursin("movq", clean)
    @test occursin("# %bb.0", clean)   # ordinary `#` GAS comments are untouched

    with_unicode = "movq %rax, %rbx  # arrow → here\n" * asm
    clean2 = StrictMode._sanitize_asm_for_mca(with_unicode)
    @test !occursin("arrow", clean2)
end

@testitem "_innermost_loop_span prefers the vectorized loop over a smaller scalar tail loop" begin
    using StrictMode
    # Mirrors the real dotk shape: a 3-line scalar tail loop (.LBB0_8) is SMALLER by line count
    # than the 5-line vectorized loop (.LBB0_6) — the vector-register preference must win.
    asm = """
    \tpushq\t%rbp
    .LBB0_6:                                # %vector.body
    \tvmovupd\t(%rax), %zmm0
    \tvfmadd231pd\t(%rcx), %zmm0, %zmm1
    \taddq\t\$8, %rax
    \tjne\t.LBB0_6
    .LBB0_8:                                # %scalar.tail
    \taddsd\t(%rdx), %xmm0
    \tjne\t.LBB0_8
    \tretq
    """
    span = StrictMode._innermost_loop_span(asm)
    @test span !== nothing
    lines = split(asm, '\n')
    @test occursin("LBB0_6", lines[span[1]])   # picked the vectorized loop, not the smaller tail
end

@testitem "_innermost_loop_span falls back to the smallest span when nothing is vectorized" begin
    using StrictMode
    asm = """
    .LBB0_1:                                # %outer
    \tcallq\tfoo
    .LBB0_2:                                # %inner
    \taddq\t\$1, %rax
    \tjne\t.LBB0_2
    \tjne\t.LBB0_1
    """
    span = StrictMode._innermost_loop_span(asm)
    @test span !== nothing
    lines = split(asm, '\n')
    @test occursin("LBB0_2", lines[span[1]])   # the smaller (inner) span, no vector ops anywhere
end

@testitem "_innermost_loop_span returns nothing when there is no backward jump" begin
    using StrictMode
    asm = "\tmovq %rax, %rbx\n\tretq\n"
    @test StrictMode._innermost_loop_span(asm) === nothing
end

@testitem "_wrap_mca_region inserts BEGIN/END around the exact span" begin
    using StrictMode
    asm = "a\nb\n.LBB0_1:\nc\njne .LBB0_1\nd"   # no trailing newline — split(...,'\n') would else add an extra "" element
    lines = split(asm, '\n')
    span = (3, 5)   # ".LBB0_1:" through "jne .LBB0_1"
    wrapped = StrictMode._wrap_mca_region(asm, span)
    wlines = split(wrapped, '\n')
    @test wlines[3] == "# LLVM-MCA-BEGIN hot"
    @test wlines[4] == lines[3]
    @test wlines[7] == "# LLVM-MCA-END"
    @test wlines[end] == "d"
end

@testitem "_parse_mca_output extracts every field from a canned real llvm-mca summary" begin
    using StrictMode
    canned = """
    [0] Code Region - hot

    Iterations:        100
    Instructions:      1100
    Total Cycles:      414
    Total uOps:        1100

    Dispatch Width:    6
    uOps Per Cycle:    2.66
    IPC:               2.66
    Block RThroughput: 4.0
    """
    r = StrictMode._parse_mca_output(canned)
    @test r.iterations == 100
    @test r.instructions == 1100
    @test r.total_cycles == 414
    @test r.total_uops == 1100
    @test r.dispatch_width == 6
    @test r.uops_per_cycle == 2.66
    @test r.ipc == 2.66
    @test r.block_rthroughput == 4.0
end

@testitem "_parse_mca_output degrades gracefully on an unrecognized/empty format" begin
    using StrictMode
    r = StrictMode._parse_mca_output("some format llvm-mca doesn't emit anymore")
    @test r.iterations == 0
    @test r.instructions == 0
    @test isnan(r.ipc)
    @test isnan(r.block_rthroughput)
end

@testitem "_mca_bound_problems fails loudly (not silently) on an unparseable NaN metric" begin
    using StrictMode
    nan_report = StrictMode.McaReport(;
        target = "f(Int)", mcpu = "generic", mcpu_fellback = false, whole_function = false
    )
    @test isnan(nan_report.ipc) && isnan(nan_report.block_rthroughput)   # McaReport's own NaN default

    # An explicit bound against an unparseable metric must be reported as a problem, not silently
    # pass just because `NaN > x`/`NaN < x` are both `false`.
    probs1 = StrictMode._mca_bound_problems(nan_report, 10.0, nothing)
    @test length(probs1) == 1 && occursin("could not be parsed", probs1[1])

    probs2 = StrictMode._mca_bound_problems(nan_report, nothing, 2.0)
    @test length(probs2) == 1 && occursin("could not be parsed", probs2[1])

    # No bounds supplied at all: NaN metrics are fine (informational-only path).
    @test isempty(StrictMode._mca_bound_problems(nan_report, nothing, nothing))

    # A real, parseable report: bounds are enforced normally.
    ok_report = StrictMode.McaReport(;
        target = "f(Int)", mcpu = "generic", mcpu_fellback = false, whole_function = false,
        ipc = 3.0, block_rthroughput = 1.5
    )
    @test isempty(StrictMode._mca_bound_problems(ok_report, 2.0, 1.0))     # within both bounds
    @test !isempty(StrictMode._mca_bound_problems(ok_report, 1.0, nothing))  # exceeds max_rthroughput
    @test !isempty(StrictMode._mca_bound_problems(ok_report, nothing, 5.0)) # below min_ipc
end

@testitem "mca_report either runs or says the weak dependency is missing" begin
    using StrictMode
    f(x::Int) = x + 1
    # Both branches assert, because the two outcomes are the whole contract: without the extension
    # `mca_report` must refuse with a message naming it, and with the extension it must run. Which
    # branch applies is a property of the environment, so neither configuration goes unchecked.
    if StrictMode.mca_available()
        @test mca_report(f, (Int,)) isa McaReport
    else
        @test_throws ErrorException mca_report(f, (Int,))
        @test_throws "LLVM_full_jll" mca_report(f, (Int,))
    end
end

# The live `llvm-mca` assertions are NOT a test item here. `LLVM_full_jll` is a dependency of no
# environment in this repo, so an item holding them could only ever skip in this suite — and a skip
# counts as green. They live in `mca_live.jl` and run from `mca_live_runner.jl`, in the one
# environment that installs the weak dependency, which CI builds for exactly that purpose.
