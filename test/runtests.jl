using Test
using AutoPrecompile

@testset "AutoPrecompile" begin
    # This version does nothing when it loads, so it adds no package callback.
    @test !any(callback -> parentmodule(callback) === AutoPrecompile, Base.package_callbacks)
end
