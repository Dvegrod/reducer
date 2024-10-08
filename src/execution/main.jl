


global logfile = undef

"""
  Works like an array squeeze function but for tuples (deletes unused dimensions)
 (sometimes it is not needed to do this but the adios API does need it often for proper transfer)
"""
function collapseDims(shape :: Tuple)
    tmp = Int[]
    for i in shape
        if i > 1
            push!(tmp, i)
        end
    end
    return Tuple(tmp)
end

"""
  Works like an array squeeze function but for tuples (deletes unused dimensions)

  The particularity here is that unused dims on the second tuple will be used to delete dimensions on the first.

  e.g ((3,2,1), (100,100,1)) -> (3,2)
"""
function collapseDims(start :: Tuple, shape :: Tuple)
    tmp = Int[]
    for i in 1:3
        if shape[i] > 1
            push!(tmp, start[i])
        end
    end
    return Tuple(tmp)
end

"""
  Used to access the input ADIOS2 stream where the data from the supplier is obtained to be reduced.
"""
function get_input(io :: ADIOS2.AIO, engine::ADIOS2.Engine,
                   var_name :: String, start :: Tuple, size :: Tuple) :: Data.Array

    y = inquire_variable(io, var_name)

    if isnothing(y)
        e = ArgumentError("Invalid value, it is not available on the specified IO")
        throw(e)
    end

    @debug start,size
    set_selection(y, collapseDims(start, size), collapseDims(size))

    array = Data.Array(undef, collapseDims(size)...)

    get(engine, y, array)

    perform_gets(engine)

    @debug sum(array)

    # Reshape will expand dims if needed
    return reshape(array, size)
end


"""
  This routine is used to properly invoke the execution of a reduction layer. Depending on the kind the invocation changes.
  It is important to note that for dynamic custom operations a `invokelatest` is required, which may slow down the function call a bit.
"""
function execute_layer!(input :: Data.Array, layer :: LocalLayer)

    id = layer.operator_id
    kind = layer.operator_kind
    if kind == 0 # BUILT IN
        @parallel (1:layer.output_shape[1], 1:layer.output_shape[2], 1:layer.output_shape[3]) reduction_functions![layer.operator_id](input, layer.out_buffer)
    elseif kind == 1 # CUSTOM STATIC
        @parallel (1:layer.output_shape[1], 1:layer.output_shape[2], 1:layer.output_shape[3]) custom_reduction_functions![layer.operator_id](input, layer.out_buffer)
    else    # CUSTOM DYNAMIC
        @parallel (1:layer.output_shape[1], 1:layer.output_shape[2], 1:layer.output_shape[3]) invokelatest(custom_reduction_functions![-1 * id], input, layer.out_buffer)
    end
end

"""
  This routine publishes the output of a pipe in the corresponding ADIOS2 stream
"""
function submit_output(io::ADIOS2.AIO, engine::ADIOS2.Engine, input::LocalLayer, global_shape)

    # TODO NOT REDEFINE
    @debug collapseDims(input.output_start, input.output_shape), collapseDims(input.output_shape)

    # NOTE THIS WILL TRIGGER AN ERROR ON VERY SMALL DOMAINS
    define_variable(io, "out", Float64, collapseDims(global_shape), collapseDims(input.output_start, input.output_shape), collapseDims(input.output_shape))

    y = inquire_variable(io, "out")

    if isnothing(y)
        e = ArgumentError("Out var has not been defined yet")
        throw(e)
    end

    @debug input.output_start, input.output_shape, global_shape

    put!(engine, y, input.out_buffer)
    perform_puts!(engine)
end


"""
  This routine carries the execution of a pipe. It contains a loop that iterates thorugh input steps and computes the reduction of them by applying the layers sequentially.
"""
function reduction_execution(e :: ExecutionInstance)
    # STEP LOOP
    while begin_step(e.input_engine) == step_status_ok

        begin_step(e.output_engine)
        @warn "STEP"
        # INPUT CHUNK
        output = get_input(e.input_IO, e.input_engine,
                           e.pipeline_config[:var_name],
                           input_start(e), input_shape(e))


        # PROCESS CHUNK
        for i in 1:e.pipeline_config[:n_layers]
            execute_layer!(i == 1 ? output : e.localized_layers[i - 1].out_buffer, e.localized_layers[i])
        end

        # OUTPUT CHUNK TODO SIMPLIFY
        submit_output(e.output_IO, e.output_engine, e.localized_layers[end], e.global_output_shape)

        end_step(e.input_engine)
        end_step(e.output_engine)
    end
end

function cleanup_instance(e :: ExecutionInstance)
    close(e.input_engine)
    close(e.output_engine)
    GC.gc()
end

"""
  Used to obtain the path to dynamic custom operations. Those will then be added into the register to be used in pipes.
"""
function includeCustoms(conn)
    c = MPIConnection(conn.location, conn.side, 1, conn.comm)
    path = ParallelReductionPipes._get(c, :custom)
    path = isabspath(path) ? path : joinpath(pwd(), path)

    if path isa Nothing
        @debug "No customs detected"
        return
    else
        loadCustomOperations(path)
    end
end


# THERE ARE 4 ADIOS STREAMS GOING ON
#   A. CONTROL PLANE (BP5) (called comm in variable names)
#      1. Runtime writes (i.e. to send status to listeners)
#      2. Runtime reads (i.e to get config parameters)
#   B. DATA PLANE (BP5 or SST)
#      1. Input data
#      2. Output data


"""
  The main routine of the runtime, which incorporates a loop that
  processes pipes.
"""
function main(connection_location :: String)
    # Initialization
    # MPI
    MPI.Init()

    loadStaticCustomOperations()

    rank = MPI.Comm_rank(MPI.COMM_WORLD)
    size = MPI.Comm_size(MPI.COMM_WORLD)


    # Pipeline adios

    # Flag parse
    for i in ARGS
        if i in keys(flags)
            # Switch flag
            flags[i] = !flags[i]
        end
    end
    # The default is to have the connection located at ./connection
    connection_location = connection_location != "" ? connection_location : "connection"

    connection = MPIConnection(connection_location, true, 10000, MPI.COMM_WORLD)


    last_id = 0
    while true

        @debug "ON LOOP"
        # LISTEN FOR CONFIGURATION ARRIVAL
        ready(connection, 1)
        if !listen(connection, last_id)
            @debug "No new pipes"
            sleep(1)
            continue
        end
        last_id = ParallelReductionPipes._get(connection, :ready)


        # Get pipeline config
        @debug "ON CONNECT"
        ar,ir,er = connect(connection)
        pipeline_vars = ParallelReductionPipes.inquirePipelineConfigurationStructure(ir)
        pipeline_config = ParallelReductionPipes.getPipelineConfigurationStructure(er, pipeline_vars)

        # Check if there are custom kernels
        includeCustoms(connection)
        @debug custom_reduction_functions!

        ready(connection, 2)

        # ADIOS INIT INPUT STREAM
        adios = adios_init_mpi(pipeline_config[:config], MPI.COMM_WORLD)
        input_io = declare_io(adios, "INPUT_IO")

        input_engine = nothing

        while true

        input_engine = open(input_io, pipeline_config[:engine], mode_read)#pipeline_config[:engine], mode_read)
        if input_engine isa Nothing
            @error "Unable to connect to the input, maybe it is not online"
            sleep(2)
        else
            break
        end

        end

        @debug "ON OUTPUT"
        # ADIOS INIT OUTPUT STREAM
        output_io = declare_io(adios, "OUTPUT_IO")

        output_engine = open(output_io, joinpath(connection_location, "reducer-o.bp"), mode_write)

        @warn "Reached pipeline beginning"


        dims = calculateDims(size, Tuple(pipeline_config[:var_shape]))
        @show dims

        # Calculate local pipeline shapes
        layers = calculateShape(pipeline_config[:layer_config], Tuple(pipeline_config[:var_shape]), pipeline_config[:n_layers], rank, Tuple(dims))

        #@debug layers

        @debug "ON EXEC"
        exec_instance = ExecutionInstance(
            last_id,
            rank,
            size,
            Tuple(dims),
            input_io,
            output_io,
            input_engine,
            output_engine,
            pipeline_config,
            layers,
            Tuple(pipeline_config[:layer_config][pipeline_config[:n_layers], 5:7])
        )

        reduction_execution(exec_instance)
        cleanup_instance(exec_instance)

        ready(connection, 1)
    end

    MPI.Finalize()

end

