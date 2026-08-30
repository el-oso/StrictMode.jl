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
# Three facts this design is built on (all verified empirically, not assumed):
#   1. A guard-page fault is FATAL and uncatchable — for a read or a write alike. There is no
#      in-process way to observe one, so an in-process probe must never touch protected memory.
#   2. A WRITE fault also destroys the backtrace (`unknown function (ip: …)`, zero frames), while a
#      READ fault still names the faulting op. Classification therefore cannot come from the fault.
#   3. A poisoned, WRITABLE page detects an out-of-bounds store without faulting at all, and yields
#      the byte offset. That is what classifies a write.
#
# The probe therefore ALWAYS runs in a subprocess: a child that faults is detected by its parent via
# `proc.termsignal`, and that is the only way to observe a masked *load*, the motivating bug class.
# There is no in-process mode. An in-process probe can only use the canary, and a load past the end
# disturbs no canary, so its clean verdict is indistinguishable from "nothing overran" in exactly
# the case this harness exists for.
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

function _mprotect!(ptr::Ptr{Cvoid}, nbytes::Int, prot::Cint)
    r = ccall(:mprotect, Cint, (Ptr{Cvoid}, Csize_t, Cint), ptr, nbytes, prot)
    r == 0 || error("StrictMode @assert_memsafe: mprotect failed (errno $(Base.Libc.errno()))")
    return nothing
end

_munmap!(ptr::Ptr{Cvoid}, nbytes::Int) = (ccall(:munmap, Cint, (Ptr{Cvoid}, Csize_t), ptr, nbytes); nothing)

# Size of the trailing guard/canary region. More than one page so that a kernel overrunning by more
# than a page's worth is still trapped (or canaried) at a known offset rather than landing in
# unmapped memory, where a store faults instead of being localized and so misreports as a read.
const _GUARD_PAGES = 4

struct GuardedBuffer
    array::Array
    _base::Ptr{Cvoid}
    _total_bytes::Int
    _canary::Ptr{UInt8}     # first byte past the data: alignment slack, then the guard pages
    _canary_bytes::Int
    _poison::UInt8          # base byte; the expected value at offset k is `_poison_byte(base, k)`
    _readable::Bool         # false once the guard pages are PROT_NONE — the canary cannot be read
end

_free_guarded!(gb::GuardedBuffer) = _munmap!(gb._base, gb._total_bytes)

# Base poison byte for buffer `i`. DISTINCT PER BUFFER, and that is load-bearing rather than tidy:
# with a single shared value a kernel that copies between two guarded buffers launders it — the
# overrunning load pulls the poison out of the source's canary and the overrunning store writes that
# same byte into the destination's, so BOTH canaries read back clean on a kernel with an
# out-of-bounds read AND an out-of-bounds write. Measured, on `out[i] = a[i]` with a one-element
# overrun — this package's motivating kernel shape, not a corner case. Distinct bytes make the
# copied value differ from the destination's own poison, so the store is detected.
_poison_for(i::Integer) = UInt8(0xa5 ⊻ (UInt8(i % 251) * 0x11))

# Expected canary byte at offset `k` past the end of the data. POSITION-DEPENDENT, for two reasons a
# constant fill cannot cover:
#   - A buffer filled with its own poison value hides an overrunning store of that value entirely; a
#     constant-byte store now mismatches at least 7 of the 8 bytes of a `Float64`-wide store.
#   - A kernel that copies a buffer's own canary bytes to a shifted offset ("self-laundering") is
#     invisible when every position holds the same byte.
# The 251 modulus (prime, and coprime with every power-of-two element size) means a shift by any
# plausible element-multiple changes the expected byte.
_poison_byte(base::UInt8, k::Integer) = base ⊻ UInt8(k % 251)

"""
    _guarded_array(src::Array; align = sizeof(eltype(src))) -> GuardedBuffer

Copy `src` into a fresh `mmap`-backed buffer whose data is followed immediately by a poisoned
canary and then a trailing `PROT_NONE` guard region: any read or write past `src`'s last valid
byte faults deterministically. The default `align = sizeof(eltype(src))` always evenly divides the
data's total byte length, so the default placement puts the guard pages flush against the data.
Requesting a wider `align` (e.g. for a kernel that assumes SIMD-width alignment) inserts up to
`align - 1` bytes of slack before the guard pages; that slack is part of the poisoned canary, so a
STORE into it is still detected at its exact offset, but a READ of it cannot fault (warned once).

Only catches overruns past the **end of the allocation** — an interior overread (e.g. a masked
load reading past a valid sub-row but still inside the same buffer) is invisible to this harness.
There is no leading guard page in this version, so underruns are not caught either.
"""
function _guarded_array(src::Array{T, N}; align::Int = sizeof(T), guard_prot::Cint = _PROT_NONE, poison::UInt8 = _poison_for(1)) where {T, N}
    align > 0 || throw(ArgumentError("align must be positive, got $align"))
    n = length(src)
    databytes = n * sizeof(T)
    ps = _pagesize()
    slack = iszero(databytes) ? 0 : (align - databytes % align) % align
    if slack > 0
        @warn "StrictMode @assert_memsafe: align=$align does not evenly divide this buffer's " *
            "$databytes-byte length — $slack byte(s) of slack sit between the data and the guard " *
            "pages. A store into that slack is still reported at its exact offset (the canary " *
            "covers it), but a read of it cannot fault. Use align=sizeof(eltype(src)) (the " *
            "default) for a flush guard." maxlog = 3
    end
    padded_bytes = databytes + slack
    data_pages = cld(max(padded_bytes, 1), ps)
    data_region_bytes = data_pages * ps
    guard_bytes = _GUARD_PAGES * ps
    total_bytes = data_region_bytes + guard_bytes
    base = _mmap_anon(total_bytes)
    guard_ptr = base + data_region_bytes
    data_start = guard_ptr - padded_bytes
    canary_ptr = Ptr{UInt8}(data_start + databytes)   # the slack, then the guard pages
    canary_bytes = slack + guard_bytes
    try
        # Poison the canary BEFORE protecting the guard pages. Under `_PROT_NONE` the guard bytes
        # are unreadable and inert; under `_PROT_READ|_PROT_WRITE` the whole canary is what an
        # out-of-bounds STORE disturbs without faulting. That is the only way to localize a write: a
        # guard-page write fault is FATAL and its backtrace is unusable (`unknown function (ip: …)`,
        # zero frames), so nothing can be recovered from the fault itself. Do not reintroduce a
        # `ReadOnlyMemoryError` catch.
        for k in 0:(canary_bytes - 1)
            unsafe_store!(canary_ptr, _poison_byte(poison, k), k + 1)
        end
        _mprotect!(guard_ptr, guard_bytes, guard_prot)
    catch
        _munmap!(base, total_bytes)
        rethrow()
    end
    arr = unsafe_wrap(Array, Ptr{T}(data_start), size(src); own = false)
    copyto!(arr, src)
    readable = !iszero(guard_prot & _PROT_READ)
    return GuardedBuffer(arr, base, total_bytes, canary_ptr, canary_bytes, poison, readable)
end

# --- the canary classifier: detects an out-of-bounds STORE without faulting --------------------
#
# Leave the trailing region readable AND writable, pre-filled with a per-buffer, position-dependent
# poison byte. A store past the end then lands in the canary instead of trapping, so it can be
# observed after the fact — with the byte offset and the argument it belongs to. That is the
# replacement for the backtrace Julia 1.12+ destroys on a guard-page write fault.
#
# Reads past the end are invisible to this probe by construction (a load disturbs nothing); the
# PROT_NONE guard region is what detects those. The two are complementary, not redundant.

# Byte offset (past the end of the data) of the first disturbed canary byte, or `nothing` if the
# canary is untouched.
function _canary_dirty(gb::GuardedBuffer)
    gb._readable || error("StrictMode @assert_memsafe: internal error — the canary of a PROT_NONE-guarded buffer cannot be read.")
    for k in 0:(gb._canary_bytes - 1)
        unsafe_load(gb._canary, k + 1) == _poison_byte(gb._poison, k) || return k
    end
    return nothing
end

# Guarded stand-ins for every `Array` argument, plus the handles needed to inspect and free them.
#
# Argument positions holding the SAME array share ONE guarded buffer, by object identity. Building
# an independent copy per position would hand `f(A, A)` two distinct pointers, which both hides
# aliasing-dependent overruns and breaks kernels that require the aliasing they were called with.
# Each handle carries every position its buffer stands in for, so a hit names all of them.
function _guarded_args(args::Tuple; align::Union{Nothing, Int}, guard_prot::Cint = _PROT_NONE)
    probe_args = Any[]
    handles = Tuple{Vector{Int}, GuardedBuffer}[]
    seen = IdDict{Any, Int}()
    for (i, a) in enumerate(args)
        if a isa Array
            j = get(seen, a, 0)
            if iszero(j)
                gb = _guarded_array(
                    a; align = something(align, sizeof(eltype(a))),
                    guard_prot, poison = _poison_for(length(handles) + 1)
                )
                push!(handles, ([i], gb))
                seen[a] = length(handles)
                push!(probe_args, gb.array)
            else
                push!(handles[j][1], i)
                push!(probe_args, handles[j][2].array)
            end
        else
            push!(probe_args, a)
        end
    end
    return (probe_args, handles)
end

# Run `f` with every Array argument backed by a writable, poisoned canary. Returns `nothing` when
# nothing stored past any end, or a description naming the argument, its type and the byte offset.
function _canary_probe(@nospecialize(f), args::Tuple; align::Union{Nothing, Int})
    probe_args, handles = _guarded_args(args; align, guard_prot = _PROT_READ | _PROT_WRITE)
    try
        f(probe_args...)
        hits = String[]
        for (positions, gb) in handles
            off = _canary_dirty(gb)
            isnothing(off) && continue
            where = length(positions) == 1 ? "argument $(only(positions))" :
                "arguments " * join(positions, ", ") * " (one shared buffer)"
            push!(hits, "$where::$(typeof(gb.array)) at +$off byte(s) past its end")
        end
        return isempty(hits) ? nothing : join(hits, "; ")
    finally
        foreach(h -> _free_guarded!(h[2]), handles)
    end
end

# --- arguments this harness cannot guard ---------------------------------------------------------
#
# A clean verdict over a partially guarded call must not render like a clean verdict over a fully
# guarded one, so every argument the harness cannot place behind a guard page is named.
#
# Two classes, treated differently because their fixes differ. A `view`/`Adjoint`/other non-`Array`
# `AbstractArray` has no relocatable backing store to rebuild, and the caller can materialize it
# (`collect`) to get coverage — so `@assert_memsafe` rejects it outright. A struct that carries
# arrays in its fields hides them from the argument list, and there is nothing the caller can
# restructure at the call site — so that one is reported, not rejected.

# Could a value of type `T` hold an array in (or below) its fields? A field typed abstractly enough
# to hold one counts: the answer must never understate coverage that was not achieved.
function _carries_array(@nospecialize(T::Type), depth::Int = 2)
    depth < 0 && return false
    isconcretetype(T) || return false
    for FT in fieldtypes(T)
        (FT <: AbstractArray || AbstractArray <: FT) && return true
        FT === T && continue                     # self-referential field: nothing new below it
        _carries_array(FT, depth - 1) && return true
    end
    return false
end

# `(position, class, description)` per unguardable argument; `class` is `:abstractarray` or `:struct`.
function _unguarded_args(args::Tuple)
    out = Tuple{Int, Symbol, String}[]
    for (i, a) in enumerate(args)
        a isa Array && continue
        if a isa AbstractArray
            push!(
                out, (
                    i, :abstractarray,
                    "argument $i::$(typeof(a)) is an AbstractArray that is not an Array — it has no " *
                        "relocatable backing store, so it runs unguarded",
                )
            )
        elseif _carries_array(typeof(a))
            push!(
                out, (
                    i, :struct,
                    "argument $i::$(typeof(a)) carries array(s) in its fields — those buffers are not " *
                        "arguments, so they run unguarded",
                )
            )
        end
    end
    return out
end

# --- the subprocess probe: catches OOB READS and WRITES ------------------------------------------
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

# Signal numbers are OS-specific: SIGBUS is 7 on Linux but 10 on Darwin/macOS (SIGSEGV is 11 on
# both). A guard-page boundary fault raises SIGSEGV on Linux but SIGBUS on macOS for the same
# out-of-bounds access — both indicate the same fault class this harness is designed to catch.
# Julia renders a memory fault it caught itself as one of these; a raw signal death has no such text.
const _MEMFAULT_RE = r"ReadOnlyMemoryError|SegmentationFault"

function _signal_name(sig::Integer)
    sig == 11 && return "SIGSEGV"
    bus = Sys.isapple() ? 10 : 7
    sig == bus && return "SIGBUS"
    return "signal $sig"
end

function _memsafe_child_script(kernel_file::AbstractString, fname::Symbol, args_path::AbstractString, using_module::Union{Nothing, Symbol}, align::Union{Nothing, Int})
    mod_stmt = isnothing(using_module) ? "include($(repr(kernel_file)))" : "using $(using_module)"
    lookup_mod = isnothing(using_module) ? "Main" : string(using_module)
    align_arg = isnothing(align) ? "nothing" : string(align)   # an Int repr is safe to splice verbatim
    # Plain (global) top-level bindings, not `local` — a top-level `local` in a multi-statement
    # script only scopes to its own statement, so it doesn't survive to the next line. Harmless
    # here: this is a throwaway one-shot process that exits right after.
    #
    # ONE child does both jobs, in this order:
    #
    #   1. CLASSIFY with the writable poisoned canary. This cannot fault, so it always completes,
    #      and it is the only thing that can tell an out-of-bounds WRITE from a READ now that a
    #      write fault's backtrace is destroyed (Julia 1.12+ gives `unknown function (ip: …)` and
    #      zero frames, where the read fault still names the kernel and line).
    #   2. DETECT with the PROT_NONE guard page, which traps either access class and kills this
    #      process.
    #
    # The classification line is printed and FLUSHED before step 2, and a flushed write survives the
    # subsequent fatal signal into the parent's pipe — measured: `termsignal=11` with the sentinel
    # present in the captured stdout. That is what makes a single spawn sufficient; classifying in a
    # second child would double the cost of the clean path, which is the common one.
    #
    # No `try`/`catch` around step 2: a genuine exception from `f` must propagate so the parent
    # reports an unrelated script error rather than a memory-safety verdict. The guard-page hit
    # itself may arrive either as a fatal signal or as a catchable `ReadOnlyMemoryError` depending
    # on the host; the parent distinguishes both from an unrelated error, so neither is caught here.
    return """
    using StrictMode, Serialization
    $mod_stmt
    __args = deserialize($(repr(args_path)))
    __f = getfield($lookup_mod, $(repr(fname)))
    __hit = StrictMode._canary_probe(__f, __args; align=$align_arg)
    println(stdout, isnothing(__hit) ? "STRICTMODE_CANARY_CLEAN" : "STRICTMODE_CANARY_DIRTY " * __hit)
    flush(stdout)
    __guarded, __handles = StrictMode._guarded_args(__args; align=$align_arg)
    __f(__guarded...)
    print(stdout, "STRICTMODE_MEMSAFE_OK")
    flush(stdout)
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
                "— the guarded probe needs a named function reachable in a fresh process. Move the " *
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
        # The canary line is printed and flushed BEFORE the guard probe, so it is present whether or
        # not the child then died on the guard page.
        canary = match(r"STRICTMODE_CANARY_DIRTY (.*)", out_s)
        # A guard-page hit does not always arrive as a signal. Julia's own fault handler can turn an
        # access to protected memory into a CATCHABLE `ReadOnlyMemoryError`, and the child then dies
        # with exit code 1 and an ordinary backtrace instead of a `termsignal`. Both deliveries are
        # the same event, and the harness must count both: treating the exception form as an
        # unrelated script error reports a real detection as a broken probe. The write kernel takes
        # the exception path on some Linux and macOS hosts and the signal path on others.
        by_signal = proc.termsignal != 0
        by_exception = !by_signal && proc.exitcode != 0 && occursin(_MEMFAULT_RE, err_s)
        if by_signal || by_exception
            how = by_signal ? "killed by $(_signal_name(proc.termsignal))" :
                "stopped by a memory-access exception"
            if canary !== nothing
                # A store past the end. Report the canary's own localization: on Julia 1.12+ the
                # write fault's backtrace is destroyed (`unknown function (ip: …)`, zero frames), so
                # the child's signal report carries nothing usable and the canary is all there is.
                return "out-of-bounds WRITE detected: $(canary.captures[1]). (The guarded probe " *
                    "subprocess was then $how; a write fault's own backtrace is not " *
                    "usable, so the offset above comes from a writable poisoned canary.)"
            end
            return "out-of-bounds READ detected — the guarded probe subprocess was $how " *
                "and nothing was stored past any argument's end. Child's own fault " *
                "report (names the faulting op):\n" * _indent(err_s)
        elseif proc.exitcode != 0
            error(
                "StrictMode @assert_memsafe: the guarded probe errored for a reason other than a " *
                    "memory fault (exit code $(proc.exitcode)) — this is not itself a memsafe " *
                    "violation, fix the underlying error:\n" * _indent(err_s)
            )
        elseif canary !== nothing
            # Stored past the end without tripping the guard page. Reachable when the store lands
            # beyond the guard page rather than in it, or when the kernel writes and the guard probe
            # happens not to fault.
            return "out-of-bounds WRITE detected: $(canary.captures[1])."
        elseif !occursin("STRICTMODE_MEMSAFE_OK", out_s)
            error("StrictMode @assert_memsafe: internal error — the probe subprocess exited cleanly but did not report success.\nstdout:\n" * _indent(out_s) * "\nstderr:\n" * _indent(err_s))
        end
        return nothing
    finally
        rm(args_path; force = true)
    end
end

# --- public API -----------------------------------------------------------------------------------

const _ISOLATE_REMOVED = "StrictMode @assert_memsafe: the `isolate` option was removed — the probe " *
    "always runs in a subprocess. An in-process probe can only use the canary, and a load past the " *
    "end disturbs no canary, so its clean verdict was indistinguishable from no overrun at all in " *
    "exactly the case this harness exists for. Drop `isolate=`."

"""
    MemsafeReport

The result of [`memsafe_report`](@ref): `target` (the checked signature, as a string), `violation`
(`nothing` if clean, else a description of the out-of-bounds access detected — naming the faulting
op for a read), and `unguarded` (one line per argument the harness could not place behind a guard
page). A clean `violation` with a non-empty `unguarded` means part of the call was never covered.
"""
struct MemsafeReport
    target::String
    violation::Union{Nothing, String}
    unguarded::Vector{String}
end

function Base.show(io::IO, r::MemsafeReport)
    printstyled(io, "MemsafeReport"; bold = true)
    print(io, ": ", r.target, "\n")
    if isnothing(r.violation)
        printstyled(io, "  clean"; color = :green)
        print(io, ": no out-of-bounds access detected.")
    else
        printstyled(io, "  VIOLATION"; color = :red, bold = true)
        print(io, ": ", r.violation)
    end
    for u in r.unguarded
        print(io, "\n")
        printstyled(io, "  UNGUARDED"; color = :yellow, bold = true)
        print(io, ": ", u)
    end
    return nothing
end

"""
    memsafe_report(f, args...; align = nothing, using_module = nothing) -> MemsafeReport

Run `f(args...)` once against guard-page-backed copies of every `Array` argument and report
whether an out-of-bounds access was detected. Non-execution guarantees elsewhere in StrictMode
(`check`/`findings`) are value-free by design; this one needs real argument values to build the
guarded buffers, so it stays a `@golden`-style value-based function/macro pair instead.

The probe always runs in a **subprocess**: a fatal out-of-bounds READ (a SIGSEGV) is then observed
through the child's exit signal instead of killing your session, and that read is the motivating
bug class. An out-of-bounds WRITE is localized by a poisoned canary the child reads back before it
touches the guard pages, since a write fault's own backtrace is destroyed.

- `align`: alignment (bytes) for each guarded array's start pointer (internally, `_guarded_array`)
  — the default (the element's own size) places the guard pages flush against the data.
- `using_module`: for when `f`'s defining file isn't self-contained (relies on its package's
  `using`/context) — the subprocess does `using \$using_module` and looks `f` up there, instead of
  raw-`include`-ing the source file.

**Scope**: only `Array` arguments are guarded. Arguments that cannot be guarded — a `view`, an
`Adjoint`, any other non-`Array` `AbstractArray`, or a struct carrying arrays in its fields — are
listed in `unguarded`; the call still runs, but those buffers are not covered. Only catches
overruns past the *end* of an allocation (no leading guard, no interior-overread detection).
Positions holding the same array share one guarded buffer, so aliasing is preserved. Linux/macOS
only (needs `mmap`/`mprotect` + POSIX signal delivery). The fatal signal for a guard-page fault is
platform-dependent — SIGSEGV on Linux, SIGBUS on macOS — both are reported identically as a memsafe
violation.

The subprocess loads `f` from its defining source file, so under a Revise-style edit loop it checks
what is on disk, not what this session compiled. If the file changed since `f` was defined here, the
verdict describes different code — in either direction, a clean report included. Reload before
trusting a probe after an edit.

```julia
r = memsafe_report(masked_load_kernel!, C, A, B)
isnothing(r.violation) || error(r.violation)
```
"""
function memsafe_report(
        @nospecialize(f), args...;
        align::Union{Nothing, Int} = nothing, using_module::Union{Nothing, Symbol} = nothing,
        isolate = nothing
    )
    isnothing(isolate) || throw(ArgumentError(_ISOLATE_REMOVED))
    Sys.islinux() || Sys.isapple() || error(
        "StrictMode @assert_memsafe: only Linux/macOS are supported (needs mmap/mprotect + POSIX " *
            "signal delivery); got Sys.KERNEL = $(Sys.KERNEL)."
    )
    target = _func_name(f) * _sig_string(map(typeof, args))
    violation = _memsafe_probe_subprocess(f, args; using_module, align)
    return MemsafeReport(target, violation, [d for (_, _, d) in _unguarded_args(args)])
end

function _assert_memsafe(target, @nospecialize(f), args::Tuple; align, using_module)
    # A `view`/`Adjoint` is rejected rather than reported: the caller can materialize it and get
    # real coverage, and a gate that silently checks less than it names is the failure this
    # harness exists to remove. A struct's array fields have no such fix at the call site, so
    # those are named and the check proceeds over what it can cover.
    unguarded = _unguarded_args(args)
    rejected = [d for (_, class, d) in unguarded if class === :abstractarray]
    isempty(rejected) || throw(
        ArgumentError(
            "@assert_memsafe cannot guard every argument of `$target`, so a clean verdict would " *
                "cover less than it claims:\n  " * join(rejected, "\n  ") *
                "\nPass a materialized `Array` (e.g. `collect(v)`) instead, or use " *
                "`memsafe_report`, which reports the gap in its `unguarded` field rather than " *
                "refusing the call."
        )
    )
    for (_, class, d) in unguarded
        class === :struct && @warn "StrictMode @assert_memsafe: $d. The guarantee covers only the " *
            "`Array` arguments of `$target`." maxlog = 3
    end
    violation = _memsafe_probe_subprocess(f, args; using_module, align)
    isnothing(violation) || _fail(:memsafe, target, violation)
    return nothing
end

"""
    @assert_memsafe f(args...)
    @assert_memsafe using_module=MyPackage f(args...)
    @assert_memsafe align=64 f(args...)

Fail if `f(args...)` performs an **out-of-bounds array access** — a `PROT_NONE`-guard-page harness
(electric-fence style), the deterministic-detection sibling of [`@assert_noalloc`](@ref) for memory
safety rather than allocation. See [`memsafe_report`](@ref) for the full semantics of `align` and
`using_module`, and its scope/platform limitations.

The probe runs in a subprocess, on guard-page-backed **copies** of every `Array` argument; the real
call then runs once more, in this process, on the original arguments, so `f`'s return value and any
argument mutation are exactly as if you had called it plainly. Each argument expression is
evaluated once; `f` itself runs twice (probe, then real) — precedented by
[`@assert_noalloc`](@ref)'s warm-up-then-measure pattern. Disabled builds expand to the bare call,
with no probe run at all.

An argument that cannot be guarded and that the caller *can* fix — a `view`, an `Adjoint`, any
other non-`Array` `AbstractArray` — is rejected, because a passing guarantee must not cover less
than it names; pass `collect(v)`, or use [`memsafe_report`](@ref), which reports the gap instead of
refusing. A struct carrying arrays in its fields has no call-site fix, so it is warned about and
the check proceeds over the `Array` arguments.

**Keyword-argument calls are not yet supported** — call `f` positionally.

```julia
@assert_memsafe masked_load_kernel!(C, A, B)               # throws if it reads past a tile's end
@assert_memsafe align=64 aligned_kernel!(buf, x)            # kernel assumes a 64-byte-aligned start
@assert_memsafe using_module=PureBLAS gemm_tile!(C, A, B)   # kernel's file needs its package context
```
"""
macro assert_memsafe(args...)
    # `:isolate` stays in the allowed set only so it can be rejected here: dropping it would make
    # `isolate=false` parse as a positional argument and misreport as "needs a call expression".
    pos, opts = _macro_call(args, (:isolate, :align, :using_module))
    haskey(opts, :isolate) && throw(ArgumentError(_ISOLATE_REMOVED))
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
            align = $align_expr, using_module = $using_module_expr
        )
        _f($(argsyms...))
    end
    return _gate(checked, esc(call))
end
