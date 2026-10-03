using Test
using AutoPrecompile
using AutoPrecompile: _collect_statement_lines, _parse_signature, _collect_roots!,
    _collect_loaded_packages, _select_statements, _compute_leaf_uuid, _format_leaf_name
const UUID = Base.UUID

# One line of each form that `--trace-compile` writes, as the recordings of
# ProjecturEd hold them, and a few more that the shape allows.
const _SIGNATURES = [
    "Tuple{typeof(Base.first), Tuple{String, String}}",
    "Tuple{Base.Fix{2, typeof(Base.:(>)), Int64}, Int64}",
    "Tuple{Type{NamedTuple{(:n, :square), T} where T<:Tuple}, Tuple{Base.UnitRange{Int64}, Array{Int64, 1}}}",
    "Tuple{typeof(Core.kwcall), NamedTuple{(:selection,), Tuple{Nothing}}, typeof(Base.identity)}",
    "Tuple{ProjecturedBook.BookModule.var\"#50#51\"{Int64}}",
    "Tuple{typeof(Base.something), Nothing, Union{}}",
    "Tuple{Base.Val{2}, Base.Val{:x}, Base.Val{true}, Base.Val{'c'}, Base.Val{1.5}, Base.Val{\"s\"}}",
    "Tuple{Array{<:Real, 1}}",
    "Tuple{Type{Pair{A, B}} where B>:Int64 where A}",
    "Tuple{Type{T} where Int64<:T<:Real}",
    "Tuple{typeof(Base.:(+)), Int64, Int64} where T",
]

# Lines that a statement file can hold and that must not be evaluated.
const _REFUSED = [
    "Tuple{typeof(rm(\"x\"))}",          # a call inside typeof
    "Tuple{Base.Val{f(1)}}",             # a call
    "Tuple{typeof(Base.:(+)(1, 2))}",    # a call of a dotted name
    "Tuple{@something}",                 # a macro
    "Tuple{x = 1}",                      # an assignment
    "Tuple{begin; 1; end}",              # a block
    "Tuple{Base.Val{\"\$(x)\"}}",        # an interpolation
    "Tuple{Base.Val{:(f())}}",           # a quoted expression
    "Tuple{(x -> x)}",                   # a function
    "Tuple{Base.Val{[1, 2]}}",           # an array
    "Tuple{Type{T} where Int64<T<Real}", # a comparison that is not <:
    "Base.Val{1}",                       # not a Tuple
    "typeof(Base.first)",                # not a Tuple
    "Tuple{Int64} Tuple{Int64}",         # two expressions
    "Tuple{Int64",                       # does not parse
]

const _A = Base.PkgId(UUID("10000000-0000-0000-0000-0000000000a1"), "PackageA")
const _B = Base.PkgId(UUID("10000000-0000-0000-0000-0000000000a2"), "PackageB")

# ── Sessions in a scratch environment ───────────────────────────────────────
#
# Each session is a new Julia process in a scratch environment of small packages,
# which names AutoPrecompile by its folder. It writes its cache files and its
# scratch space into a scratch depot, and reads installed packages from the depots
# of this process.

const _SCRATCH_UUIDS = Dict("PackageA" => "20000000-0000-0000-0000-0000000000a1",
                            "PackageB" => "20000000-0000-0000-0000-0000000000a2",
                            "PackageC" => "20000000-0000-0000-0000-0000000000a3")

function _write_statements(root, lines)
    directory = mkpath(joinpath(root, "precompile"))
    write(joinpath(directory, "scenario.txt"), join(lines, "\n") * "\n")
end

# A package in `folder` with the dependencies `deps` (scratch packages beside it),
# `body` in its module, and `statements` in its statement file.
function _make_scratch_package(folder, name; deps = String[], body = "", statements = nothing)
    root = joinpath(folder, name)
    mkpath(joinpath(root, "src"))
    project = "name = \"$name\"\nuuid = \"$(_SCRATCH_UUIDS[name])\"\nversion = \"0.1.0\"\n"
    if !isempty(deps)
        project *= "\n[deps]\n" * join(["$dep = \"$(_SCRATCH_UUIDS[dep])\"\n" for dep in deps])
        project *= "\n[sources]\n" * join(["$dep = {path = \"../$dep\"}\n" for dep in deps])
    end
    write(joinpath(root, "Project.toml"), project)
    write(joinpath(root, "src", "$name.jl"), "module $name\n$body\nend\n")
    statements === nothing || _write_statements(root, statements)
    root
end

# The depots of this process follow the scratch depot by name: an empty entry in
# `JULIA_DEPOT_PATH` would add the default depots without the depot of the user,
# which holds the registry and the installed packages.
_scratch_environment_variables(depot) =
    ("JULIA_LOAD_PATH" => "@" * (Sys.iswindows() ? ";" : ":") * "@stdlib",
     "JULIA_DEPOT_PATH" => join([depot; DEPOT_PATH], Sys.iswindows() ? ";" : ":"),
     "JULIA_PKG_OFFLINE" => "true", "JULIA_PKG_PRECOMPILE_AUTO" => "0")

# A scratch environment that names AutoPrecompile and three packages. `PackageB`
# ships a line that would remove `marker` if it were evaluated. It answers the
# folder of the environment, the folder of the scratch depot, and the folders of
# the packages.
function _make_scratch_environment(marker)
    folder = mktempdir()
    packages = [
        _make_scratch_package(folder, "PackageA";
            body = "struct Thing\n    x::Int\nend\nf(t::Thing) = string(t.x, \"!\")\nf(x::Int) = string(x, \"?\")",
            statements = ["Tuple{typeof(PackageA.f), PackageA.Thing}"]),
        _make_scratch_package(folder, "PackageB"; deps = ["PackageA"],
            body = "import PackageA\ng(t::PackageA.Thing) = PackageA.f(t) * \"!\"",
            statements = ["# what a scenario compiled",
                          "Tuple{typeof(PackageB.g), PackageA.Thing}",
                          "Tuple{typeof(PackageC.h), Int64}",
                          "Tuple{typeof(rm($(repr(marker))))}"]),
        _make_scratch_package(folder, "PackageC"; body = "h(x) = x + 1")]
    environment = mkpath(joinpath(folder, "environment"))
    depot = mkpath(joinpath(folder, "depot"))
    paths = [pkgdir(AutoPrecompile); packages]
    code = "using Pkg; Pkg.develop([PackageSpec(path = path) for path in $(repr(paths))]; io = devnull)"
    run(addenv(`$(Base.julia_cmd()) --startup-file=no --project=$environment -e $code`,
               _scratch_environment_variables(depot)...))
    environment, depot, packages
end

# Run `code` in a new session of `environment`, with `--trace-compile` into
# `trace` when it is given, and answer its standard output and standard error.
function _run_session(environment, depot, code; trace = nothing)
    flags = trace === nothing ? String[] : ["--trace-compile=$trace"]
    code = "_is_leaf_name(package) = startswith(package.name, \"AutoPrecompileLeaf_\")\n" * code
    output = IOBuffer()
    errors = IOBuffer()
    command = addenv(`$(Base.julia_cmd()) --startup-file=no $flags --project=$environment -e $code`,
                     _scratch_environment_variables(depot)...)
    run(pipeline(command; stdout = output, stderr = errors))
    String(take!(output)), String(take!(errors))
end

# The code of a session that loads `packages` with a short wait before a build,
# waits until the builds that it started end, and prints their exit codes.
_format_building_session(packages) = """
    using AutoPrecompile
    AutoPrecompile._BUILD_WAIT[] = 0.5
    using $packages
    deadline = time() + 600
    while time() < deadline
        sleep(0.5)
        builds = lock(() -> collect(values(AutoPrecompile._BUILDS)), AutoPrecompile._STATE_LOCK)
        AutoPrecompile._BUILD_TIMER[] === nothing && !isempty(builds) &&
            all(process_exited, builds) && break
    end
    print(join([string(process.exitcode) for process in values(AutoPrecompile._BUILDS)], " "))
    """

@testset "AutoPrecompile" begin

@testset "a package with no folder precompile/ has no statements" begin
    mktempdir() do folder
        @test _collect_statement_lines(folder) == String[]
    end
end

@testset "the .txt files of precompile/ in the order of their names, without comments" begin
    mktempdir() do folder
        directory = mkpath(joinpath(folder, "precompile"))
        write(joinpath(directory, "b.txt"), "# a comment\n\nTuple{Int64}\n")
        write(joinpath(directory, "a.txt"), "  Tuple{String}  \n")
        write(joinpath(directory, "notes.md"), "Tuple{Char}\n")
        mkpath(joinpath(directory, "c.txt"))
        @test _collect_statement_lines(folder) == ["Tuple{String}", "Tuple{Int64}"]
    end
end

@testset "a line with the shape of a signature parses: $line" for line in _SIGNATURES
    @test _parse_signature(line) isa Expr
end

@testset "a line without the shape of a signature is refused: $line" for line in _REFUSED
    @test _parse_signature(line) === nothing
end

@testset "the roots are the first names of the dotted names" begin
    line = "Tuple{typeof(Base.first), DataFrames.DataFrame, " *
           "ProjecturedPlatform.WidgetModule.WidgetTree{Int64}, Type{T} where T<:Integer}"
    @test _collect_roots!(Set{Symbol}(), _parse_signature(line)) ==
          Set([:Base, :DataFrames, :ProjecturedPlatform])
end

@testset "a line is selected when each of its roots is loaded" begin
    packages = Dict(:PackageA => _A, :PackageB => _B)
    lines = ["Tuple{typeof(PackageA.f), Int64}",
             "Tuple{typeof(PackageB.g), PackageA.T}",
             "Tuple{typeof(PackageC.h)}",
             "Tuple{typeof(Base.first), Tuple{Int64}}",
             "Tuple{typeof(PackageA.f), Int64}",
             "Tuple{typeof(rm(\"x\"))}"]
    statements, set = _select_statements(lines, packages)
    @test statements == sort(["Tuple{typeof(PackageA.f), Int64}",
                              "Tuple{typeof(PackageB.g), PackageA.T}",
                              "Tuple{typeof(Base.first), Tuple{Int64}}"])
    @test set == [_A, _B]
    @test _select_statements(["Tuple{typeof(Base.first), Tuple{Int64}}"], packages) ==
          (["Tuple{typeof(Base.first), Tuple{Int64}}"], Base.PkgId[])
end

@testset "the loaded packages by name, without Main, Base and Core" begin
    packages = _collect_loaded_packages()
    @test packages[:Test] == Base.PkgId(Test)
    @test packages[:AutoPrecompile] == Base.PkgId(AutoPrecompile)
    @test !any(name -> haskey(packages, name), (:Main, :Base, :Core))
end

@testset "the uuid of a leaf depends on the set, not on its order or the session" begin
    @test _compute_leaf_uuid([_A]) == UUID("d1e08e70-0d7e-5fa0-a26e-5fad11320bc5")
    @test _compute_leaf_uuid([_A, _B]) == _compute_leaf_uuid([_B, _A]) ==
          UUID("cf0e0f27-f259-5fbc-9ca5-4391c7ec8415")
    name = _format_leaf_name(_compute_leaf_uuid([_A, _B]))
    @test name == "AutoPrecompileLeaf_cf0e0f27f2595fbc"
    @test Base.isidentifier(name)
end

@testset "the disk limit comes from the preferences, in megabytes" begin
    get_limit = AutoPrecompile._get_disk_limit
    @test get_limit(Dict{String,Any}()) == 2048 * 1024^2
    @test get_limit(Dict{String,Any}("disk_limit_mb" => 100)) == 100 * 1024^2
    @test get_limit(Dict{String,Any}("disk_limit_mb" => 0)) == 0
    for value in ("2 GB", -1, 1.5)
        limit = @test_logs (:warn, r"disk_limit_mb") get_limit(Dict{String,Any}("disk_limit_mb" => value))
        @test limit == 2048 * 1024^2
    end
end

@testset "the leaves loaded longest ago go first, until all fit the limit" begin
    mktempdir() do depot
        leaves = mkpath(joinpath(depot, "leaves"))
        # A leaf with 1000 bytes of images for each of two Julia versions, loaded
        # `age` seconds ago.
        function make_leaf(name, age; building = false)
            folder = mkpath(joinpath(leaves, name))
            write(joinpath(folder, "statements.txt"), "")
            write(joinpath(folder, "loaded"), string(time() - age))
            building && write(joinpath(folder, "build.pid"), "1 host")
            for version in ("v1.12", "v1.13")
                images = mkpath(joinpath(depot, "compiled", version, name))
                write(joinpath(images, "image.so"), zeros(UInt8, 1000))
            end
        end
        make_leaf("AutoPrecompileLeaf_built", 500; building = true)
        make_leaf("AutoPrecompileLeaf_kept", 400)
        make_leaf("AutoPrecompileLeaf_old", 300)
        make_leaf("AutoPrecompileLeaf_middle", 200)
        make_leaf("AutoPrecompileLeaf_new", 100)
        mkpath(joinpath(leaves, "Other"))
        keep = Set(["AutoPrecompileLeaf_kept"])

        # Five leaves of a little more than 2000 bytes each. The two oldest leaves
        # that may go bring them under 6500 bytes; the one with a build and the
        # kept one stay, though they are older.
        removed = AutoPrecompile._remove_old_leaves!(; leaves, depot, limit = 6500, keep)
        @test removed == ["AutoPrecompileLeaf_old", "AutoPrecompileLeaf_middle"]
        for name in removed, folder in (joinpath(leaves, name),
                                        joinpath(depot, "compiled", "v1.12", name),
                                        joinpath(depot, "compiled", "v1.13", name))
            @test !isdir(folder)
        end
        for name in ("AutoPrecompileLeaf_built", "AutoPrecompileLeaf_kept",
                     "AutoPrecompileLeaf_new", "Other")
            @test isdir(joinpath(leaves, name))
        end
        @test AutoPrecompile._remove_old_leaves!(; leaves, depot, limit = 6500, keep) == String[]
    end
end

@testset "AutoPrecompile adds its callback and the folder of its leaves when it loads" begin
    @test any(callback -> parentmodule(callback) === AutoPrecompile, Base.package_callbacks)
    @test AutoPrecompile._LEAVES[] in LOAD_PATH
end

@testset "a session builds the leaf of its packages, and a later session loads it" begin
    marker = tempname()
    write(marker, "")
    environment, depot, packages = _make_scratch_environment(marker)
    package_a = Base.PkgId(UUID(_SCRATCH_UUIDS["PackageA"]), "PackageA")
    package_b = Base.PkgId(UUID(_SCRATCH_UUIDS["PackageB"]), "PackageB")
    leaves = joinpath(depot, "scratchspaces", string(Base.PkgId(AutoPrecompile).uuid), "leaves")
    leaf_ab = joinpath(leaves, _format_leaf_name(_compute_leaf_uuid([package_a, package_b])))
    leaf_a = joinpath(leaves, _format_leaf_name(_compute_leaf_uuid([package_a])))
    call = "print(any(_is_leaf_name, keys(Base.loaded_modules))); PackageB.g(PackageA.Thing(3))"

    # The first session selects two of the four lines, builds their leaf in the
    # background and says so. The line that calls `rm` is never evaluated.
    output, errors = _run_session(environment, depot, _format_building_session("PackageA, PackageB"))
    @test output == "0"
    @test occursin("AutoPrecompile: compiling 2 statements for PackageA, PackageB in the background",
                   errors)
    @test readlines(joinpath(leaf_ab, "statements.txt")) ==
          ["Tuple{typeof(PackageA.f), PackageA.Thing}", "Tuple{typeof(PackageB.g), PackageA.Thing}"]
    log = read(joinpath(leaf_ab, "build.log"), String)
    @test occursin("AutoPrecompile: compiled 2 of 2 statements", log)
    @test occursin("AutoPrecompile: the image is ready", log)
    @test isfile(marker)

    # A later session loads the leaf, builds nothing, and does not compile the
    # statements. Without AutoPrecompile the same call compiles `PackageB.g`, so
    # the first check means something.
    trace = joinpath(depot, "with-leaf.txt")
    output, errors = _run_session(environment, depot, "using AutoPrecompile, PackageA, PackageB; $call";
                                  trace)
    @test output == "true"
    @test !occursin("AutoPrecompile", errors)
    @test !occursin("PackageB.g", read(trace, String))
    @test isfile(joinpath(leaf_ab, "loaded"))
    trace = joinpath(depot, "without-leaf.txt")
    output, _ = _run_session(environment, depot, "using PackageA, PackageB; $call"; trace)
    @test output == "false"
    @test occursin("PackageB.g", read(trace, String))

    # A changed statement file builds the leaf again, and the session after loads it.
    # The build removes the old images of the leaf first, such as one that Julia
    # wrote for other flags.
    images = joinpath(depot, "compiled", "v$(VERSION.major).$(VERSION.minor)", basename(leaf_ab))
    stale = joinpath(images, "stale.ji")
    write(stale, "")
    _write_statements(packages[1], ["Tuple{typeof(PackageA.f), PackageA.Thing}",
                                    "Tuple{typeof(PackageA.f), Int64}"])
    output, errors = _run_session(environment, depot, _format_building_session("PackageA, PackageB"))
    @test output == "0"
    @test occursin("AutoPrecompile: compiling 3 statements for PackageA, PackageB", errors)
    @test !isfile(stale)
    @test count(endswith(".ji"), readdir(images)) == 1
    output, _ = _run_session(environment, depot, "using AutoPrecompile, PackageA, PackageB; $call")
    @test output == "true"

    # A package with no statements builds nothing.
    output, errors = _run_session(environment, depot, """
        using AutoPrecompile
        AutoPrecompile._BUILD_WAIT[] = 0.5
        using PackageC
        sleep(3)
        print(isempty(AutoPrecompile._BUILDS))
        """)
    @test output == "true"
    @test !occursin("AutoPrecompile", errors)

    # A session that ends before the wait starts the build as it ends, and the
    # build goes on after the session.
    output, errors = _run_session(environment, depot, "using AutoPrecompile, PackageA")
    @test occursin("AutoPrecompile: compiling 2 statements for PackageA in the background", errors)
    log = joinpath(leaf_a, "build.log")
    deadline = time() + 600
    while time() < deadline && !(isfile(log) && occursin("the image is ready", read(log, String)))
        sleep(1)
    end
    @test occursin("AutoPrecompile: the image is ready", read(log, String))
end

end
