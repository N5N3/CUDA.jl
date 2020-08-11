module DummyPool

# dummy allocator that passes through any requests, calling into the GC if that fails.

using ..CUDA
using ..CUDA: @pool_timeit, @safe_lock, @safe_lock_spin, NonReentrantLock, PerDevice, initialize!

using Base: @lock

const allocated_lock = NonReentrantLock()
const allocated = PerDevice{Dict{CuPtr,Int}}() do dev
    Dict{CuPtr,Int}()
end

function init()
    initialize!(allocated, ndevices())
end

function alloc(sz, dev=device())
    ptr = nothing
    for phase in 1:3
        if phase == 2
            @pool_timeit "$phase.0 gc (incremental)" GC.gc(false)
        elseif phase == 3
            @pool_timeit "$phase.0 gc (full)" GC.gc(true)
        end

        @pool_timeit "$phase.1 alloc" begin
            ptr = CUDA.actual_alloc(dev, sz)
        end
        ptr === nothing || break
    end

    if ptr !== nothing
        @safe_lock allocated_lock begin
            allocated[dev][ptr] = sz
        end
        return ptr
    else
        return nothing
    end
end

function free(ptr, dev=device())
    sz = @safe_lock_spin allocated_lock begin
        sz = allocated[dev][ptr]
        delete!(allocated[dev], ptr)
        sz
    end

    CUDA.actual_free(dev, ptr, sz)
    return
end

reclaim(target_bytes::Int=typemax(Int)) = return 0

used_memory(dev=device()) = @safe_lock allocated_lock begin
    mapreduce(sizeof, +, values(allocated[dev]); init=0)
end

cached_memory() = 0

end
