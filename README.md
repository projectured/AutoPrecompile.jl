# AutoPrecompile.jl

[![CI](https://github.com/projectured/AutoPrecompile.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/projectured/AutoPrecompile.jl/actions/workflows/CI.yml)

**Status: in development.** This version does nothing when it loads. It reads
no statement file and builds no image.

## Goal

A Julia session compiles much of the code that it runs, and it keeps that code
only until the process ends. A package can cache compiled code in its own
package image with a precompile workload, but that workload holds only what the
package itself runs. Code that joins several packages, such as a table view of a
data frame drawn in a native window, belongs to no single package, so each new
session compiles it again.

AutoPrecompile will cache that code. A package will ship recorded precompile
statements in a folder `precompile/` at its root. For each set of packages that
a session loads, AutoPrecompile will select the statements whose modules are all
loaded, build one small package that depends on that set and replays them, and
load its image in later sessions with the same set.

- The user will load it with `using AutoPrecompile`.
- The first session with a new set will compile as before. AutoPrecompile will
  build the image in a separate process in the background, and log what it
  does.
- A statement that names a type or a method that no longer exists will be
  skipped.
