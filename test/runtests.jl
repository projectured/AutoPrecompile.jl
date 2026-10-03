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

@testset "this version adds no package callback when it loads" begin
    @test !any(callback -> parentmodule(callback) === AutoPrecompile, Base.package_callbacks)
end

end
