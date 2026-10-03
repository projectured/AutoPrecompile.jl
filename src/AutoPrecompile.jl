"""
    AutoPrecompile

A package in development. Its goal: for each set of packages that a session
loads, compile the precompile statements that those packages ship into one
package image, so that a later session with the same set loads compiled code
instead of compiling it again.

A package ships its statements in the `.txt` files of a folder `precompile/` at
its root, one signature on each line, as `julia --trace-compile` writes it: the
text inside `precompile(…)`.

This version does nothing when it loads. It has the selection of the statements
that apply to the loaded packages, and nothing calls it yet.
"""
module AutoPrecompile

using UUIDs: UUID, uuid5

# The folder of a package that holds its statement files, and their extension.
const _STATEMENT_FOLDER = "precompile"
const _STATEMENT_EXTENSION = ".txt"

# The modules that a statement can name without a loaded package.
const _BUILTIN_ROOTS = (:Base, :Core)

# The namespace of the uuids of the leaves: the uuid of this package.
const _LEAF_NAMESPACE = UUID("b272d1c7-21da-44b4-9d4d-f64941f33c6f")

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

# ── The selection ───────────────────────────────────────────────────────────

# The loaded packages, as Julia's lock of loading sees them.
_collect_loaded_package_ids() = @lock Base.require_lock collect(keys(Base.loaded_modules))

"""
    _collect_loaded_packages() -> Dict{Symbol,Base.PkgId}

The loaded packages by name. A name that two loaded packages share is left out,
because a statement can not say which of them it means.
"""
function _collect_loaded_packages()
    packages = Dict{Symbol,Base.PkgId}()
    shared = Set{Symbol}()
    for package in _collect_loaded_package_ids()
        package.uuid === nothing && continue
        name = Symbol(package.name)
        haskey(packages, name) && packages[name] != package && push!(shared, name)
        packages[name] = package
    end
    foreach(name -> delete!(packages, name), shared)
    packages
end

"""
    _collect_loaded_statement_lines() -> Vector{String}

The lines of the statement files of every loaded package.
"""
function _collect_loaded_statement_lines()
    lines = String[]
    for package in _collect_loaded_package_ids()
        package.uuid === nothing && continue
        loaded = get(Base.loaded_modules, package, nothing)
        loaded === nothing && continue
        folder = pkgdir(loaded)
        folder === nothing || append!(lines, _collect_statement_lines(folder))
    end
    lines
end

"""
    _select_statements(lines, packages) -> (statements, set)

The lines that have the shape of a signature and whose roots are all loaded:
`Base`, `Core`, or a name of `packages`. `statements` holds each selected line
once, sorted. `set` holds the packages that they name, sorted by uuid.
"""
function _select_statements(lines, packages::AbstractDict{Symbol,Base.PkgId})
    statements = Set{String}()
    set = Set{Base.PkgId}()
    for line in lines
        expression = _parse_signature(line)
        expression === nothing && continue
        roots = _collect_roots!(Set{Symbol}(), expression)
        all(root -> root in _BUILTIN_ROOTS || haskey(packages, root), roots) || continue
        push!(statements, line)
        for root in roots
            root in _BUILTIN_ROOTS || push!(set, packages[root])
        end
    end
    sort!(collect(statements)), sort!(collect(set); by = package -> string(package.uuid))
end

"""
    _select_loaded_statements() -> (statements, set)

[`_select_statements`](@ref) for the statement files and the packages that this
session has loaded.
"""
_select_loaded_statements() =
    _select_statements(_collect_loaded_statement_lines(), _collect_loaded_packages())

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
_format_leaf_name(uuid::UUID) = "AutoPrecompileLeaf_" * replace(string(uuid), "-" => "")[1:16]

end # module AutoPrecompile
