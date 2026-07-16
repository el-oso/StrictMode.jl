# F41/issue #15: `@assert_memsafe` — a guard-page (electric-fence style) harness for catching
# out-of-bounds array access in unsafe SIMD kernels deterministically instead of flakily.
#
# Motivation: a masked SIMD microkernel can OOB-read past a partial-row tile (a masked vector load
# reads a full lane width at the tile pointer, up to W-1 elements past the valid region). That kind
# of bug is allocation-layout-dependent — it only faults when the next page happens to be unmapped —
# so it can pass `@assert_typestable`/`@assert_noalloc`/`@assert_trim_safe` and a green dogfood using
# ordinary heap arrays (whose trailing page happens to be mapped) forever, then crash once in a long
# benchmark run. This harness re-allocates array arguments into `mmap`-backed buffers placed flush
# against a trailing `PROT_NONE` guard page, so any read/write one element past the intended bounds
# faults on every run, and reports it as a StrictMode violation instead of a process kill.
#
# Two research findings this design is built on (verified empirically, not assumed):
#   1. An OOB WRITE against the guard page is catchable IN-PROCESS: Julia's segv handler converts a
#      write fault on a mapped-but-protected page into a `ReadOnlyMemoryError`; the process survives.
#   2. An OOB READ is NOT catchable in-process: it is a fatal SIGSEGV (the process dies), but a
#      *subprocess* that faults is detected deterministically by its parent via `proc.termsignal`,
#      with the child's own signal report (naming the faulting op) on stderr. This is the only path
#      that catches the motivating bug's class (a masked *load*), so `isolate=true` (subprocess) is
#      the default; `isolate=false` (in-process) is the cheaper store-only fallback.
# A prior design considered shipping the probe to a `Distributed` worker instead of a plain
# subprocess. Dropped: the guard buffers can't cross a worker boundary anyway (they must be built
# *inside* the child regardless of transport), so `Distributed` bought nothing here over `run` +
# `Serialization` while adding a hard main-`[deps]` dependency this package otherwise keeps ext-only.

using Serialization: serialize, deserialize

# --- guard-page buffer construction -------------------------------------------------------------

function _pagesize()
    return Int(ccall(:getpagesize, Cint, ()))
end

const _PROT_READ = Cint(0x01)
const _PROT_WRITE = Cint(0x02)
const _PROT_NONE = Cint(0x00)
const _MAP_PRIVATE = Cint(0x02)
# MAP_ANONYMOUS: 0x20 on Linux, 0x1000 on Darwin — the only mmap flag that differs between the two
# platforms this harness targets.
const _MAP_ANON = Cint(Sys.isapple() ? 0x1000 : 0x20)

function _mmap_anon(nbytes::Int)
    ptr = ccall(
        :mmap, Ptr{Cvoid}, (Ptr{Cvoid}, Csize_t, Cint, Cint, Cint, Int),
        C_NULL, nbytes, _PROT_READ | _PROT_WRITE, _MAP_PRIVATE | _MAP_ANON, -1, 0
    )
    ptr == Ptr{Cvoid}(-1) && error("StrictMode @assert_memsafe: mmap($nbytes bytes) failed (errno $(Base.Libc.errno()))")
    return ptr
end

function _mprotect_none!(ptr::Ptr{Cvoid}, nbytes::Int)
    r = ccall(:mprotect, Cint, (Ptr{Cvoid}, Csize_t, Cint), ptr, nbytes, _PROT_NONE)
    r == 0 || error("StrictMode @assert_memsafe: mprotect failed (errno $(Base.Libc.errno()))")
    return nothing
end

_munmap!(ptr::Ptr{Cvoid}, nbytes::Int) = (ccall(:munmap, Cint, (Ptr{Cvoid}, Csize_t), ptr, nbytes); nothing)

struct GuardedBuffer
    array::Array
    _base::Ptr{Cvoid}
    _total_bytes::Int
end

_free_guarded!(gb::GuardedBuffer) = _munmap!(gb._base, gb._total_bytes)

"""
    _guarded_array(src::Array; align = sizeof(eltype(src))) -> GuardedBuffer

Copy `src` into a fresh `mmap`-backed buffer whose data ends **flush** against a trailing
`PROT_NONE` guard page: any read or write one element past `src`'s last valid byte faults
deterministically. The default `align = sizeof(eltype(src))` always evenly divides the data's
total byte length, so the default placement is simultaneously flush *and* naturally aligned — no
tradeoff. Requesting a wider `align` (e.g. for a kernel that assumes SIMD-width alignment) trades
away up to `align - 1` bytes of end-of-buffer detection precision to get it (warned once).

Only catches overruns past the **end of the allocation** — an interior overread (e.g. a masked
load reading past a valid sub-row but still inside the same buffer) is invisible to this harness.
There is no leading guard page in this version, so underruns are not caught either.
"""
function _guarded_array(src::Array{T, N}; align::Int = sizeof(T)) where {T, N}
    align > 0 || throw(ArgumentError("align must be positive, got $align"))
    n = length(src)
    databytes = n * sizeof(T)
    ps = _pagesize()
    slack = databytes == 0 ? 0 : (align - databytes % align) % align
    if slack > 0
        @warn "StrictMode @assert_memsafe: align=$align does not evenly divide this buffer's " *
            "$databytes-byte length — $slack byte(s) of end-of-buffer detection precision traded " *
            "away for alignment. Use align=sizeof(eltype(src)) (the default) for exact flush." maxlog = 3
    end
    padded_bytes = databytes + slack
    data_pages = cld(max(padded_bytes, 1), ps)
    data_region_bytes = data_pages * ps
    total_bytes = data_region_bytes + ps
    base = _mmap_anon(total_bytes)
    guard_ptr = base + data_region_bytes
    try
        _mprotect_none!(guard_ptr, ps)
    catch
        _munmap!(base, total_bytes)
        rethrow()
    end
    data_start = guard_ptr - padded_bytes   # flush against the guard once `slack` is accounted for
    arr = unsafe_wrap(Array, Ptr{T}(data_start), size(src); own = false)
    copyto!(arr, src)
    return GuardedBuffer(arr, base, total_bytes)
end

# --- isolate=false: in-process probe, catches OOB WRITES only -----------------------------------

function _memsafe_probe_inprocess(@nospecialize(f), args::Tuple; align::Union{Nothing, Int})
    guarded = Any[]
    handles = GuardedBuffer[]
    for a in args
        if a isa Array
            gb = _guarded_array(a; align = something(align, sizeof(eltype(a))))
            push!(guarded, gb.array)
            push!(handles, gb)
        else
            push!(guarded, a)
        end
    end
    try
        f(guarded...)
        return nothing
    catch e
        e isa ReadOnlyMemoryError && return "out-of-bounds WRITE detected (guard page triggered " *
            "ReadOnlyMemoryError). isolate=false only catches stores, not loads — use the default " *
            "isolate=true to also catch out-of-bounds reads."
        rethrow()
    finally
        foreach(_free_guarded!, handles)
    end
end

# --- isolate=true: subprocess probe, catches OOB READS and WRITES -------------------------------
#
# The guard buffers can't cross a process boundary (a raw mmap pointer is meaningless in another
# address space), so they're built INSIDE the child from the plain deserialized argument values —
# the same `_guarded_array` used by the in-process path. `f` must be a NAMED function reachable in
# a fresh process: by default this harness locates its defining source file via `which` and
# `include`s it directly (works for a self-contained kernel file with no unusual package deps —
# the common case for a focused microkernel); pass `using_module = MyPackage` to instead have the
# child `using MyPackage` and look the function up there (needed when the kernel's file relies on
# imports/context only its enclosing package provides).

function _indent(s::AbstractString)
    isempty(s) && return "  (no output)"
    return join(("  " * l for l in split(s, '\n')), '\n')
end

function _memsafe_child_script(kernel_file::AbstractString, fname::Symbol, args_path::AbstractString, using_module::Union{Nothing, Symbol}, align::Union{Nothing, Int})
    mod_stmt = using_module === nothing ? "include($(repr(kernel_file)))" : "using $(using_module)"
    lookup_mod = using_module === nothing ? "Main" : string(using_module)
    align_kw = align === nothing ? "" : "; align=$align"   # an Int repr is safe to splice verbatim
    # Plain (global) top-level bindings, not `local` — a top-level `local` in a multi-statement
    # script only scopes to its own statement, so it doesn't survive to the next line. Harmless
    # here: this is a throwaway one-shot process that exits right after.
    #
    # An out-of-bounds WRITE against the guard page is catchable even in this (child) process, as a
    # `ReadOnlyMemoryError` — it must be caught HERE and reported via a distinct stdout sentinel,
    # not left to propagate: an uncaught exception exits nonzero with no signal, which the parent
    # would otherwise (wrongly) treat as an unrelated script error rather than a memsafe violation.
    # Any OTHER exception is a genuine bug in `f` unrelated to memory safety and must still propagate.
    return """
    using StrictMode, Serialization
    $mod_stmt
    __args = deserialize($(repr(args_path)))
    __f = getfield($lookup_mod, $(repr(fname)))
    __guarded = map(__a -> __a isa Array ? StrictMode._guarded_array(__a$(align_kw)).array : __a, __args)
    try
        __f(__guarded...)
        print(stdout, "STRICTMODE_MEMSAFE_OK")
    catch __e
        __e isa ReadOnlyMemoryError || rethrow()
        print(stdout, "STRICTMODE_MEMSAFE_WRITE_VIOLATION")
    end
    """
end

function _memsafe_probe_subprocess(@nospecialize(f), args::Tuple; using_module::Union{Nothing, Symbol}, align::Union{Nothing, Int} = nothing)
    fname = nameof(f)
    if using_module === nothing
        # A function is reachable in a fresh child regardless of which module it ended up in
        # (`include`-ing a plain script file at top level defines into `Main`, same as the REPL) —
        # what actually matters is whether `which` can point at a real file on disk to `include`.
        # A closure, an anonymous function, or something `eval`'d from a string has no such file.
        argtypes = map(typeof, args)
        m = try
            which(f, Tuple{argtypes...})
        catch err
            error("StrictMode @assert_memsafe: could not resolve a method of `$fname` for argument types $argtypes to locate its source file: $(sprint(showerror, err))")
        end
        kernel_file = isabspath(String(m.file)) ? String(m.file) : Base.find_source_file(String(m.file))
        (kernel_file === nothing || !isfile(kernel_file)) && error(
            "StrictMode @assert_memsafe: `$fname`'s source file ($(m.file)) could not be found on " *
                "disk (a closure, an anonymous function, or a REPL/`eval`'d-from-string definition?) " *
                "— isolate=true needs a named function reachable in a fresh process. Pass " *
                "`isolate=false` (in-process, catches out-of-bounds stores only), or move the " *
                "definition to a file and pass `using_module = TheDefiningPackage`."
        )
    else
        kernel_file = ""   # unused when using_module is given
    end

    args_path, args_io = mktemp()
    close(args_io)
    script = _memsafe_child_script(kernel_file, fname, args_path, using_module, align)
    try
        serialize(args_path, args)
        cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -e $script`
        outbuf, errbuf = IOBuffer(), IOBuffer()
        proc = run(pipeline(cmd; stdout = outbuf, stderr = errbuf); wait = false)
        wait(proc)
        out_s, err_s = String(take!(outbuf)), String(take!(errbuf))
        if proc.termsignal != 0
            signame = proc.termsignal == 11 ? "SIGSEGV" : proc.termsignal == 7 ? "SIGBUS" : "signal $(proc.termsignal)"
            return "deterministic out-of-bounds access — the guarded probe subprocess was killed by " *
                "$signame. Child's own signal report (names the faulting op):\n" * _indent(err_s)
        elseif occursin("STRICTMODE_MEMSAFE_WRITE_VIOLATION", out_s)
            # A WRITE fault is catchable even in the child (ReadOnlyMemoryError) — it exits 0 with
            # this sentinel rather than a signal, so it must be checked before the exitcode branch.
            return "out-of-bounds WRITE detected (guard page triggered ReadOnlyMemoryError in the " *
                "guarded subprocess)."
        elseif proc.exitcode != 0
            error(
                "StrictMode @assert_memsafe: the guarded probe errored for a reason other than a " *
                    "memory fault (exit code $(proc.exitcode)) — this is not itself a memsafe " *
                    "violation, fix the underlying error:\n" * _indent(err_s)
            )
        elseif !occursin("STRICTMODE_MEMSAFE_OK", out_s)
            error("StrictMode @assert_memsafe: internal error — the probe subprocess exited cleanly but did not report success.\nstdout:\n" * _indent(out_s) * "\nstderr:\n" * _indent(err_s))
        end
        return nothing
    finally
        rm(args_path; force = true)
    end
end

# --- public API -----------------------------------------------------------------------------------

"""
    MemsafeReport

The result of [`memsafe_report`](@ref): `target` (the checked signature, as a string), `isolate`
(whether the probe ran in a subprocess), and `violation` (`nothing` if clean, else a description
of the out-of-bounds access detected — naming the faulting op when `isolate=true` caught it).
"""
struct MemsafeReport
    target::String
    isolate::Bool
    violation::Union{Nothing, String}
end

function Base.show(io::IO, r::MemsafeReport)
    printstyled(io, "MemsafeReport"; bold = true)
    print(io, ": ", r.target, " (isolate=", r.isolate, ")\n")
    if r.violation === nothing
        printstyled(io, "  clean"; color = :green)
        print(io, ": no out-of-bounds access detected.")
    else
        printstyled(io, "  VIOLATION"; color = :red, bold = true)
        print(io, ": ", r.violation)
    end
    return nothing
end

"""
    memsafe_report(f, args...; isolate = true, align = nothing, using_module = nothing) -> MemsafeReport

Run `f(args...)` once against guard-page-backed copies of every `Array` argument and report
whether an out-of-bounds access was detected. Non-execution guarantees elsewhere in StrictMode
(`check`/`findings`) are value-free by design; this one needs real argument values to build the
guarded buffers, so it stays a `@golden`-style value-based function/macro pair instead.

- `isolate = true` (default): the probe runs in a **subprocess**, so a fatal out-of-bounds READ
  (a SIGSEGV) is caught via the child's exit signal rather than crashing your session. This is the
  only mode that catches the motivating bug class (a masked SIMD load reading past a tile).
- `isolate = false`: the probe runs **in-process** — cheaper, but only catches out-of-bounds
  WRITES (caught as a `ReadOnlyMemoryError`); an out-of-bounds read is a fatal, uncatchable crash
  in this mode.
- `align`: alignment (bytes) for each guarded array's start pointer (internally, `_guarded_array`)
  — the default (the element's own size) is always exact-flush, no tradeoff.
- `using_module`: for `isolate=true` when `f`'s defining file isn't self-contained (relies on its
  package's `using`/context) — the subprocess does `using \$using_module` and looks `f` up there,
  instead of raw-`include`-ing the source file.

**Scope**: only `Array` arguments are guarded; every other argument passes through unguarded. Only
catches overruns past the *end* of an allocation (no leading guard, no interior-overread
detection). Linux/macOS only (needs `mmap`/`mprotect` + POSIX signal delivery); untested on macOS
in this package's own CI as of writing.

```julia
r = memsafe_report(masked_load_kernel!, C, A, B)
r.violation === nothing || error(r.violation)
```
"""
function memsafe_report(
        @nospecialize(f), args...;
        isolate::Bool = true, align::Union{Nothing, Int} = nothing, using_module::Union{Nothing, Symbol} = nothing
    )
    Sys.islinux() || Sys.isapple() || error(
        "StrictMode @assert_memsafe: only Linux/macOS are supported (needs mmap/mprotect + POSIX " *
            "signal delivery); got Sys.KERNEL = $(Sys.KERNEL)."
    )
    target = _func_name(f) * _sig_string(map(typeof, args))
    violation = isolate ? _memsafe_probe_subprocess(f, args; using_module, align) :
        _memsafe_probe_inprocess(f, args; align)
    return MemsafeReport(target, isolate, violation)
end

function _assert_memsafe(target, @nospecialize(f), args::Tuple; isolate::Bool, align, using_module)
    violation = isolate ? _memsafe_probe_subprocess(f, args; using_module, align) :
        _memsafe_probe_inprocess(f, args; align)
    violation === nothing || _fail(:memsafe, target, violation)
    return nothing
end

"""
    @assert_memsafe f(args...)
    @assert_memsafe isolate=false f(args...)
    @assert_memsafe using_module=MyPackage f(args...)
    @assert_memsafe align=64 f(args...)

Fail if `f(args...)` performs an **out-of-bounds array access** — a `PROT_NONE`-guard-page harness
(electric-fence style), the deterministic-detection sibling of [`@assert_noalloc`](@ref) for memory
safety rather than allocation. See [`memsafe_report`](@ref) for the full semantics of `isolate`,
`align`, and `using_module`, and its scope/platform limitations.

The probe runs on guard-page-backed **copies** of every `Array` argument; the real call then runs
once more, on the original arguments, so `f`'s return value and any argument mutation are exactly
as if you had called it plainly. Each argument expression is evaluated once; `f` itself runs
twice (probe, then real) — precedented by [`@assert_noalloc`](@ref)'s warm-up-then-measure pattern.
Disabled builds expand to the bare call, with no probe run at all.

**Keyword-argument calls are not yet supported** — call `f` positionally.

```julia
@assert_memsafe masked_load_kernel!(C, A, B)               # throws if it reads past a tile's end
@assert_memsafe isolate=false fills_only!(buf, x)           # cheaper store-only check
@assert_memsafe using_module=PureBLAS gemm_tile!(C, A, B)   # kernel's file needs its package context
```
"""
macro assert_memsafe(args...)
    pos, opts = _macro_call(args, (:isolate, :align, :using_module))
    isempty(pos) && throw(ArgumentError("@assert_memsafe needs a call expression"))
    call = pos[1]
    fexpr, argexprs, kwexprs = _callinfo(call)
    isempty(kwexprs) || throw(
        ArgumentError(
            "@assert_memsafe does not support keyword-argument calls; call `f` positionally " *
                "(or check it manually via `StrictMode.memsafe_report`)."
        )
    )
    target = string(call)
    fe = esc(fexpr)
    argsyms = [gensym(:arg) for _ in eachindex(argexprs)]
    binds = Any[:($s = $(esc(e))) for (s, e) in zip(argsyms, argexprs)]
    isolate_expr = haskey(opts, :isolate) ? esc(opts[:isolate]) : true
    align_expr = haskey(opts, :align) ? esc(opts[:align]) : nothing
    if haskey(opts, :using_module) && !(opts[:using_module] isa Symbol)
        throw(
            ArgumentError(
                "@assert_memsafe: using_module must be a plain top-level module name (e.g. " *
                    "`using_module = MyPackage`), not `$(opts[:using_module])` — a dotted " *
                    "submodule path isn't supported."
            )
        )
    end
    using_module_expr = haskey(opts, :using_module) ? Expr(:quote, opts[:using_module]) : nothing

    checked = quote
        $(binds...)
        local _f = $fe
        $(_assert_memsafe)(
            $target, _f, ($(argsyms...),);
            isolate = $isolate_expr, align = $align_expr, using_module = $using_module_expr
        )
        _f($(argsyms...))
    end
    return _gate(checked, esc(call))
end
