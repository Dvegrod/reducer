

using Base: Filesystem

using Test
using ADIOS2
using reducer


# This test file check the blueprinting of pipelines works properly
const dirname = Filesystem.mktempdir()
const filename = "$dirname/test.bp"


include("configuration.jl")
include("exe_utils.jl")