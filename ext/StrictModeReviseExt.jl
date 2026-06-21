# Live human feedback: after each Revise edit, re-check the strict registry and print any
# violations to the REPL — the "compiler shouts as you code" loop. Loaded automatically when both
# StrictMode and Revise are present. The agent-facing counterpart is `StrictMode.audit`.

module StrictModeReviseExt

using StrictMode
using Revise

const _KEY = Ref{Any}(nothing)

# Runs after each revision (Revise invokes user callbacks with no arguments).
function _on_revision()
    StrictMode.checks_enabled() || return nothing
    isempty(StrictMode.registered_strict()) && return nothing
    fs = StrictMode.check_all(; fail = :none)
    failed = filter(f -> f.status === :fail, fs)
    isempty(failed) || StrictMode.format_findings(stdout, failed; format = :text)
    return nothing
end

function _start_watch()
    StrictMode.checks_enabled() ||
        @info "StrictMode.watch: checks are disabled — run `StrictMode.enable_checks!()` (and restart) first."
    StrictMode.backend_available() ||
        @warn "StrictMode.watch: the analysis backend isn't loaded — `using AllocCheck, JET` so the re-checks can run."
    # `all = true` fires the callback before the next REPL command after *any* tracked edit.
    _KEY[] = Revise.add_callback(String[]; all = true, key = :strictmode_watch) do
        _on_revision()
    end
    @info "StrictMode: watching — strict methods are re-checked after each edit. `unwatch()` to stop."
    return _KEY[]
end

function _stop_watch()
    _KEY[] === nothing && return nothing
    Revise.remove_callback(_KEY[])
    _KEY[] = nothing
    @info "StrictMode: stopped watching."
    return nothing
end

function __init__()
    StrictMode._REVISE_WATCH[] = _start_watch
    StrictMode._REVISE_UNWATCH[] = _stop_watch
    return nothing
end

end # module StrictModeReviseExt
