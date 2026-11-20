@testitem "checks are enabled in the test environment" begin
    using StrictMode, StrictModeTest
    @test StrictMode.checks_enabled() === true
end

@testitem "assert_enabled: errors under CI when disabled, skippable locally" begin
    using StrictMode
    # Pure-core truth table.
    @test StrictMode._assert_enabled(true, false) === true
    @test StrictMode._assert_enabled(true, true) === true
    @test StrictMode._assert_enabled(false, false) === false
    @test_throws ErrorException StrictMode._assert_enabled(false, true)
    # Public entry point in this env (checks baked on): true regardless of CI.
    @test assert_enabled() === true
end

@testitem "_gate selects the branch by compile-time flag" begin
    using StrictMode
    expected = StrictMode.checks_enabled() ? :checked : :bare
    @test StrictMode._gate(:checked, :bare) === expected
end

@testitem "enabled macros wrap the call (not the bare expression)" begin
    using StrictMode
    ex = @macroexpand @assert_noalloc identity(1)
    # With checks on, the expansion must be more than just `identity(1)`.
    @test !(ex isa Expr && ex.head === :call && ex.args[1] === :identity)
end

@testitem "assert_enabled is loud when StrictModeTest is declared but never loaded" begin
    using StrictMode
    # A package can be LISTED as a dependency and never `using`ed. Then every guarantee runs on the
    # value-free scan while the environment advertises the proofs, and none of the `test_*` gates
    # exist to be called. The pure core is tested directly so this needs no filesystem or
    # environment fixture.

    @test StrictMode._assert_enabled(true, false, false) === true      # checks on, nothing declared
    @test StrictMode._assert_enabled(true, true, false) === true       # …same under CI
    @test_throws ErrorException StrictMode._assert_enabled(true, false, true)
    @test_throws ErrorException StrictMode._assert_enabled(true, true, true)
    # Checks OFF short-circuits first: there is no point complaining about which engine would run
    # when no engine runs at all.
    @test StrictMode._assert_enabled(false, false, true) === false
    @test_throws ErrorException StrictMode._assert_enabled(false, true, true)   # the CI rule still wins

    # And the detector itself must be quiet in this environment, where StrictModeTest IS loaded.
    @test StrictMode.proofs_loaded()
    @test !StrictMode._backend_declared_but_unloaded()
    @test StrictMode.assert_enabled()
end

@testitem "a checks-off session under CI announces itself" begin
    using StrictMode
    # `assert_enabled()` is the guard for the silent-skip failure mode, and it only fires in a suite
    # that remembers to call it — which, in this tree, is exactly one caller. The load banner covers
    # the suites that do not: with checks off and CI set, staying quiet would let a green run mean
    # nothing at all. Driven in a subprocess because the state under test is a precompile-baked
    # const plus an environment variable.
    script = """
    using StrictMode
    print(stdout, "LOADED ", StrictMode.checks_enabled())
    """
    run_with(env) = begin
        out, err = IOBuffer(), IOBuffer()
        cmd = setenv(
            `$(Base.julia_cmd()) --project=$(Base.active_project()) --startup-file=no -e $script`,
            merge(ENV, env)
        )
        p = run(pipeline(cmd; stdout = out, stderr = err); wait = false)
        wait(p)
        (String(take!(out)), String(take!(err)))
    end
    # Checks ARE enabled in this environment, so the disabled-path banner must stay silent —
    # otherwise the assertion below would pass for any input at all.
    _, err_on = run_with(Dict("CI" => "true"))
    @test !occursin("checks are DISABLED", err_on)
    @test occursin("checks ENABLED", err_on)
end

@testitem "issue #28: the load banner is trim-safe and printf-safe" begin
    using StrictMode
    # `_eprint` passes its message as `jl_safe_printf`'s FORMAT string, with no variadic arguments:
    # a `ccall` signature naming an extra argument describes a non-variadic call, which x86-64 SysV
    # tolerates and the AArch64 Apple ABI does not — that segfaulted every macOS job at
    # `using StrictMode`. The cost of passing no varargs is that a `%` in the text would be read as
    # a format specifier, so the banners must not contain one.
    @test !occursin('%', StrictMode._BANNER_REPORTING)
    @test !occursin('%', StrictMode._BANNER_CI_DISABLED)

    # Both are non-empty and end in a newline: a format string without one runs the next line of
    # output into the banner.
    for b in (StrictMode._BANNER_REPORTING, StrictMode._BANNER_CI_DISABLED)
        @test !isempty(b)
        @test endswith(b, '\n')
    end

    # And it really does write — a no-op writer would satisfy everything above.
    @test isnothing(StrictMode._eprint(""))
end

@testitem "the tier banner reaches only a direct dependent" begin
    using StrictMode
    # A library that uses StrictMode in its own `src` would otherwise announce the tier to everyone
    # who types `using ThatLibrary` — about a tool they did not choose and cannot silence from
    # their own project. The banner is gated on StrictMode appearing in the ACTIVE project file.
    proj = joinpath(pkgdir(StrictMode), "Project.toml")
    @test occursin(StrictMode.UUID_STRING, read(proj, String))

    # This environment names StrictMode, so the banner path stays live where it is meant to be.
    # Under `Pkg.test` the sandbox arrives on `LOAD_PATH` with no active project set, which is why
    # the search covers the load path as well as `Base.ACTIVE_PROJECT`.
    @test StrictMode.direct_dependency()

    # A project that does not name it is silent, and an unreadable one counts as "not named"
    # rather than falling back to noise. `Base.ACTIVE_PROJECT` holds whatever `--project` was
    # given, so both the file and the containing directory have to resolve.
    mktempdir() do dir
        file = joinpath(dir, "Project.toml")
        oldproj, oldload, olddepot = Base.ACTIVE_PROJECT[], copy(Base.LOAD_PATH), copy(Base.DEPOT_PATH)
        try
            # Point the other two sources at nothing, so only the project under test can answer.
            empty!(Base.LOAD_PATH)
            push!(Base.LOAD_PATH, "@")
            empty!(Base.DEPOT_PATH)
            push!(Base.DEPOT_PATH, joinpath(dir, "depot"))

            write(file, "[deps]\n")
            for p in (file, dir)
                Base.set_active_project(p)
                @test !StrictMode.direct_dependency()
            end
            write(file, "[deps]\nStrictMode = \"$(StrictMode.UUID_STRING)\"\n")
            for p in (file, dir)
                Base.set_active_project(p)
                @test StrictMode.direct_dependency()
            end
            Base.set_active_project(joinpath(dir, "does_not_exist", "Project.toml"))
            @test !StrictMode.direct_dependency()

            # The `Pkg.test` shape: no active project, the sandbox on `LOAD_PATH`.
            push!(Base.LOAD_PATH, dir)
            @test StrictMode.direct_dependency()
        finally
            Base.set_active_project(oldproj)
            empty!(Base.LOAD_PATH)
            append!(Base.LOAD_PATH, oldload)
            empty!(Base.DEPOT_PATH)
            append!(Base.DEPOT_PATH, olddepot)
        end
    end
end

@testitem "a preference key StrictMode does not read is reported at load" begin
    using StrictMode

    mktempdir() do dir
        oldproj, oldload = Base.ACTIVE_PROJECT[], copy(Base.LOAD_PATH)
        try
            empty!(Base.LOAD_PATH)
            push!(Base.LOAD_PATH, "@")
            Base.set_active_project(joinpath(dir, "Project.toml"))
            write(joinpath(dir, "Project.toml"), "[deps]\n")

            # Nothing set, and the two keys StrictMode reads: nothing to report.
            @test isempty(StrictMode.unknown_preferences())
            prefs = joinpath(dir, "LocalPreferences.toml")
            write(prefs, "[StrictMode]\nchecks_enabled = true\nbanner = false\n")
            @test isempty(StrictMode.unknown_preferences())

            # A misspelled key is ignored by Preferences.jl, so checks stay on. It is named, with
            # its file. Another package's table is not StrictMode's to judge.
            write(prefs, "[Other]\ncheck_enabled = 1\n\n[StrictMode]\n# a comment\ncheck_enabled = false\n\"baner\" = false\nbanner = true\n\n[Later]\nx = 1\n")
            unknown = StrictMode.unknown_preferences()
            @test unknown == ["check_enabled ($prefs)", "baner ($prefs)"]

            # The project file's own table, and a path on `LOAD_PATH` (the `Pkg.test` shape).
            rm(prefs)
            write(joinpath(dir, "Project.toml"), "[deps]\n\n[preferences.StrictMode]\nchecks_enable = false\n")
            @test StrictMode.unknown_preferences() == ["checks_enable ($(joinpath(dir, "Project.toml")))"]
            Base.set_active_project(nothing)
            @test isempty(StrictMode.unknown_preferences())
            push!(Base.LOAD_PATH, dir)
            @test length(StrictMode.unknown_preferences()) == 1

            # What the load prints. The writer goes to the C `stderr`, so it is read back from a
            # file the descriptor is pointed at.
            out = joinpath(dir, "stderr.txt")
            open(out, "w") do io
                redirect_stderr(io) do
                    StrictMode._warn_unknown_preferences()
                    Libc.flush_cstdio()
                end
            end
            printed = read(out, String)
            @test occursin("StrictMode: unknown preference checks_enable (", printed)
            @test occursin("StrictMode reads `checks_enabled` and `banner`", printed)

            # `banner = false` hides the tier banner and nothing else: a misspelled key is
            # reported whatever the banner is set to, so the warning reads no banner setting.
            reads_banner(@nospecialize(x)) = x isa GlobalRef ? x.name === :BANNER_ENABLED :
                x isa Expr ? any(reads_banner, x.args) : false
            warn_code = only(Base.code_lowered(StrictMode._warn_unknown_preferences, ())).code
            tier_code = only(Base.code_lowered(StrictMode._announce_tier, ())).code
            @test !any(reads_banner, warn_code)
            @test any(reads_banner, tier_code)
            # The note is a format string for the writer, so it holds no `%`.
            @test !occursin('%', StrictMode._UNKNOWN_PREFERENCE_NOTE)
        finally
            Base.set_active_project(oldproj)
            empty!(Base.LOAD_PATH)
            append!(Base.LOAD_PATH, oldload)
        end
    end
end

@testitem "unknown_preferences searches the shared environments" begin
    using StrictMode

    mktempdir() do dir
        oldproj, oldload, olddepot = Base.ACTIVE_PROJECT[], copy(Base.LOAD_PATH), copy(Base.DEPOT_PATH)
        try
            # No project active: the default environment is the one Preferences.jl reads, and a
            # named shared environment on `LOAD_PATH` is read as well.
            default = joinpath(dir, "depot", "environments", StrictMode._DEFAULT_ENV)
            named = joinpath(dir, "depot", "environments", "tools")
            for (env, key) in ((default, "check_enabled"), (named, "baner"))
                mkpath(env)
                write(joinpath(env, "Project.toml"), "[deps]\n")
                write(joinpath(env, "LocalPreferences.toml"), "[StrictMode]\n$key = false\n")
            end
            empty!(Base.DEPOT_PATH)
            push!(Base.DEPOT_PATH, joinpath(dir, "depot"))
            empty!(Base.LOAD_PATH)
            append!(Base.LOAD_PATH, ["@", "@v#.#", "@tools", "@stdlib"])
            Base.set_active_project(nothing)
            @test StrictMode.unknown_preferences() == [
                "check_enabled ($(joinpath(default, "LocalPreferences.toml")))",
                "baner ($(joinpath(named, "LocalPreferences.toml")))",
            ]
        finally
            Base.set_active_project(oldproj)
            empty!(Base.LOAD_PATH)
            append!(Base.LOAD_PATH, oldload)
            empty!(Base.DEPOT_PATH)
            append!(Base.DEPOT_PATH, olddepot)
        end
    end
end

@testitem "unknown_preferences reads every TOML spelling of StrictMode's table" begin
    using StrictMode

    mktempdir() do dir
        oldproj, oldload = Base.ACTIVE_PROJECT[], copy(Base.LOAD_PATH)
        try
            empty!(Base.LOAD_PATH)
            push!(Base.LOAD_PATH, "@")
            proj = joinpath(dir, "Project.toml")
            prefs = joinpath(dir, "LocalPreferences.toml")
            Base.set_active_project(proj)
            write(proj, "[deps]\n")
            # The project file stays, since it is what makes `dir` the active project.
            found(text, file) = (write(file, text); r = StrictMode.unknown_preferences(); file == proj ? write(proj, "[deps]\n") : rm(file); r)
            for text in (
                    "[StrictMode]  # local overrides\ncheck_enabled = false\n",
                    "[ StrictMode ]\ncheck_enabled = false\n",
                    "['StrictMode']\ncheck_enabled = false\n",
                    "StrictMode.check_enabled = false\n",
                    "[StrictMode.check_enabled]\nx = 1\n",
                    "StrictMode = {check_enabled = false}\n",
                    "StrictMode = { banner = true, \"check_enabled\" = false } # c\n",
                    "StrictMode = {banner = \"a, } b\", check_enabled = [1, 2]}\n",
                )
                @test found(text, prefs) == ["check_enabled ($prefs)"]
            end
            for text in (
                    "[deps]\n\n[preferences.\"StrictMode\"]\ncheck_enabled = false\n",
                    "[deps]\n\n[preferences]\nStrictMode.check_enabled = false\n",
                    "[deps]\n\n[ preferences . StrictMode ] # note\ncheck_enabled = false\n",
                    "[deps]\n\n[preferences]\nStrictMode = {check_enabled = false}\n",
                    "preferences = {Other = {x = 1}, StrictMode = {check_enabled = false}}\n[deps]\n",
                )
                @test found(text, proj) == ["check_enabled ($proj)"]
            end
            # Keys StrictMode reads, in the same spellings, and another package's table.
            @test isempty(found("StrictMode.checks_enabled = false\n[ StrictMode ] # c\nbanner = true\n[Other]\ncheck_enabled = 1\n", prefs))
            @test isempty(found("[preferences]\nStrictMode.banner = false\nOther.check_enabled = 1\n", proj))
            @test isempty(found("StrictMode = {checks_enabled = false, banner = true}\nOther = {check_enabled = 1}\n", prefs))
            @test isempty(found("[preferences]\nOther = {StrictMode = 1, check_enabled = 1}\n", proj))
            # The whole file is read, however long.
            @test found("[StrictMode]\n" * "# padding\n"^10_000 * "check_enabled = false\n", prefs) == ["check_enabled ($prefs)"]
        finally
            Base.set_active_project(oldproj)
            empty!(Base.LOAD_PATH)
            append!(Base.LOAD_PATH, oldload)
        end
    end
end

@testitem "unknown_preferences names a preference file it cannot read" begin
    using StrictMode

    # A file that cannot be read is named in a warning, once, and the other files are still
    # searched: an empty list must not stand for "could not look". Permissions are what make a file
    # unreadable here, and Windows does not deny reads through them.
    Sys.iswindows() || mktempdir() do dir
        oldproj, oldload = Base.ACTIVE_PROJECT[], copy(Base.LOAD_PATH)
        prefs = joinpath(dir, "LocalPreferences.toml")
        try
            empty!(Base.LOAD_PATH)
            push!(Base.LOAD_PATH, "@")
            proj = joinpath(dir, "Project.toml")
            Base.set_active_project(proj)
            write(proj, "[deps]\n\n[preferences.StrictMode]\nchecks_enable = false\n")
            write(prefs, "[StrictMode]\nbaner = false\n")
            chmod(prefs, 0o000)
            # The fixture really is unreadable; as a superuser it would not be.
            @test_throws SystemError read(prefs)
            empty!(StrictMode._UNREADABLE_PREFERENCES)

            out = joinpath(dir, "stderr.txt")
            printed(f) = (open(io -> redirect_stderr(() -> (r = f(); Libc.flush_cstdio(); r), io), out, "w"), read(out, String))
            (found, text) = printed(StrictMode.unknown_preferences)
            @test found == ["checks_enable ($proj)"]
            @test occursin("StrictMode: could not read the preference file $prefs", text)
            # Once per file: a second search names it no more.
            (found2, text2) = printed(StrictMode.unknown_preferences)
            @test found2 == found
            @test !occursin(prefs, text2)
            # The load-time warning reaches the same search, and the text it prints holds no `%`.
            @test !occursin('%', StrictMode._UNREADABLE_PREFERENCE_NOTE)
        finally
            chmod(prefs, 0o644)
            empty!(StrictMode._UNREADABLE_PREFERENCES)
            Base.set_active_project(oldproj)
            empty!(Base.LOAD_PATH)
            append!(Base.LOAD_PATH, oldload)
        end
    end
end
