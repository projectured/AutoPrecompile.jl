# AutoPrecompile.jl

[![CI](https://github.com/projectured/AutoPrecompile.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/projectured/AutoPrecompile.jl/actions/workflows/CI.yml)

**Status: 0.1.0, an early release.** It builds, loads and removes images.
ProjecturEd does not need it: since its release 0.1.1, each of its packages
compiles its own first window into its package image. Problem reports and
questions are welcome as GitHub issues.

A Julia session compiles much of the code that it runs, and it keeps that code
only until the process ends. A package can cache compiled code in its package
image with a `PrecompileTools` workload. The image holds all code that the
workload runs, also methods of other packages. But a workload can run only the
code of its package and of the packages that it depends on, and a package that a
session loads later can invalidate that code. Code that joins packages that do
not depend on each other needs a package or an extension that depends on all of
them, with a workload of its own: one for each combination that users load.

AutoPrecompile makes that package for you: one leaf for each set of packages
that a session loads, built after the session loaded them, so no package of the
set can invalidate it.

## What it saves

Measured on 2026-10-03 with the packages of ProjecturEd, a projectional editor,
in the session that [their README](https://github.com/projectured/Projectured.jl)
shows: `using AutoPrecompile, Projectured,
DataFrames, SimpleDirectMediaLayer`, then `display_in_editor` of a data frame of
100 000 rows, timed until the window draws its first frame. Julia 1.13, one
thread, three runs of each session that loads an image or none. The packages of
ProjecturEd had no workloads of their own then, so the session without
AutoPrecompile compiles all of their code. With their own workloads, since
ProjecturEd 0.1.1, that first frame takes about 0.75 s without AutoPrecompile.

| session | `using` line | first `display_in_editor` | second |
| --- | ---: | ---: | ---: |
| without AutoPrecompile | 1.2 s | 27 to 30 s | 0.1 to 2.2 s |
| the first with AutoPrecompile, which builds the image | 2.5 s | 29 s | 5.6 s |
| a later one, which loads the image | 2.8 to 3.0 s | 0.3 to 0.4 s | 0.1 to 0.2 s |

- Without the image, nearly all of the first call is compile time. With it, the
  first call compiles 0.2 s at most.
- The image holds 8129 statements. It took about 95 s to build in the
  background, and it takes 127 MB.
- The `using` line takes about 1.7 s more, because AutoPrecompile reads the
  statement files and loads the image.
- The session that builds the image is no faster. Its second call also compiles
  the code of AutoPrecompile that starts the build.

## Install

AutoPrecompile is in the registry
[`ProjecturedRegistry`](https://github.com/projectured/ProjecturedRegistry), not in
the General registry. Add both registries once; if General is there already, its
line does nothing:

```
pkg> registry add General
pkg> registry add https://github.com/projectured/ProjecturedRegistry
pkg> add AutoPrecompile
```

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

## Licence

MIT, in [`LICENSE`](LICENSE).
