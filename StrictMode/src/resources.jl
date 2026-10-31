# Where a registered resource, or something borrowed from one, leaves the scope that owns it.
#
# `@assert_noescape` already answers CONFINEMENT for a handle created in a frame: the compiler's
# escape analysis says whether it provably cannot leave. This asks the complementary question, and
# a narrower one — not "is release proved on every path", which needs post-dominance over the
# exception CFG and breaks the moment a `close` sits in a helper, but "does this body hand the
# resource somewhere it will outlive its owner". Those shapes are visible in the IR:
#
#   - it is RETURNED, so the caller holds a borrow whose owner may be gone;
#   - it is STORED into something that is not itself a registered resource, so the reference
#     outlives this frame through a container nobody scoped;
#   - it is CAPTURED BY A TASK, which keeps it alive past the frame and shares it besides.
#
# The last one needs the same `jl_new_task` crossing the concurrency scan uses, which is why the two
# live next to each other conceptually even though the questions differ.
#
# Deliberately NOT a proof of release, and `:info` because of it: a resource handed to a callee this
# scan cannot follow reads as not leaked, exactly as a guard inside such a callee reads as absent in
# `alias_guard_report`. Finding a leak is evidence; finding none is a lead.

# Does this statement's inferred type carry a registered scoped value, or something projected out of
# one? Projection is tracked because the borrow — `ws.buffer` — is what escapes, not the workspace.
function _resource_taint!(tset::BitSet, ci, i::Int, st, types)
    _op_tainted_res(a) = (a isa Core.SSAValue && a.id in tset) ||
        (a isa Core.Argument && _is_scoped_type(_arg_type(ci, a)))
    T = (1 <= i <= length(types)) ? types[i] : nothing
    _is_scoped_type(T) && return push!(tset, i)
    callee, args = _call_callee_and_args(ci, st)
    if !isnothing(callee)
        nm = try
            nameof(callee)
        catch
            nothing
        end
        if nm isa Symbol && (haskey(_PROJECT_OPS, nm) || nm in _CARRY_OPS)
            pos = get(_PROJECT_OPS, nm, 0)
            if iszero(pos)
                any(_op_tainted_res, args) && push!(tset, i)
            elseif 1 <= pos <= length(args) && _op_tainted_res(args[pos])
                push!(tset, i)
            end
        end
        return tset
    end
    Meta.isexpr(st, :new) && any(_op_tainted_res, @view st.args[2:end]) && push!(tset, i)
    return tset
end

# The declared type of an argument slot, for the seed above.
function _arg_type(ci, a::Core.Argument)
    slots = ci.slottypes
    return (slots isa Vector && 1 <= a.n <= length(slots)) ? slots[a.n] : nothing
end

"""
    resource_leak_report(mod::Module; only = nothing, exempt = ()) -> Vector{StrictFinding}

Methods in `mod` that let a registered resource — or a value borrowed out of one — leave the scope
that owns it. Every finding is `:info`. Register the owning type first with
[`register_scoped!`](@ref); with nothing registered this reports nothing.

Rust releases a resource when its owner goes out of scope. Julia hands the decision to the garbage
collector, which runs at a time nobody chose — and for a GPU buffer or a file handle that is not a
performance question: the CPU collector cannot see GPU memory pressure at all.

Three shapes are reported, and all three are about a reference outliving its owner rather than about
release:

- **returned** — the caller receives a borrow whose owner may already be gone.
- **stored** into something that is not itself a registered resource, so the reference escapes
  through a container nobody scoped.
- **captured by a task**, which both outlives the frame and shares the resource.

This is the complement of [`@assert_noescape`](@ref), which proves CONFINEMENT for a handle created
in a frame and says nothing about one that arrives as an argument. Neither subsumes the other.

**It does not prove release on every path.** That needs post-dominance over the exception control
flow, and a `close` inside a helper defeats it, so this reports the shapes that are visible instead
of failing to prove the property that is not. And it is `:info` for the same reason
[`alias_guard_report`](@ref) is: a resource handed to a callee this scan cannot follow reads as not
leaked, so a finding is evidence and an empty report is a lead.

```julia
register_scoped!(Workspace)
resource_leak_report(MyPkg)                       # every escape shape
resource_leak_report(MyPkg; only = r"^kernel_")   # one family
```

Judged on the concrete signatures a method has **compiled**, like [`bang_report`](@ref), so warm
the kernels first — a method with no specialization is skipped rather than guessed at. That is the
opposite of [`alias_guard_report`](@ref), which reads the declared signature and so covers a method
nothing has called.
"""
function resource_leak_report(mod::Module; only = nothing, exempt = ())
    out = StrictFinding[]
    isempty(_SCOPED_TYPES) && return out
    methods_, _ = module_methods(mod; only, exempt)
    for m in methods_
        sigs = _method_signatures(m)
        isempty(sigs) && continue
        f = try
            _method_function(m).instance
        catch
            continue
        end
        shapes = Set{String}()
        for tt in sigs
            union!(shapes, _resource_escapes(f, Tuple(tt)))
        end
        isempty(shapes) && continue
        push!(
            out,
            StrictFinding(
                nameof(mod), string(m.name), string(m.sig), :resource, :info,
                string(m.file), Int(m.line),
                "lets a registered resource outlive the scope that owns it: " *
                    join(sort!(collect(shapes)), ", "),
                "hand back a value rather than the handle, or give the resource an owner that is " *
                    "itself registered. A resource passed to a callee this scan could not follow " *
                    "reads as not leaked, so an empty report is a lead rather than a proof",
                :report
            )
        )
    end
    return out
end

# The escape shapes present in one signature's optimized IR, as readable names.
function _resource_escapes(@nospecialize(f), @nospecialize(types::Tuple))
    shapes = Set{String}()
    cts = try
        Base.code_typed(f, types; optimize = true)
    catch
        return shapes
    end
    isempty(cts) && return shapes
    ci = cts[1].first
    code = ci.code
    types_ = ci.ssavaluetypes
    tset = BitSet()
    # Taint reaches forward, so a fixed point costs at most one pass per statement.
    for _ in 1:(length(code) + 1)
        before = length(tset)
        for (i, st) in enumerate(code)
            _resource_taint!(tset, ci, i, st, types_)
        end
        length(tset) == before && break
    end
    tainted(a) = (a isa Core.SSAValue && a.id in tset) ||
        (a isa Core.Argument && _is_scoped_type(_arg_type(ci, a)))
    for st in code
        if st isa Core.ReturnNode
            isdefined(st, :val) && tainted(st.val) && push!(shapes, "returned")
            continue
        end
        if Meta.isexpr(st, :foreigncall) && _fcall_name(st) === :jl_new_task
            any(tainted, @view st.args[6:end]) && push!(shapes, "captured by a task")
            continue
        end
        callee, args = _call_callee_and_args(ci, st)
        isnothing(callee) && continue
        nm = try
            nameof(callee)
        catch
            continue
        end
        nm isa Symbol && haskey(_STORE_OPS, nm) || continue
        pos = _STORE_OPS[nm]
        # The CONTAINER is the store's target; the value is whatever follows it. Storing a resource
        # into another registered resource is ownership, not a leak — that is the workspace pattern.
        (1 <= pos <= length(args)) || continue
        tainted(args[pos]) && continue
        any(tainted, @view args[(pos + 1):end]) && push!(shapes, "stored outside a scoped owner")
    end
    return shapes
end
