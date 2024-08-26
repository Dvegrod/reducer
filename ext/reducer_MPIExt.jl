module reducer_MPIExt
   using reducer, MPI

#reducer.MPIConnection = MPIConnection


using MPI
using ParallelStencil
using ADIOS2

@init_parallel_stencil(Threads, Float64, 3)

include("../src/execution/structs.jl")
include("../src/execution/local_domains.jl")
include("../src/execution/reduction_operations.jl")
include("../src/execution/communication.jl")

reducer.connect(connection :: MPIConnection) = connect(connection)
reducer.setup(connection :: MPIConnection) = setup(connection)

include("../src/execution/main.jl")


reducer.main(backend :: Type{<: reducer.CPUBackend}) = main()

end
