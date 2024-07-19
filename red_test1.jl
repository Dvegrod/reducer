
using ADIOS2

include("src/reducer.jl")



builder::reducer.PipelineBuilder = reducer.input("var_name", "random", "", [100, 100, 10], Float64)


# Add one layer
ker1 = reducer.kernel([10, 10, 1])
builder = reducer.reduction(builder, ker1, :average)

# Launch
reducer.build(builder)

adios = adios_init_serial()
io = declare_io(adios, "COMM_IO")
engine = open(io, "reducer.bp", mode_readRandomAccess)

#@assert reducer.@check_for_val_w_timeout((f() = reducer._get(io, engine, :exec_ready)), 1, 10)

# Build
#@assert reducer.@check_for_val_w_timeout((f() = reducer._get(io, engine, :exec_ready)), 2, 10)

