using ParallelStencil: @parallel_indices_cuda, init_parallel_stencil
using ADIOS2
using Plots
using ParallelStencil


@init_parallel_stencil(Threads, Float64, 2);

"""
  This app computes the mandelbrot set in parallel using MPI. Its used as a test app for trying ADIOS2

  Execution:
    mpiexec -n [# procs] julia test_generator.jl [side length of the square domain] [max iters on each pixel]

  There's n processes:
    x1 Master process: executes master(), assigns pieces of the domain on demand to the workers until the domain is complete
    x(n-1) Workers: receive tasks of computing the mandelbrot set on horizontal tranches of the domain and write them.
"""


"""
  Computes mandelbrot on a pixel
"""
function mandel_iter_calc(c :: ComplexF64, max_iter :: Int)
    z = c
    for n in 1:max_iter
        if abs(z) > 2
            return n
        end
        z = z * z + c
    end

    return max_iter
end

"""
  Used just to get a more desirable result image for the example, it does not have any particular semantics
"""
function convenient_function(x :: Int)::Float64
    return  1. -  1 / Float64(x)
end

"""
  Transfoms grid coordinates into number space coordinates given a domain specification
"""
function grid_transform_setup(side_dim :: Int,
                              limx_min :: Float64, limx_max :: Float64,
                              limy_min ::Float64, limy_max :: Float64)

    return (i, j) -> ComplexF64(((i - 1) / (side_dim - 1) * (limx_max - limx_min) + limx_min),
                                ((j - 1) / (side_dim - 1) * (limy_max - limy_min) + limy_min))
end

"""
  Computes a section of the set
"""
@parallel_indices (ix, iy) function worker!(
                transform :: Function, max_iter :: Int, result_buffer :: Array{Float64})
    # Execute task
    result_buffer[ix, iy] = convenient_function(
        mandel_iter_calc(
            transform(ix, iy), max_iter)
    )
    return
end



function main()

    # Domain setup
    side_dim = parse(Int, ARGS[1])

    max_iter = parse(Int, ARGS[2])

    # Buffer setup
    buffer = Float64[0. for _ in 1:side_dim, _ in 1:side_dim]

    # Setup transform
    transform = grid_transform_setup(side_dim, -2.0, 1.5, -1.5, 1.5)

    # Setup ADIOS
    adios = adios_init_serial()
    io = declare_io(adios, "IO")
    engine = open(io, "buffer.bp", mode_write)

    # Declare var
    matrix = define_variable(io, "mandel", buffer)

    # Compute mandelbrot
    @parallel (1:side_dim, 1:side_dim) worker!(transform, max_iter, buffer)

    spy(buffer)
    savefig("out.png")

    # Save computation
    put!(engine, matrix, buffer)
    perform_puts!(engine)

    close(engine)
end


main()
