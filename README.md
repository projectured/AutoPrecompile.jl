# AutoPrecompile.jl

[![CI](https://github.com/projectured/AutoPrecompile.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/projectured/AutoPrecompile.jl/actions/workflows/CI.yml)

**Status: in development.** It builds, loads and removes images. Nothing of it
has been measured outside its tests yet.

A Julia session compiles much of the code that it runs, and it keeps that code
only until the process ends. A package can cache compiled code in its own
package image with a precompile workload, but that workload holds only what the
package itself runs. Code that joins several packages, such as a table view of a
data frame drawn in a native window, belongs to no single package, so each new
session compiles it again.

AutoPrecompile caches that code, once for each set of packages that a session
loads.

## Use

```julia
julia> using AutoPrecompile, DataFrames, SomeViewer
```

The first session with a new set of packages compiles as before. After 10 s with
no new load, AutoPrecompile builds an image for the set in a separate process at
a low priority, and logs that it does:

```
[ Info: AutoPrecompile: compiling 2344 statements for DataFrames, SomeViewer, … in the background; the next session that loads these packages uses the result
```

A later session that loads the same packages loads that image, and finds the
code compiled. A session that ends before the 10 s pass starts the build as it
ends, and the build goes on after the session.

## Ship statements with a package

A package takes part with a folder `precompile/` at its root. Each `.txt` file
in it holds one signature on each line, as `julia --trace-compile=trace.txt`
writes them: the text inside `precompile(…)`.

```
# precompile/table-view.txt
Tuple{typeof(SomeViewer.show_table), DataFrames.DataFrame}
Tuple{typeof(Base.getindex), DataFrames.DataFrame, Int64, Symbol}
```

- A line applies when each module that it names is loaded. A line that names a
  package that the session did not load is left out.
- A line must have the shape of a signature: a `Tuple{…}` of names, type
  parameters, literals and `typeof` of a name. Any other line is refused and
  never evaluated, so a statement file can not run code.
- A line that names a type or a method that no longer exists is skipped. A file
  can be older than the code; record it again when much of it no longer applies.
- An empty line and a line that starts with `#` are left out.

## How it works

After each load of a package, AutoPrecompile reads the statement files of the
loaded packages and selects the lines that apply. The packages that those lines
name are the set of a *leaf*: a small package that AutoPrecompile writes into
its scratch space, which imports the set and replays the lines inside a
`PrecompileTools` workload while Julia precompiles it. Julia keeps the image of
the leaf with the images of the other packages.

- When the leaf of the set has a valid image, AutoPrecompile loads it.
- When the leaf has no valid image, AutoPrecompile never builds it in the
  session. It writes the leaf and builds it in the background, as above. A
  changed statement file or a new version of a package makes the image stale,
  and the next build replaces it.
- A process that writes a cache file does nothing, so no cache file depends on
  the statements.

## Disk space

All images of AutoPrecompile together take at most 2048 MB. Before and after
each build, it removes the images that a session loaded longest ago until they
fit, but never an image that the session loaded or one that a build can be
writing. Set another limit in megabytes in `LocalPreferences.toml` beside the
`Project.toml` of your environment:

```toml
[AutoPrecompile]
disk_limit_mb = 4096
```

The images live in the scratch space of AutoPrecompile, so `Pkg.gc()` removes
them when AutoPrecompile is no longer installed.
