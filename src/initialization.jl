# initialization

# CUDA packages require complex initialization (discover CUDA, download artifacts, etc)
# that can't happen at module load time, so defer that to run time upon actual use.

const configured = Threads.Atomic{Int}(-1)   # -1=unconfigured, -2=configuring,
                                             # 0=failed, 1=configured

"""
    functional(show_reason=false)

Check if the package has been configured successfully and is ready to use.

This call is intended for packages that support conditionally using an available GPU. If you
fail to check whether CUDA is functional, actual use of functionality might warn and error.
"""
function functional(show_reason::Bool=false)
    try
        CUDA.version()
        CUDA.toolkit()
        return true
    catch
        show_reason || rethrow()
        return false
    end
end


## deferred initialization API

function __init__()
    # register device overrides
    precompiling = ccall(:jl_generating_output, Cint, ()) != 0
    if !precompiling
        eval(overrides)
    end
end

@noinline function __init_driver__()
    if version() < v"10.1"
        @warn "This version of CUDA.jl only supports NVIDIA drivers for CUDA 10.1 or higher (yours is for CUDA $(version()))"
    end

    # ensure that operations executed by the REPL back-end finish before returning,
    # because displaying values happens on a different task (CUDA.jl#831)
    if isdefined(Base, :active_repl_backend)
        push!(Base.active_repl_backend.ast_transforms, ex->
            quote
                try
                    $(ex)
                finally
                    $configured[] == 1 && $synchronize()
                end
            end
        )
    end

    # enable generation of FMA instructions to mimic behavior of nvcc
    LLVM.clopts("-nvptx-fma-level=1")

    return
end

function __init_toolkit__()
    if toolkit_release() < v"10.1"
        @warn "This version of CUDA.jl only supports CUDA 10.1 or higher (your toolkit provides CUDA $(toolkit_release()))"
    elseif toolkit_release() > release()
        @warn """You are using CUDA toolkit $(toolkit_release()) with a driver that only supports up to $(release()).
                 It is recommended to upgrade your driver, or switch to automatic installation of CUDA."""
    end

    return
end


## convenience functions

# TODO: update docstrings

export has_cuda, has_cuda_gpu

"""
    has_cuda()::Bool

Check whether the local system provides an installation of the CUDA driver and toolkit.
Use this function if your code loads packages that require CUDA.jl.

Note that CUDA-dependent packages might still fail to load if the installation is broken,
so it's recommended to guard against that and print a warning to inform the user:

```
using CUDA
if has_cuda()
    try
        using CuArrays
    catch ex
        @warn "CUDA is installed, but CuArrays.jl fails to load" exception=(ex,catch_backtrace())
    end
end
```
"""
has_cuda(show_reason::Bool=false) = functional(show_reason)

"""
    has_cuda_gpu()::Bool

Check whether the local system provides an installation of the CUDA driver and toolkit, and
if it contains a CUDA-capable GPU. See [`has_cuda`](@ref) for more details.

Note that this function initializes the CUDA API in order to check for the number of GPUs.
"""
has_cuda_gpu(show_reason::Bool=false) = has_cuda(show_reason) && length(devices()) > 0

# robustly get and parse an env var
function getenv(var, default::T) where T
    if haskey(ENV, var)
        result = tryparse(T, ENV[var])
        if result === nothing
            @warn "Could not parse $(var)=$(ENV[var]), using default value '$default'"
            default
        else
            result
        end
    else
        default
    end
end
