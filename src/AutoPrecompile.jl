"""
    AutoPrecompile

Compiles, once for each set of packages that a session loads, the precompile
statements that those packages ship, into one package image that a later session
with the same set loads.

A package ships its statements in the `.txt` files of a folder `precompile/` at
its root, one signature on each line, as `julia --trace-compile` writes it: the
text inside `precompile(…)`.

After each load of a package, AutoPrecompile selects the statements of the loaded
packages whose modules are all loaded. The packages that they name are the set of
a *leaf*: a small package that AutoPrecompile writes into its scratch space, which
imports the set and replays the statements while Julia precompiles it.

- When the leaf of the set has a valid image, AutoPrecompile loads it, and the
  session finds the code compiled.
- Else, after 10 s with no new load, it writes the leaf and builds its image in a
  separate process at a low priority, and logs that it does. The session goes on
  and compiles as before; the next session with the same set loads the image. A
  session that ends before the 10 s pass starts the build as it ends.

A line that does not have the shape of a signature is never evaluated. A process
that writes a cache file does nothing, so no cache file depends on the
statements.

This version does not limit the disk space of its leaves yet.
"""
module AutoPrecompile

using Scratch: get_scratch!
using UUIDs: UUID, uuid5

# The folder of a package that holds its statement files, and their extension.
const _STATEMENT_FOLDER = "precompile"
const _STATEMENT_EXTENSION = ".txt"

# The modules that a statement can name without a loaded package.
const _BUILTIN_ROOTS = (:Base, :Core)

# The namespace of the uuids of the leaves: the uuid of this package.
const _LEAF_NAMESPACE = UUID("b272d1c7-21da-44b4-9d4d-f64941f33c6f")

# The start of the name of every leaf.
const _LEAF_PREFIX = "AutoPrecompileLeaf_"

# The packages that every leaf depends on, besides its set.
const _AUTOPRECOMPILE = Base.PkgId(_LEAF_NAMESPACE, "AutoPrecompile")
const _PRECOMPILETOOLS =
    Base.PkgId(UUID("aea7be01-6a6a-4083-8856-8a6e6704d82a"), "PrecompileTools")

# The time in seconds with no new load before a build starts.
const _BUILD_WAIT = Ref(10.0)

# ── The statement files ─────────────────────────────────────────────────────

"""
    _collect_statement_lines(folder) -> Vector{String}

The lines of the statement files of the package in `folder`: each `.txt` file
of its folder `precompile/`, in the order of the file names. An empty line and a
line that starts with `#` are left out. A package with no such folder has none.
"""
function _collect_statement_lines(folder::AbstractString)
    directory = joinpath(folder, _STATEMENT_FOLDER)
    isdir(directory) || return String[]
    lines = String[]
    for name in sort!(readdir(directory))
        path = joinpath(directory, name)
        (endswith(name, _STATEMENT_EXTENSION) && isfile(path)) || continue
        for line in eachline(path)
            line = strip(line)
            (isempty(line) || startswith(line, '#')) && continue
            push!(lines, String(line))
        end
    end
    lines
end

# ── The shape of a signature ────────────────────────────────────────────────
#
# A statement file is text from another package, and AutoPrecompile evaluates
# what it selects. So a line is selected only when its expression has the shape
# of a type as `--trace-compile` writes it. Evaluating such an expression looks
# up names and applies type parameters; the only function that it calls is
# `typeof` of a name.

# Whether `x` is a name or a dotted name, such as `Base.Order.lt` or `Base.:(+)`.
_is_dotted_name(x) =
    x isa Symbol ||
    (x isa Expr && x.head === :. && length(x.args) == 2 && _is_dotted_name(x.args[1]) &&
     x.args[2] isa QuoteNode && x.args[2].value isa Symbol)

# Whether `x` has the shape of a part of a type.
function _is_type_expression(x)
    x isa Symbol && return true
    x isa QuoteNode && return x.value isa Symbol
    x isa Union{Integer,AbstractFloat,Char,String} && return true
    x isa Expr || return false
    head, arguments = x.head, x.args
    head === :. && return _is_dotted_name(x)
    head === :call &&
        return length(arguments) == 2 && arguments[1] === :typeof && _is_dotted_name(arguments[2])
    head === :curly &&
        return !isempty(arguments) && _is_dotted_name(arguments[1]) &&
               all(_is_type_expression, @view arguments[2:end])
    head in (:tuple, :where, :<:, :>:) && return all(_is_type_expression, arguments)
    head === :comparison &&
        return all(i -> isodd(i) ? _is_type_expression(arguments[i]) : arguments[i] === :<:,
                   eachindex(arguments))
    false
end

# Whether `x` is the signature of a method instance: a `Tuple{…}` type, with or
# without `where`.
function _is_signature(x)
    body = x
    while body isa Expr && body.head === :where && !isempty(body.args)
        body = body.args[1]
    end
    body isa Expr && body.head === :curly && !isempty(body.args) && body.args[1] === :Tuple &&
        _is_type_expression(x)
end

"""
    _parse_signature(line) -> Union{Expr,Nothing}

The expression of `line` when the line parses as one expression with the shape
of a signature, else `nothing`.
"""
function _parse_signature(line::AbstractString)
    expression = try
        Meta.parse(line)
    catch
        return nothing
    end
    _is_signature(expression) ? expression : nothing
end

"""
    _collect_roots!(roots, expression) -> roots

Add to `roots` the first name of each dotted name in `expression`: the modules
that a signature names.
"""
function _collect_roots!(roots::Set{Symbol}, x)
    x isa Expr || return roots
    if x.head === :.
        first = x
        while first isa Expr
            first = first.args[1]
        end
        first isa Symbol && push!(roots, first)
    else
        foreach(argument -> _collect_roots!(roots, argument), x.args)
    end
    roots
end

# A line of a statement file that has the shape of a signature, and its roots.
struct _ParsedLine
    line::String
    roots::Vector{Symbol}
end

# The lines of `lines` that have the shape of a signature, with their roots.
function _parse_statement_lines(lines)
    parsed = _ParsedLine[]
    for line in lines
        expression = _parse_signature(line)
        expression === nothing && continue
        push!(parsed, _ParsedLine(line, collect(_collect_roots!(Set{Symbol}(), expression))))
    end
    parsed
end

# ── The selection ───────────────────────────────────────────────────────────

# The state of the session: the folder of the leaves, the parsed statements of
# each loaded package, the wait for a build, and the builds that it started.
const _LEAVES = Ref("")
const _STATE_LOCK = ReentrantLock()
const _PARSED = Dict{Base.PkgId,Vector{_ParsedLine}}()
const _BUILD_TIMER = Ref{Union{Nothing,Timer}}(nothing)
const _BUILDS = Dict{UUID,Base.Process}()

# Whether the callback runs, so that a load that it starts does not run it again.
const _RUNNING = Threads.Atomic{Bool}(false)

# The loaded packages and their modules, as Julia's lock of loading sees them.
_collect_loaded_modules() = @lock Base.require_lock collect(Base.loaded_modules)

# Whether `package` is loaded.
_is_loaded(package::Base.PkgId) = @lock Base.require_lock haskey(Base.loaded_modules, package)

# Whether `package` is a leaf of AutoPrecompile.
_is_leaf(package::Base.PkgId) = startswith(package.name, _LEAF_PREFIX)

"""
    _collect_loaded_packages(modules = _collect_loaded_modules()) -> Dict{Symbol,Base.PkgId}

The loaded packages by name. A name that two loaded packages share is left out,
because a statement can not say which of them it means.
"""
function _collect_loaded_packages(modules = _collect_loaded_modules())
    packages = Dict{Symbol,Base.PkgId}()
    shared = Set{Symbol}()
    for (package, _) in modules
        package.uuid === nothing && continue
        name = Symbol(package.name)
        haskey(packages, name) && packages[name] != package && push!(shared, name)
        packages[name] = package
    end
    foreach(name -> delete!(packages, name), shared)
    packages
end

# The parsed statement lines of the loaded `package`. They are read once in a
# session, because a loaded package keeps its files.
function _compute_package_statements!(package::Base.PkgId, loaded::Module)
    lock(_STATE_LOCK) do
        get!(_PARSED, package) do
            folder = pkgdir(loaded)
            folder === nothing ? _ParsedLine[] :
                _parse_statement_lines(_collect_statement_lines(folder))
        end
    end
end

# The parsed lines whose roots are all loaded, as `_select_statements` answers them.
function _select_parsed_statements(parsed, packages::AbstractDict{Symbol,Base.PkgId})
    statements = Set{String}()
    set = Set{Base.PkgId}()
    for entry in parsed
        all(root -> root in _BUILTIN_ROOTS || haskey(packages, root), entry.roots) || continue
        push!(statements, entry.line)
        for root in entry.roots
            root in _BUILTIN_ROOTS || push!(set, packages[root])
        end
    end
    sort!(collect(statements)), sort!(collect(set); by = package -> string(package.uuid))
end

"""
    _select_statements(lines, packages) -> (statements, set)

The lines that have the shape of a signature and whose roots are all loaded:
`Base`, `Core`, or a name of `packages`. `statements` holds each selected line
once, sorted. `set` holds the packages that they name, sorted by uuid.
"""
_select_statements(lines, packages::AbstractDict{Symbol,Base.PkgId}) =
    _select_parsed_statements(_parse_statement_lines(lines), packages)

"""
    _select_loaded_statements() -> (statements, set)

[`_select_statements`](@ref) for the statement files and the packages that this
session has loaded. The files of the leaves are not read.
"""
function _select_loaded_statements()
    modules = _collect_loaded_modules()
    parsed = _ParsedLine[]
    for (package, loaded) in modules
        (package.uuid === nothing || _is_leaf(package)) && continue
        append!(parsed, _compute_package_statements!(package, loaded))
    end
    _select_parsed_statements(parsed, _collect_loaded_packages(modules))
end

# ── The key of a leaf ───────────────────────────────────────────────────────

"""
    _compute_leaf_uuid(set) -> UUID

The uuid of the leaf of the packages `set`. It depends only on the uuids of the
packages, not on their order, so every session with the same set finds the same
leaf.
"""
_compute_leaf_uuid(set) =
    uuid5(_LEAF_NAMESPACE, join(sort!([string(package.uuid) for package in set]), ","))

"""
    _format_leaf_name(uuid) -> String

The package name of the leaf with `uuid`.
"""
_format_leaf_name(uuid::UUID) = _LEAF_PREFIX * replace(string(uuid), "-" => "")[1:16]

# ── The leaf ────────────────────────────────────────────────────────────────

"""
    _Leaf

The package that AutoPrecompile writes for one set of packages: its id, its
folder in the scratch space, the statements that it replays, and the set.
"""
struct _Leaf
    id::Base.PkgId
    folder::String
    statements::Vector{String}
    set::Vector{Base.PkgId}
end

function _make_leaf(statements, set)
    uuid = _compute_leaf_uuid(set)
    name = _format_leaf_name(uuid)
    _Leaf(Base.PkgId(uuid, name), joinpath(_LEAVES[], name), statements, set)
end

_get_statement_file(leaf::_Leaf) = joinpath(leaf.folder, "statements.txt")
_get_build_log(leaf::_Leaf) = joinpath(leaf.folder, "build.log")

_format_statement_file(statements) = isempty(statements) ? "" : join(statements, '\n') * '\n'

function _format_leaf_project(leaf::_Leaf)
    text = "name = \"$(leaf.id.name)\"\nuuid = \"$(leaf.id.uuid)\"\nversion = \"0.1.0\"\n\n[deps]\n"
    for package in unique!([_AUTOPRECOMPILE; _PRECOMPILETOOLS; leaf.set])
        text *= "$(package.name) = \"$(package.uuid)\"\n"
    end
    text
end

function _format_leaf_source(leaf::_Leaf)
    imports = join(("import $(package.name)\n" for package in leaf.set))
    """
    # Written by AutoPrecompile for one set of packages. Its precompile replays the
    # statements of statements.txt.
    module $(leaf.id.name)

    import AutoPrecompile
    using PrecompileTools: @setup_workload, @compile_workload
    $(imports)
    module StatementScope end

    const STATEMENT_FILE = joinpath(@__DIR__, "..", "statements.txt")
    include_dependency(STATEMENT_FILE)

    @setup_workload begin
        statements = readlines(STATEMENT_FILE)
        @compile_workload begin
            AutoPrecompile._replay_statements!(statements, StatementScope)
        end
    end

    end
    """
end

# Whether the folder of `leaf` holds the statements that the session selects now.
function _is_leaf_written(leaf::_Leaf)
    path = _get_statement_file(leaf)
    isfile(path) && read(path, String) == _format_statement_file(leaf.statements)
end

# Write `text` to `path` under another name, then rename it, so that a build in
# another session never reads half a file.
function _write_atomically(path, text)
    temporary = "$path.$(getpid()).new"
    write(temporary, text)
    mv(temporary, path; force = true)
end

function _write_leaf!(leaf::_Leaf)
    mkpath(joinpath(leaf.folder, "src"))
    _write_atomically(joinpath(leaf.folder, "Project.toml"), _format_leaf_project(leaf))
    _write_atomically(joinpath(leaf.folder, "src", leaf.id.name * ".jl"), _format_leaf_source(leaf))
    _write_atomically(_get_statement_file(leaf), _format_statement_file(leaf.statements))
    nothing
end

# Bind each loaded module into `scope` under its own name. A statement names a
# type from the module that defines it, so each module must be reachable there.
function _bind_loaded_modules!(scope::Module)
    for (_, loaded) in _collect_loaded_modules()
        name = nameof(loaded)
        (name === :Main || isdefined(scope, name)) && continue
        try
            Core.eval(scope, :(const $name = $loaded))
        catch
        end
    end
    scope
end

"""
    _replay_statements!(statements, scope) -> (compiled, skipped, total)

Bind each loaded module into `scope`, then compile each statement that has the
shape of a signature and still names a method, resolved in `scope`. A leaf calls
this inside its `@compile_workload`. A statement that names a type or a method
that no longer exists is skipped.
"""
function _replay_statements!(statements, scope::Module)
    _bind_loaded_modules!(scope)
    compiled = 0
    for line in statements
        expression = _parse_signature(line)
        expression === nothing && continue
        try
            precompile(Core.eval(scope, expression)) && (compiled += 1)
        catch
        end
    end
    total = length(statements)
    println(stderr, "AutoPrecompile: compiled $compiled of $total statements")
    (compiled = compiled, skipped = total - compiled, total = total)
end

# ── The build ───────────────────────────────────────────────────────────────

# The command that builds the image of `leaf` in a process of its own, with the
# load path and the depots of this session. A pidfile lock lets one process
# build a leaf at a time; the next one finds the image valid and stops.
function _make_build_command(leaf::_Leaf)
    separator = Sys.iswindows() ? ";" : ":"
    code = """
        using FileWatching: mkpidlock
        leaf = Base.PkgId(Base.UUID("$(leaf.id.uuid)"), "$(leaf.id.name)")
        mkpidlock($(repr(joinpath(leaf.folder, "build.pid")))) do
            if !Base.isprecompiled(leaf)
                result = Base.compilecache(leaf)
                result isa Exception && throw(result)
            end
        end
        println("AutoPrecompile: the image is ready")
        """
    command = `$(Base.julia_cmd()) --startup-file=no --history-file=no -e $code`
    Sys.isunix() && Sys.which("nice") !== nothing && (command = `nice -n 10 $command`)
    detach(addenv(command, "JULIA_LOAD_PATH" => join(Base.load_path(), separator),
                  "JULIA_DEPOT_PATH" => join(DEPOT_PATH, separator)))
end

# Whether a build of `leaf` that this session started still runs.
function _is_building(leaf::_Leaf)
    lock(_STATE_LOCK) do
        process = get(_BUILDS, leaf.id.uuid, nothing)
        process !== nothing && process_running(process)
    end
end

function _start_build!(leaf::_Leaf)
    names = join(sort!([package.name for package in leaf.set]), ", ")
    log = _get_build_log(leaf)
    @info "AutoPrecompile: compiling $(length(leaf.statements)) statements for $names in the background; the next session that loads these packages uses the result" log
    process = open(log, "w") do io
        run(pipeline(_make_build_command(leaf); stdin = devnull, stdout = io, stderr = io);
            wait = false)
    end
    lock(() -> (_BUILDS[leaf.id.uuid] = process), _STATE_LOCK)
    errormonitor(@async begin
        if success(process)
            @info "AutoPrecompile: the image for $names is ready"
        else
            @warn "AutoPrecompile: the build for $names failed" log
        end
    end)
    process
end

# Run `f`, and turn a fault into a warning, because a fault of AutoPrecompile must
# not stop the session.
function _run_guarded(f, what)
    try
        f()
    catch exception
        @warn "AutoPrecompile: $what failed" exception = (exception, catch_backtrace())
    end
    nothing
end

# Build the leaf of the statements that the session selects now, unless its image
# is valid or a build of it runs. While a package loads, wait again.
function _build_selection!()
    lock(() -> (_BUILD_TIMER[] = nothing), _STATE_LOCK)
    _is_any_package_loading() && return _schedule_build!()
    statements, set = _select_loaded_statements()
    isempty(statements) && return nothing
    leaf = _make_leaf(statements, set)
    _is_building(leaf) && return nothing
    _is_leaf_written(leaf) && Base.isprecompiled(leaf.id) && return nothing
    _write_leaf!(leaf)
    _start_build!(leaf)
    nothing
end

# Start a build after `_BUILD_WAIT[]` seconds with no new load. Each call starts
# the wait again.
function _schedule_build!()
    lock(_STATE_LOCK) do
        timer = _BUILD_TIMER[]
        timer === nothing || close(timer)
        _BUILD_TIMER[] = Timer(_ -> _run_guarded(_build_selection!, "the build"), _BUILD_WAIT[])
    end
    nothing
end

# Stop the wait for a build, and answer whether a build waited.
function _cancel_build_wait!()
    lock(_STATE_LOCK) do
        timer = _BUILD_TIMER[]
        _BUILD_TIMER[] = nothing
        timer === nothing || close(timer)
        timer !== nothing
    end
end

# A build that waits starts at once when the session ends, in a process that
# outlives it.
_start_waiting_build() = _cancel_build_wait!() && _run_guarded(_build_selection!, "the build")

# ── The callback ────────────────────────────────────────────────────────────

# Whether a package loads now. Julia calls the callback of a dependency while the
# package that imports it still loads, and calls the callback of the outer package
# after its load ends, so the callback waits for that one.
_is_any_package_loading() = @lock Base.require_lock !isempty(Base.package_locks)

# Load the leaf of the loaded packages when its image is valid, else wait for a
# build.
function _load_or_schedule!()
    statements, set = _select_loaded_statements()
    isempty(statements) && return nothing
    leaf = _make_leaf(statements, set)
    _is_loaded(leaf.id) && return nothing
    if _is_leaf_written(leaf) && Base.isprecompiled(leaf.id)
        _cancel_build_wait!()
        Base.require(leaf.id)
    else
        _schedule_build!()
    end
    nothing
end

# The callback after each load of a package. A fault here must not stop the
# `using` line of the user, so it becomes a warning.
function _run_after_load(package::Base.PkgId)
    _is_leaf(package) && return nothing
    _is_any_package_loading() && return nothing
    Threads.atomic_cas!(_RUNNING, false, true) && return nothing
    try
        _load_or_schedule!()
    catch exception
        @warn "AutoPrecompile: the check after a load failed" exception = (exception, catch_backtrace())
    finally
        _RUNNING[] = false
    end
    nothing
end

function __init__()
    ccall(:jl_generating_output, Cint, ()) == 1 && return nothing
    _LEAVES[] = get_scratch!(@__MODULE__, "leaves")
    _LEAVES[] in LOAD_PATH || push!(LOAD_PATH, _LEAVES[])
    push!(Base.package_callbacks, _run_after_load)
    atexit(_start_waiting_build)
    nothing
end

end # module AutoPrecompile
