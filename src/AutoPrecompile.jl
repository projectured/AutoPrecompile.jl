"""
    AutoPrecompile

A package in development. Its goal: for each set of packages that a session
loads, compile the precompile statements that those packages ship into one
package image, so that a later session with the same set loads compiled code
instead of compiling it again.

This version does nothing when it loads: it reads no statement file and builds
no image.
"""
module AutoPrecompile

end # module AutoPrecompile
