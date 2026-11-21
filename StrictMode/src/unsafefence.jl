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
# `@inbounds`, a pointer made from an integer or by reinterpreting one (`Ptr{T}(addr)`), a
# global of a module read by a name that is a run-time value (`getglobal(Base, nm)`), which may be
# any function the module holds, and code evaluated at run time (`eval`, `include_string`), which
# may do anything.
const _UNSAFE_FORMS = (:ccall, :cfunction, :inbounds, :Ptr, :dynamic_global, :eval)

# The functions that evaluate code at run time. What that code does is a value of the call, so,
# like a `dynamic_global` read, it cannot be read from the method or cleared. A module's own `eval`
# and `include` are instances of the two types, one per module.
const _EVAL_FUNCS = Base.IdSet{Any}((Core.eval, Base.eval, Base.include_string, Base.include))
const _EVAL_TYPES = Tuple(getglobal(M, n) for (M, n) in ((Core, :EvalInto), (Base, :IncludeInto)) if isdefined(M, n))
_is_eval(@nospecialize(v)) = v in _EVAL_FUNCS || any(T -> v isa T, _EVAL_TYPES)

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
#
# A callable object holding a function, such as `const LOAD1 = Base.Fix2(unsafe_load, 1)` or
# `identity ∘ Libc.free`, names the functions it holds: calling it calls them.
function _unsafe_function(@nospecialize(v), depth::Int = 0)
    (v isa Function || v isa Core.IntrinsicFunction) || return nothing
    _is_eval(v) && return :eval
    v in _UNSAFE_LIBC && return nameof(v)::Symbol   # by identity, so before the name test
    nm = try
        nameof(v)
    catch
        nothing
    end
    (nm isa Symbol && _is_unsafe_name(nm)) && return nm
    depth < 4 || return nothing
    for i in 1:nfields(v)
        isdefined(v, i) || continue
        inner = _unsafe_function(getfield(v, i), depth + 1)
        isnothing(inner) || return inner
    end
    return nothing
end

_is_ptr_type(@nospecialize(v)) = v isa Type && v <: Ptr && v !== Union{}

# The calls that take a pointer type only to name it: building another type from it
# (`Vector{Ptr{T}}`, `Union{Ptr{T}, Nothing}`), testing or asserting a type, its size, a field of
# the type object (`Ptr.body`), `cglobal`, which is reported by its own name, and the two
# conversions a `ccall` lowers its arguments through: `cconvert(Ptr{T}, addr)` returns the integer,
# and `unsafe_convert` is reported by its own name. Core has its own `sizeof`, `cconvert` and
# `unsafe_convert`, which code written with Core's names calls. Any other call handed a pointer
# type may apply it, as `map(Ptr{T}, addrs)`, `ntuple(Ptr{T}, n)`, `Base.Generator(Ptr{T}, addrs)`,
# a splat `Ptr{T}(xs...)` and a keyword call do, and lowered code carries no types to tell which,
# so it is reported. A comparison never reaches this.
const _PTR_NAMERS = (
    Core.apply_type, isa, Core.typeassert, <:, >:, sizeof, Core.sizeof, typeintersect, getfield,
    getproperty, cglobal, Base.cconvert, Base.unsafe_convert,
    (getglobal(Core, n) for n in (:cconvert, :unsafe_convert) if isdefined(Core, n))...,
)

# Whether a call hands a pointer type to a function that may apply it. `Ptr{T}[]` names the type
# for an empty vector, and `Ptr{T}[a, b]` converts each element to it.
function _ptr_applied(@nospecialize(callee), args::Vector{Any}, resolve)
    any(g -> g === callee, _PTR_NAMERS) && return false
    callee === getindex && length(args) == 2 && return false
    return any(a -> _is_ptr_type(resolve(a)), args[2:end])
end

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

# The function a lowered call names, resolved without inference: a `GlobalRef`, a constant,
# `M.name` on a module, which lowers to `getproperty(M, :name)` (or is written `getfield(M, :name)`)
# in a statement of its own, or a local that is assigned once and holds one of those.
function _lowered_callee(code::Vector{Any}, @nospecialize(a), depth::Int = 0)
    depth > 8 && return nothing
    a isa GlobalRef && return isdefined(a.mod, a.name) ? getglobal(a.mod, a.name) : nothing
    a isa QuoteNode && return a.value
    if a isa Core.SlotNumber
        # `B = Base; B.unsafe_load(p)` and `T = Ptr{Float64}; T(a)`. A local assigned more than
        # once holds no one value; where it is a module operand, `_lowered_modules` follows each
        # of its assignments.
        rhs = _single_assignment(code, a)
        return rhs === nothing ? a : _lowered_callee(code, rhs, depth + 1)
    end
    if Meta.isexpr(a, :call)
        # `M.name` written where a value is stored (`f = Base.unsafe_load`) is the call itself,
        # with no statement of its own.
        v = _lowered_global_read(code, a, depth)
        isnothing(v) || return v
        # `Ptr{T}` is `Core.apply_type(Ptr, T)`. The type it names is the one being
        # parameterized, which is all a caller needs to know it is a pointer type.
        if length(a.args) >= 2 && _lowered_callee(code, a.args[1], depth + 1) === Core.apply_type
            return _lowered_callee(code, a.args[2], depth + 1)
        end
        return nothing
    end
    a isa Core.SSAValue && return _lowered_callee(code, code[a.id], depth + 1)
    return a isa Expr ? nothing : a
end

# The right-hand side of the one assignment to a local, or `nothing` when there is none or
# several.
function _single_assignment(code::Vector{Any}, slot::Core.SlotNumber)
    rhs = nothing
    for st in code
        (Meta.isexpr(st, :(=)) && st.args[1] == slot) || continue
        isnothing(rhs) || return nothing
        rhs = st.args[2]
    end
    return rhs
end

# Whether a statement reads a global of a module by a name that is not written in the code. Which
# function that is cannot be read from the method, so it cannot be cleared either. `getglobal`
# reads nothing but a module; `getproperty` and `getfield` count only when their first operand
# is one, since on any other value they read a field.
function _dynamic_global_read(code::Vector{Any}, @nospecialize(s))
    (Meta.isexpr(s, :call) && length(s.args) >= 3) || return false
    reader = _lowered_callee(code, s.args[1], 1)
    reader in (getproperty, getfield, getglobal) || return false
    nm = s.args[3]
    (nm isa QuoteNode || nm isa Symbol) && return false
    (nm isa Core.SSAValue && code[nm.id] isa QuoteNode) && return false
    return reader === getglobal || !isempty(_lowered_modules(code, s.args[2]))
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

# Every module a value can be, for the module operand of `M.name`. A local assigned more than once
# can hold the value of each of its assignments, and a typed local (`M::Module = Base`) is assigned
# through `convert` and `typeassert`, which hand a module back unchanged.
function _lowered_modules(code::Vector{Any}, @nospecialize(a), seen::Set{Int} = Set{Int}(), depth::Int = 0)
    out = Module[]
    depth > 16 && return out
    if a isa Core.SlotNumber
        a.id in seen && return out
        push!(seen, a.id)
        for st in code
            (Meta.isexpr(st, :(=)) && st.args[1] == a) || continue
            append!(out, _lowered_modules(code, st.args[2], seen, depth + 1))
        end
        return out
    end
    a isa Core.SSAValue && return _lowered_modules(code, code[a.id], seen, depth + 1)
    if Meta.isexpr(a, :call) && length(a.args) == 3
        f = _lowered_callee(code, a.args[1])
        f === convert && return _lowered_modules(code, a.args[3], seen, depth + 1)
        f === Core.typeassert && return _lowered_modules(code, a.args[2], seen, depth + 1)
    end
    v = _lowered_callee(code, a)
    v isa Module && push!(out, v)
    return out
end

# Every value `M.name` can read, one per module `M` can be: `getproperty(M, :name)`,
# `getfield(M, :name)` or `getglobal(M, :name)`.
function _lowered_global_reads(code::Vector{Any}, @nospecialize(s))
    out = Any[]
    (Meta.isexpr(s, :call) && length(s.args) == 3) || return out
    _lowered_callee(code, s.args[1], 1) in (getproperty, getfield, getglobal) || return out
    nm = s.args[3] isa QuoteNode ? s.args[3].value : s.args[3]
    nm isa Symbol || return out
    for M in _lowered_modules(code, s.args[2])
        isdefined(M, nm) && push!(out, getglobal(M, nm))
    end
    return out
end

function _scan_unsafe!(out::Set{Symbol}, ci::Core.CodeInfo, resolve)
    # One finding per method, so the span an `@inbounds` block covers does not matter: a bare
    # `@inbounds a[i]` flags one statement and `@inbounds for …` flags most of the loop, and both
    # mean the same thing about this method.
    any(fl -> !iszero(fl & _IR_FLAG_INBOUNDS), ci.ssaflags) && push!(out, :inbounds)
    note(@nospecialize(v)) = (nm = _unsafe_function(v); isnothing(nm) || push!(out, nm); nothing)
    # A value used by name, and when it is `M.name` with `M` a local that can hold several
    # modules, the global of each.
    function noteval(@nospecialize(a))
        note(resolve(a))
        foreach(note, _lowered_global_reads(ci.code, a isa Core.SSAValue ? ci.code[a.id] : a))
        return nothing
    end
    dynamic(@nospecialize(s)) = _dynamic_global_read(ci.code, s)
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
            (named(st) || Meta.isexpr(st, :call)) && noteval(st)
        end
        if st isa Core.ReturnNode
            isdefined(st, :val) && named(st.val) && noteval(st.val)
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
        dynamic(st) && push!(out, :dynamic_global)
        callee = resolve(st.args[1])
        # Comparing a value with an unsafe function hands the function to nothing.
        (callee === (===) || callee === (!==) || callee === (==) || callee === (!=) || callee === isequal) && continue
        # The method table a call goes through does not make the call unsafe, so the function a
        # keyword call, a splat, a broadcast or a `map` is handed counts as much as a callee.
        for a in st.args
            named(a) && noteval(a)
        end
        _ptr_applied(callee, st.args, resolve) && push!(out, :Ptr)
        # Arithmetic on a pointer constant, `C_NULL + addr`, makes a pointer from an integer.
        (callee === (+) || callee === (-)) && any(a -> resolve(a) isa Ptr, st.args[2:end]) && push!(out, :Ptr)
        isnothing(callee) && continue
        if _is_ptr_type(callee)
            push!(out, :Ptr)
        elseif callee isa Core.Builtin && length(st.args) >= 3 && st.args[end] === false
            nm = nameof(callee)
            # `getfield(x, i, false)` and `getfield(x, i, order, false)` both take the flag last;
            # with two operands the last one is the field.
            nm in _UNCHECKED_BUILTINS && !(nm === :getfield && !(length(st.args) in (4, 5))) && push!(out, nm)
        end
    end
    return out
end

# Scan generated method `m`'s code at signature `sig` into `out`; `false` when there is none to
# read. A generator that raises, or one that needs types `sig` leaves free, yields no `CodeInfo`.
function _generated_constructs!(out::Set{Symbol}, m::Method, @nospecialize(sig))
    cis = try
        _code_typed_by_type(sig; optimize = false)
    catch
        return false
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
    return read
end

# The unsafe constructs in one method's body, as a sorted, deduplicated list of names. `ccall`
# stands for a `:foreigncall` statement, which is what a `ccall` becomes.
#
# Read from the method's LOWERED code, which is what it wrote: every construct here is visible
# there, and reading it runs no inference. Inferring at the method's declared signature cost
# seconds on a large generic kernel, and for an abstract signature it returned the code of every
# method matching it, so a generic method was charged with the `@inbounds` and `unsafe_*` calls of
# its more specific siblings. A `@generated` method has no lowered body of its own and is inferred,
# keeping only its own result: at its declared signature, or at each compiled specialization when
# the generator needs the argument types.
#
# `nothing` when the method's code cannot be read: a generator that raises or has not run for any
# types yet, or a method that keeps no source. That is not an empty list, which says the method was
# read and is clean.
function _unsafe_constructs(m::Method)
    out = Set{Symbol}()
    if isdefined(m, :generator)
        # Julia runs a generator at the declared signature only when it does not use the type
        # parameters left free there. Otherwise the code exists per argument types, and each
        # specialization compiled so far is read; every one must read, or the method was not.
        if !_generated_constructs!(out, m, m.sig)
            # Reading at `m.sig` itself leaves an instance at that signature, with no code.
            specs = filter(mi -> Base.isdispatchtuple(mi.specTypes), _specializations(m))
            isempty(specs) && return nothing
            for mi in specs
                _generated_constructs!(out, m, mi.specTypes) || return nothing
            end
        end
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
uses any of these. Constructors, top-level anonymous functions and callables with no name of their
own are read like every other method.

| construct | reported as |
|---|---|
| a `ccall` or `@ccall` | `:ccall` |
| `@cfunction` | `:cfunction` |
| `@inbounds` | `:inbounds` |
| `pointer`, `pointer_from_objref`, and any function whose name begins with `unsafe_` | its name |
| the pointer intrinsics `pointerref`, `pointerset`, `atomic_pointer…`, and `llvmcall`, `cglobal` | its name |
| `Libc.malloc`, `calloc`, `realloc`, `free`, `memcpy`, `memmove`, `memset`, `memcmp` | its name |
| a pointer made from an integer: `Ptr{T}(addr)`, `Ptr{T}` handed to any call that may apply it (`reinterpret(Ptr{T}, addr)`, `convert(Ptr{T}, addr)`, `map(Ptr{T}, addrs)`, `ntuple(Ptr{T}, n)`, `Ptr{T}(xs...)`, `Ptr{T}[addr]`), or arithmetic on a pointer constant (`C_NULL + addr`) | `:Ptr` |
| `memoryrefnew`, `memoryrefget`, `memoryrefset!` or `getfield` with a literal `false` bounds check | its name |
| a global of a module read by a name that is a run-time value: `getglobal(M, nm)`, `getproperty(Base, nm)` | `:dynamic_global` |
| code evaluated at run time: `eval`, `@eval`, `Core.eval`, `include_string`, `include`, whether called or passed on | `:eval` |

A function counts wherever the method names it, not only where it calls it: `map(unsafe_load, ps)`,
`unsafe_load.(ps)`, `unsafe_load(args...)`, `unsafe_wrap(Array, p, n; own = false)` and
`f = unsafe_load; f(p)` are all reported as `unsafe_load` or `unsafe_wrap`. The name may be
qualified or looked up: `f = Base.unsafe_load` and `getglobal(Base, :unsafe_load)(p)` name it too, and so does a
callable constant holding it, `const LOAD1 = Base.Fix2(unsafe_load, 1); LOAD1(p)`. A pointer type
kept in a local that is assigned once is followed, `T = Ptr{Float64}; T(addr)`, and so is a module
kept in a local to every module it is assigned, typed or not: `B = Base; B.unsafe_load(p)` and
`M = Core; c && (M = Base); M.unsafe_load(p)` are reported. A lookup whose name is not written in the code,
`getglobal(Base, nm)`, cannot be resolved to a function, so it is reported as `dynamic_global`
instead of passing. Comparing a value with
one (`f === unsafe_load`) is not. The C allocator is matched by identity, so a package's own
function named `free` is not `Libc.free`. A pointer type is reported as an operand of any call
other than one that only names it, since lowered code carries no types to tell a call that applies
it (`map(Ptr{T}, addrs)`, `Ptr{T}.(addrs)`, `ntuple(Ptr{T}, n)`, `Base.Generator(Ptr{T}, addrs)`,
`addr |> Ptr{T}`, a splat, a keyword call, a tuple that is applied later) from one that does not.
The calls that only name it are building another type (`Vector{Ptr{T}}`, `Ref{Ptr{Cvoid}}`,
`Union{Ptr{T}, Nothing}`), `isa`, a type assertion, `<:`, `>:`, a comparison, `sizeof`,
`typeintersect`, a field of the type object, `cglobal`, the `ccall` conversions `cconvert` and
`unsafe_convert`, and the empty typed literal `Ptr{T}[]`; `Ptr{T}[addr]` converts `addr` and is
reported. Taking a `Ptr` argument builds no pointer and is not reported, and neither is arithmetic
on one (`p + 8`): only arithmetic on a pointer constant such as `C_NULL` is, since the scan cannot
tell a pointer argument from an integer in lowered code.
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

A `@generated` method has no lowered body. It is read at its declared signature when its generator
does not use the argument types, and otherwise at each specialization compiled so far, so the
types it is read for are the ones it has been called with. Before its first call such a method is a
`:fail` finding saying its code could not be read.

Read from each method's own lowered code on purpose. A small wrapper around a pointer load inlines
under optimization, so its `unsafe_load` would surface in an innocent caller and vanish from the
method that actually wrote it. Lowered code needs no inference, so the scan is cheap on any module.
"""
function unsafe_report(mod::Module; only = nothing, exempt = (), allow = ())
    allowed = _check_allow(allow)
    out = StrictFinding[]
    # A constructor, a top-level lambda and a callable with no name are code like any other; the
    # census leaves them out only because no declaration can name them. A keyword method's
    # `Core.kwcall` entry stays out: it forwards to the body, and the default values it evaluates
    # are evaluated by the positional method too, which is read.
    methods_, _ = module_methods(mod; only, exempt, keep = (:constructor, :closure, :unreadable))
    for m in methods_
        found = _unsafe_constructs(m)
        if isnothing(found)
            push!(
                out, _unevaluated(
                    nameof(mod), string(m.name), string(m.sig), :unsafe,
                    "the method's code could not be read, so it was not checked for constructs " *
                        "that leave Julia's safety guarantees" *
                        (
                        isdefined(m, :generator) ?
                            ". A `@generated` method whose generator needs its argument types " *
                            "is read at each compiled specialization: call it first" : ""
                    );
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
