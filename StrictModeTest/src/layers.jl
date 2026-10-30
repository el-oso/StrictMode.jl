# Julia has no orphan rule. Any module may add a method to any function for any type, and the
# language is right not to forbid it — extending `Base.show` for your own type is how the ecosystem
# composes. What the language cannot know is a project's intended direction of dependency: that the
# kernel layer must not reach up into the application layer, and that two sibling layers must not
# extend each other. That is a declaration, so this takes one.
#
# Only modules named in the declaration are judged. An access to Base, Core, or a package outside
# the graph is out of scope here — measured on StrictMode itself, `improper_qualified_accesses`
# returns 66 rows, essentially all of them deliberate reads of Base and Core internals that this
# package exists to do. Judging those would bury the layer violations the declaration is about.
# ExplicitImports' own `check_*` functions are the right tool for that wider question.

# The declared graph, normalized: each layer mapped to the set it may extend. A layer that names
# itself is harmless and a layer missing from the graph is not judged at all, so the graph is also
# the opt-in.
function _layer_graph(pairs)
    graph = Dict{Module, Set{Module}}()
    for p in pairs
        p isa Pair || throw(
            ArgumentError("test_layers: each argument must be `Layer => (deps…)`, got $(typeof(p))")
        )
        layer, allowed = p
        layer isa Module ||
            throw(ArgumentError("test_layers: the left of each pair must be a Module, got $(repr(layer))"))
        set = Set{Module}()
        for a in (allowed isa Module ? (allowed,) : allowed)
            a isa Module ||
                throw(ArgumentError("test_layers: `$layer` may only name Modules, got $(repr(a))"))
            push!(set, a)
        end
        haskey(graph, layer) &&
            throw(ArgumentError("test_layers: `$layer` is declared twice"))
        graph[layer] = set
    end
    isempty(graph) && throw(ArgumentError("test_layers: no layers declared, so nothing is checked"))
    return graph
end

# Which declared layer a module belongs to: itself, or the layer it sits beneath. A submodule
# answers to its layer's declaration rather than escaping it.
function _owning_layer(graph, mod::Module)
    haskey(graph, mod) && return mod
    for layer in keys(graph)
        StrictMode._in_module_tree(mod, layer) && return layer
    end
    return nothing
end

# Rule 1: a method written in one layer may only extend a function owned by a layer that layer
# declared it may see.
function _extension_findings!(out, graph, layer::Module)
    allowed = graph[layer]
    methods_, _ = StrictMode.module_methods(layer; include_exempt = true)
    for m in methods_
        f = try
            StrictMode._method_function(m).instance
        catch
            continue                      # no singleton instance: nothing owns it to check
        end
        owner = _owning_layer(graph, parentmodule(f))
        (isnothing(owner) || owner === layer || owner in allowed) && continue
        push!(
            out,
            StrictMode._mkfinding(
                nameof(layer), string(m.name), string(m.sig), :layer, true,
                "`$(nameof(layer))` adds a method to `$(nameof(owner)).$(m.name)`, and " *
                    "`$(nameof(layer))` does not declare `$(nameof(owner))` among the layers it " *
                    "may see",
                string(m.file), Int(m.line),
                "move the method into `$(nameof(owner))`, or into a layer that may see it — or " *
                    "add `$(nameof(owner))` to `$(nameof(layer))`'s declared dependencies if the " *
                    "direction is intended";
                tier = :proof
            )
        )
    end
    return out
end

# Rule 2: no layer may read a non-public name of another layer, whatever the declared direction.
# A public name is the layer's interface; anything else is its implementation.
function _access_findings!(out, graph, layer::Module)
    # The package entry file, not the layer's own: a submodule has no `pathof`, and the analysis
    # walks down from the root anyway — the rows it returns are keyed by module, which is what the
    # filter below selects on.
    path = pathof(Base.moduleroot(layer))
    isnothing(path) && return out         # not inside a package: nothing on disk to parse
    rows = try
        ExplicitImports.improper_qualified_accesses(layer, path)
    catch err
        throw(AnalysisError(string(nameof(layer)), "(module)", err))
    end
    for (mod, accesses) in rows
        _owning_layer(graph, mod) === layer || continue
        for a in accesses
            a.public_access && continue
            a.self_qualified && continue
            target = _owning_layer(graph, a.accessing_from)
            (isnothing(target) || target === layer) && continue
            push!(
                out,
                StrictMode._mkfinding(
                    nameof(layer), string(a.name), string(nameof(a.accessing_from)), :layer, true,
                    "`$(nameof(layer))` reads `$(nameof(a.accessing_from)).$(a.name)`, which " *
                        "`$(nameof(a.accessing_from))` does not declare public",
                    a.location, 0,
                    "use a name `$(nameof(a.accessing_from))` marks `public` or `export`, or move " *
                        "what you need into its interface — an implementation detail you reach " *
                        "around is one that cannot be changed without breaking you";
                    tier = :proof
                )
            )
        end
    end
    return out
end

function _layer_findings(pairs)
    graph = _layer_graph(pairs)
    out = StrictMode.StrictFinding[]
    for layer in sort!(collect(keys(graph)); by = m -> string(nameof(m)))
        _extension_findings!(out, graph, layer)
        _access_findings!(out, graph, layer)
        any(f -> f.mod === nameof(layer), out) ||
            push!(out, StrictMode._mkfinding(nameof(layer), "", "", :layer, false, "", "", 0; tier = :proof))
    end
    return out
end

"""
    test_layers(Layer => (deps...), ...) -> Vector{StrictFinding}

Prove that a declared layer graph holds, and throw a `StrictMode.StrictViolation` collecting every
violation.

Julia has no orphan rule, and should not: extending `Base.show` for your own type is how the
ecosystem composes. What the language cannot know is a project's intended **direction of
dependency** — that the kernel layer must not reach up into the application layer, that two sibling
layers must not extend each other. Declare it and this checks it.

```julia
test_layers(
    App    => (Engine, Kernel),
    Engine => (Kernel,),
    Kernel => (),
)
```

Two rules:

1. **Extension follows the declaration.** A method written in one layer may only extend a function
   owned by a layer that layer declared. `Engine` adding a method to `Kernel.area` is fine above;
   `Kernel` adding one to `Engine.spin` is not, and neither is a sibling reaching across.
2. **No layer reads another layer's implementation.** A qualified access to a name the owning layer
   does not mark `public` or `export` is a violation whichever way the declaration points. A public
   name is the interface; anything else cannot be changed without breaking the reader.

**Only the declared modules are judged.** A call into Base, Core, or a package outside the graph is
out of scope — measured on StrictMode itself, the underlying analysis returns 66 improper accesses,
essentially all of them deliberate reads of Base and Core internals that this package exists to
perform. Judging those would bury the layer violations the declaration is about. For that wider
question use `ExplicitImports.check_all_qualified_accesses_are_public` and its siblings directly;
this is deliberately the narrower check.

A module missing from the graph is not judged, so the graph is also the opt-in. A submodule answers
to the layer it sits beneath rather than escaping the declaration.

The extension rule reads the method census, so it sees a method on a foreign function even though
its name is bound elsewhere; the access rule parses the layer's source, so a layer with no file on
disk contributes no access findings.
"""
test_layers(pairs::Pair...) = _test_layers(pairs)
test_layers(graph::AbstractDict) = _test_layers(collect(graph))

function _test_layers(pairs)
    fs = _layer_findings(pairs)
    failed = filter(StrictMode._failed, fs)
    isempty(failed) && return fs
    msg = sprint(io -> StrictMode.format_findings(io, failed; format = :text))
    throw(StrictMode.StrictViolation(:test_layers, "layer graph", msg))
end
