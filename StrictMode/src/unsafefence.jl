# Rust's `#![forbid(unsafe_code)]` applied to a Julia module: a layer that must stay inside the
# language's guarantees declares so, and anything that leaves them is reported. Julia cannot enforce
# this — `ccall` and `unsafe_load` are ordinary calls — so it is a scan, and the declaration is the
# caller asking for it.
#
# Read from each method's own LOWERED code, before any inlining: a small wrapper around a pointer
# load inlines under optimization, and its `unsafe_load` then surfaces in an innocent caller while
# disappearing from the method that wrote it.

# `pointer` does not begin with `unsafe_`, and taking one is the step that leaves the language's
# guarantees even when nothing is dereferenced yet. The rest are the intrinsics the `unsafe_*`
# functions are built from, which a method can call directly: a pointer load or store, inline LLVM
# IR, and the address of a C global.
const _UNSAFE_NAMES = (
    :pointer, :pointer_from_objref, :pointerref, :pointerset, :atomic_pointerref,
    :atomic_pointerset, :atomic_pointerswap, :atomic_pointermodify, :atomic_pointerreplace,
    :llvmcall, :cglobal,
)

# The C allocator and the raw memory routines, matched by identity: `free` and `malloc` are names
# a package may well give a function of its own.
const _UNSAFE_LIBC = Base.IdSet{Any}(
    getglobal(Libc, n) for n in (:malloc, :calloc, :realloc, :free, :memcpy, :memmove, :memset, :memcmp)
        if isdefined(Libc, n)
)

# The construct names that are not the name of a function: a `ccall` statement, an `@cfunction`,
# `@inbounds`, and a pointer made from an integer or by reinterpreting one (`Ptr{T}(addr)`).
const _UNSAFE_FORMS = (:ccall, :cfunction, :inbounds, :Ptr)

# The builtins that take a bounds-check flag as their last argument. A literal `false` there reads
# or writes without the check, as `@inbounds` does.
const _UNCHECKED_BUILTINS = (
    :memoryrefnew, :memoryrefget, :memoryrefset!, :memoryrefswap!, :memoryrefmodify!,
    :memoryrefreplace!, :memoryrefsetonce!, :getfield,
)

# `ccall` lowers its arguments through these two. Reporting them as separate findings would add a
# line per `ccall` that tells the reader nothing the `ccall` finding did not.
const _CCALL_GLUE = (:cconvert, :unsafe_convert)

# `@inbounds` reaches typed IR as a per-statement flag, not as a statement of its own, so it is read
# from `ssaflags` rather than from `ci.code`. The reference is direct, like `_max_methods`' use of
# `InferenceParams`: a Julia that renames the flag must fail loudly here rather than let the scan
# report a module using `@inbounds` as clean.
const _IR_FLAG_INBOUNDS = Base.Compiler.IR_FLAG_INBOUNDS

_is_unsafe_name(nm::Symbol) = nm in _UNSAFE_NAMES || startswith(String(nm), "unsafe_")

# The construct a value names when it is one of the functions this scan reports, else `nothing`.
# Asked of every operand, not only of the callee: `map(unsafe_load, ps)`, `unsafe_load.(ps)`,
# `unsafe_load(args...)`, `unsafe_wrap(Array, p, n; own)` and `f = unsafe_load` all name the
# function as an argument of some other call, or as a value.
function _unsafe_function(@nospecialize(v))
    (v isa Function || v isa Core.IntrinsicFunction) || return nothing
    v in _UNSAFE_LIBC && return nameof(v)::Symbol   # by identity, so before the name test
    nm = try
        nameof(v)
    catch
        return nothing
    end
    return (nm isa Symbol && _is_unsafe_name(nm)) ? nm : nothing
end

_is_ptr_type(@nospecialize(v)) = v isa Type && v <: Ptr && v !== Union{}

# `allow` names constructs by bare `Symbol`, but a reader looks for the macro they wrote.
_render_construct(nm::Symbol) =
    nm === :inbounds ? "`@inbounds`" : nm === :cfunction ? "`@cfunction`" : "`" * String(nm) * "`"

const _UNSAFE_LIBC_NAMES = Tuple(sort!(Symbol[nameof(f) for f in _UNSAFE_LIBC]))

# An `allow` entry that names no construct this scan can report excuses nothing, which a caller
# who misspelled one would read as the exception being in force.
function _check_allow(allow)
    allowed = Set{Symbol}()
    for a in allow
        nm = Symbol(a)
        known = _is_unsafe_name(nm) || nm in _UNSAFE_FORMS || nm in _UNCHECKED_BUILTINS ||
            nm in _UNSAFE_LIBC_NAMES
        known || throw(
            ArgumentError(
                "unsafe_report: `allow` names `$nm`, which is not a construct this scan reports. " *
                    "Accepted: :" *
                    join((_UNSAFE_FORMS..., _UNSAFE_NAMES..., _UNSAFE_LIBC_NAMES..., _UNCHECKED_BUILTINS...), ", :") *
                    ", and any function whose name begins with `unsafe_`."
            )
        )
        push!(allowed, nm)
    end
    return allowed
end

# The function a lowered call names, resolved without inference: a `GlobalRef`, a constant, or
# `M.name` on a module, which lowers to `getproperty(M, :name)` (or is written `getfield(M, :name)`)
# in a statement of its own.
function _lowered_callee(code::Vector{Any}, @nospecialize(a), depth::Int = 0)
    depth > 8 && return nothing
    a isa GlobalRef && return isdefined(a.mod, a.name) ? getglobal(a.mod, a.name) : nothing
    a isa QuoteNode && return a.value
    # `M.name` written where a value is stored (`f = Base.unsafe_load`) is the call itself, with
    # no statement of its own.
    Meta.isexpr(a, :call) && return _lowered_global_read(code, a, depth)
    if a isa Core.SSAValue
        s = code[a.id]
        v = _lowered_global_read(code, s, depth)
        isnothing(v) || return v
        # `Ptr{T}` is `Core.apply_type(Ptr, T)` in a statement of its own. The type it names is
        # the one being parameterized, which is all a caller needs to know it is a pointer type.
        if Meta.isexpr(s, :call) && length(s.args) >= 2 &&
                _lowered_callee(code, s.args[1], depth + 1) === Core.apply_type
            return _lowered_callee(code, s.args[2], depth + 1)
        end
        return _lowered_callee(code, s, depth + 1)
    end
    return a isa Expr ? nothing : a
end

# The value `M.name` reads: `getproperty(M, :name)`, `getfield(M, :name)` or `getglobal(M, :name)`
# on a module, else `nothing`.
function _lowered_global_read(code::Vector{Any}, @nospecialize(s), depth::Int)
    (Meta.isexpr(s, :call) && length(s.args) == 3) || return nothing
    _lowered_callee(code, s.args[1], depth + 1) in (getproperty, getfield, getglobal) || return nothing
    M = _lowered_callee(code, s.args[2], depth + 1)
    nm = s.args[3] isa QuoteNode ? s.args[3].value : s.args[3]
    return (M isa Module && nm isa Symbol && isdefined(M, nm)) ? getglobal(M, nm) : nothing
end

function _scan_unsafe!(out::Set{Symbol}, ci::Core.CodeInfo, resolve)
    # One finding per method, so the span an `@inbounds` block covers does not matter: a bare
    # `@inbounds a[i]` flags one statement and `@inbounds for …` flags most of the loop, and both
    # mean the same thing about this method.
    any(fl -> !iszero(fl & _IR_FLAG_INBOUNDS), ci.ssaflags) && push!(out, :inbounds)
    note(@nospecialize(v)) = (nm = _unsafe_function(v); isnothing(nm) || push!(out, nm); nothing)
    # A value a statement can hold by name: lowering gives a global its own statement, so the
    # name is judged where it is USED. A use as a callee, an argument, a stored local or a
    # returned value hands the function on; a comparison (`f === unsafe_load`) does not.
    named(@nospecialize(a)) = a isa Core.SSAValue || a isa GlobalRef || a isa QuoteNode ||
        a isa Function || a isa Core.IntrinsicFunction
    for st in ci.code
        # Lowered code writes `p = pointer(a)` as an assignment around the call, and
        # `f = unsafe_load` as one around the name.
        if Meta.isexpr(st, :(=))
            st = st.args[2]
            (named(st) || Meta.isexpr(st, :call)) && note(resolve(st))
        end
        if st isa Core.ReturnNode
            isdefined(st, :val) && named(st.val) && note(resolve(st.val))
            continue
        end
        st isa Expr || continue
        if st.head === :foreigncall
            push!(out, :ccall)
            continue
        elseif st.head === :cfunction
            push!(out, :cfunction)
            continue
        end
        (st.head === :call && !isempty(st.args)) || continue
        callee = resolve(st.args[1])
        # Comparing a value with an unsafe function hands the function to nothing.
        (callee === (===) || callee === (!==) || callee === (==) || callee === (!=) || callee === isequal) && continue
        # The method table a call goes through does not make the call unsafe, so the function a
        # keyword call, a splat, a broadcast or a `map` is handed counts as much as a callee.
        for a in st.args
            named(a) && note(resolve(a))
        end
        isnothing(callee) && continue
        if _is_ptr_type(callee)
            push!(out, :Ptr)
        elseif (callee === reinterpret || callee === Core.Intrinsics.bitcast || callee === convert) && length(st.args) >= 2 &&
                _is_ptr_type(resolve(st.args[2]))
            push!(out, :Ptr)
        elseif callee isa Core.Builtin && length(st.args) >= 3 && st.args[end] === false
            nm = nameof(callee)
            nm in _UNCHECKED_BUILTINS && !(nm === :getfield && length(st.args) != 4) && push!(out, nm)
        end
    end
    return out
end

# The unsafe constructs in one method's body, as a sorted, deduplicated list of names. `ccall`
# stands for a `:foreigncall` statement, which is what a `ccall` becomes.
#
# Read from the method's LOWERED code, which is what it wrote: every construct here is visible
# there, and reading it runs no inference. Inferring at the method's declared signature cost
# seconds on a large generic kernel, and for an abstract signature it returned the code of every
# method matching it, so a generic method was charged with the `@inbounds` and `unsafe_*` calls of
# its more specific siblings. A `@generated` method has no lowered body of its own and is inferred,
# keeping only its own result.
#
# `nothing` when the method's code cannot be read: a generator that raises, or a method that keeps
# no source. That is not an empty list, which says the method was read and is clean.
function _unsafe_constructs(m::Method)
    out = Set{Symbol}()
    if isdefined(m, :generator)
        cis = try
            _code_typed_by_type(m.sig; optimize = false)
        catch
            return nothing
        end
        read = false
        for pair in cis
            ci = pair isa Pair ? pair.first : pair
            ci isa Core.CodeInfo || continue
            mi = ci.parent
            (mi isa Core.MethodInstance && mi.def !== m) && continue
            _scan_unsafe!(out, ci, a -> _unopt_callee(ci, a))
            read = true
        end
        # A generator that raises yields its `Method` in place of the code.
        read || return nothing
    else
        src = try
            Base.uncompressed_ast(m)
        catch
            return nothing
        end
        _scan_unsafe!(out, src, a -> _lowered_callee(src.code, a))
    end
    # A `ccall` already says this method leaves the language; its own argument conversion is not a
    # second thing to fix.
    :ccall in out && setdiff!(out, _CCALL_GLUE)
    return sort!(collect(out))
end

"""
    unsafe_report(mod::Module; only = nothing, exempt = (), allow = ()) -> Vector{StrictFinding}

Every method in `mod` that leaves Julia's safety guarantees: one `:fail` finding per method that
uses any of these.

| construct | reported as |
|---|---|
| a `ccall` or `@ccall` | `:ccall` |
| `@cfunction` | `:cfunction` |
| `@inbounds` | `:inbounds` |
| `pointer`, `pointer_from_objref`, and any function whose name begins with `unsafe_` | its name |
| the pointer intrinsics `pointerref`, `pointerset`, `atomic_pointer…`, and `llvmcall`, `cglobal` | its name |
| `Libc.malloc`, `calloc`, `realloc`, `free`, `memcpy`, `memmove`, `memset`, `memcmp` | its name |
| a pointer made from an integer: `Ptr{T}(addr)`, `reinterpret(Ptr{T}, addr)`, `convert(Ptr{T}, addr)` | `:Ptr` |
| `memoryrefnew`, `memoryrefget`, `memoryrefset!` or `getfield` with a literal `false` bounds check | its name |

A function counts wherever the method names it, not only where it calls it: `map(unsafe_load, ps)`,
`unsafe_load.(ps)`, `unsafe_load(args...)`, `unsafe_wrap(Array, p, n; own = false)` and
`f = unsafe_load; f(p)` are all reported as `unsafe_load` or `unsafe_wrap`. The name may be
qualified or looked up: `f = Base.unsafe_load` and `getglobal(Base, :unsafe_load)(p)` name it too. Comparing a value with
one (`f === unsafe_load`) is not. The C allocator is matched by identity, so a package's own
function named `free` is not `Libc.free`. Taking a `Ptr` argument, or naming the type, builds no
pointer and is not reported.
A conversion to a pointer type is reported whatever is converted: the scan reads lowered code,
which carries no types, so `convert(Ptr{Cvoid}, p)` on a pointer reads like one on an address.

This is the scan behind `StrictModeTest.test_no_unsafe`, and the Julia form of Rust's
`#![forbid(unsafe_code)]`. The language cannot enforce it — `ccall` and `unsafe_load` are ordinary
calls that any module may make — so a layer that must stay inside the guarantees says so by running
this, and the result is the list of places that do not.

`allow` names the constructs this module is permitted to use anyway, by the `Symbol` in the table:
`allow = (:unsafe_load,)` keeps a deliberate, reviewed pointer read from failing while still
reporting a `ccall` elsewhere. A name that is no construct of this scan raises an `ArgumentError`
listing the accepted ones, since an entry that excuses nothing reads as an exception in force. `only` and `exempt` filter by the *defining* function's name, as
everywhere else.

```julia
unsafe_report(MyKernels)                            # every escape, as findings
unsafe_report(MyKernels; allow = (:unsafe_load,))   # one reviewed construct excused
```

**`@inbounds` is reported as `:inbounds`.** It leaves no statement in lowered or typed IR — it is
carried in the per-statement `ssaflags` — so it is read from there and not from the statement list.
It belongs in this report because it is the one construct here that trades a thrown `BoundsError`
for silent undefined behavior; `allow = (:inbounds,)` excuses it where the in-range property is
proved and tested.

A `Base.@propagate_inbounds` method is clean on its own, and the finding lands on the caller that
wrote `@inbounds`, which is the method that made the claim.

Read from each method's own lowered code on purpose. A small wrapper around a pointer load inlines
under optimization, so its `unsafe_load` would surface in an innocent caller and vanish from the
method that actually wrote it. Lowered code needs no inference, so the scan is cheap on any module.
"""
function unsafe_report(mod::Module; only = nothing, exempt = (), allow = ())
    allowed = _check_allow(allow)
    out = StrictFinding[]
    methods_, _ = module_methods(mod; only, exempt)
    for m in methods_
        found = _unsafe_constructs(m)
        if isnothing(found)
            push!(
                out, _unevaluated(
                    nameof(mod), string(m.name), string(m.sig), :unsafe,
                    "the method's code could not be read, so it was not checked for constructs " *
                        "that leave Julia's safety guarantees";
                    file = string(m.file), line = Int(m.line)
                )
            )
            continue
        end
        isempty(found) && continue
        reported = filter(n -> !(n in allowed), found)
        isempty(reported) && continue
        names = join((_render_construct(n) for n in reported), ", ")
        push!(
            out,
            _mkfinding(
                nameof(mod), string(m.name), string(m.sig), :unsafe, true,
                "leaves Julia's safety guarantees: " * names,
                string(m.file), Int(m.line),
                "rewrite the method inside the language, or — where the escape is deliberate and " *
                    "reviewed — name it with `allow = (" *
                    join((":" * String(n) for n in reported), ", ") * ",)` so the exception is " *
                    "visible where the policy is written"
            )
        )
    end
    return out
end
