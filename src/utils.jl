using Flux, Random

struct ImmutableChain{T<:Tuple}
    layers::T
end


ImmutableChain(x, y, xs...) = ImmutableChain((x, y, xs...))

Flux.children(c::ImmutableChain) = c.layers
Flux.mapchildren(f, c::ImmutableChain) = ImmutableChain(f.(c.layers))

applyall(::Tuple{}, x) = x
applyall(fs::Tuple, x) = applyall(Base.tail(fs), first(fs)(x))

(c::ImmutableChain)(x) = applyall(c.layers, x)

# Helper function to take a recursive data structure (Such as an ImmutableChain)
# and flatten it out into a tuple
@generated function flatten_tuple(t)
    stmts = Any[]
    tuple_args = Any[]
    function collect_args(t, sym)
        for i = 1:fieldcount(t)
            fT = fieldtype(t, i)
            if fT === Nothing
                continue
            end
            g = gensym()
            push!(stmts, :($g = getfield($sym, $i)))
            if !(fT <: AbstractArray)
                collect_args(fT, g)
            else
                push!(tuple_args, g)
            end
        end
    end
    collect_args(t, :t)
    return quote
        $(stmts...)
        tuple($(tuple_args...))
    end
end

# The inverse of flatten_tuple()
@generated function unflatten_tuple(pattern, t)
    function expand_arg(pattern, idx)
        fields = Any[]
        for i = 1:fieldcount(pattern)
            fT = fieldtype(pattern, i)
            if fT === Nothing
                push!(fields, nothing)
                continue
            end
            if fT <: Tuple || fT <: NamedTuple
                arg, idx = expand_arg(fT, idx)
                push!(fields, arg)
            else
                push!(fields, Expr(:call, :getfield, :t, idx))
                idx += 1
            end
        end
        Expr(:new, pattern, fields...), idx
    end
    res = expand_arg(pattern, 1)[1]
    return res
end



# Include our TPUBatchNorm object
include("tpu_batchnorm.jl")
export map_to_tpu, map_to_cpu, TPUBatchNorm, tpu
function map_to_tpu end
const tpu = map_to_tpu

## Mapping utilities
# Convert scalars to single-element XRTArrays with eltype Float32:
map_to_tpu(x::Real) = XRTArray(convert(Float32, x))

# Convert arrays to XRTArrays with eltype Float32
map_to_tpu(x::AbstractArray) = XRTArray(Float32.(x))

# Strip off the TrackedArray coating to get at the data underneath
map_to_tpu(x::TrackedArray) = map_to_tpu(Flux.data(x))

# Turn Chain objects into ImmutableChain objects which store the computation within their type signature
map_to_tpu(x::Chain) = ImmutableChain(tuple(map(map_to_tpu, x.layers)...))

# Convert BatchNorm layers into TPUBatchNorm layers, passing all children straight through,
# except for the "active" child, which is not used by the TPUBatchNorm
map_to_tpu(x::Flux.BatchNorm) = TPUBatchNorm(map(map_to_tpu, Flux.children(x))[1:end-1]...)

# We deal manually with recurrence, so Recur{T} values get turned into just T values
map_to_tpu(x::Flux.Recur) = Flux.mapchildren(map_to_tpu, x.cell)

# For all other objects, just map the children through `map_to_tpu`.
map_to_tpu(x) = Flux.mapchildren(map_to_tpu, x)


map_to_cpu(x) = Flux.mapchildren(map_to_cpu, x)
map_to_cpu(x::XRTArray) = convert(Array, x)
map_to_cpu(x::ImmutableChain) = Chain(map(map_to_cpu, x.layers)...)
map_to_cpu(x::TPUBatchNorm) = Flux.BatchNorm(map(map_to_cpu, Flux.children(x))..., false)
map_to_cpu(x::Flux.LSTMCell) = Flux.Recur(Flux.mapchildren(map_to_cpu, x))

## Layer reimplementations that need to know about XRTArray
import NNlib: softmax, logsoftmax, ∇softmax, ∇logsoftmax
import Flux: logitcrossentropy
export crossentropy, logitcrossentropy, softmax, ∇softmax, logsoftmax, ∇logsoftmax

# Work around inference limitations to dynamically find the number of
# batches held within a tensor.
neg_nbatch(x) = XRTArray(Float32(-size(x, ndims(x))))
Zygote.@nograd neg_nbatch

function crossentropy(ŷ::XRTArray, y::XRTArray)
    return sum(y .* log.(ŷ)) / neg_nbatch(y)
end

function logitcrossentropy(logŷ::XRTArray, y::XRTArray)
    return sum(y .* logsoftmax(logŷ)) / neg_nbatch(y)
end

# Define softmax and its gradient for XRTArrays
function softmax(xs::XRTArray)
    ys = xs .- maximum(xs, dims=1)
    zs = exp.(ys)
    return zs ./ sum(zs, dims=1)
end
function ∇softmax(Δ, xs::XRTArray)
    sf = softmax(xs)
    return sf .* (Δ .- sum(Δ .* sf, dims = 1))
end
Zygote.@adjoint softmax(xs::XRTArray) = softmax(xs), Δ -> (∇softmax(Δ, xs),)

# Define logsoftmax and its gradient for XRTArrays
function logsoftmax(xs::XRTArray)
    ys = xs .- maximum(xs, dims=1)
    zs = sum(exp.(ys), dims=1)
    return ys .- log.(zs)
end
∇logsoftmax(Δ, xs::XRTArray) = ∇softmax(Δ ./ max.(eps(eltype(xs)),softmax(xs)), xs)
Zygote.@adjoint logsoftmax(xs::XRTArray) = logsoftmax(xs), Δ -> (∇logsoftmax(Δ, xs),)


function Base.sort(x::XRTArray{T,<:Any,1}; keys=x) where {T}
    return XLA.HloSort{typeof(<)}(0, false)(<, keys, x)[2]
end

Base.rand(::Type{XRTArray{T}}, shape::Int...) where {T} = XLA.HloRng(T, shape, 1)(XRTArray(typemin(T)),XRTArray(typemax(T)))
Base.rand(::Type{XRTArray{F}}, shape::Int...) where {F <: AbstractFloat} = XLA.HloRng(F, shape, 1)(XRTArray(0.0f0),XRTArray(1.0f0))
Base.randn(::Type{XRTArray{F}}, shape::Int...) where {F <: AbstractFloat} = XLA.HloRng(F, shape, 2)(XRTArray(0.0f0),XRTArray(1.0f0))

# Shuffle by repeatedly sorting x with a random vector as the sorting key.
# see https://github.com/tensorflow/tensorflow/blob/85deaa11cae878ba2c0e5284085956f75434b5b2/tensorflow/compiler/tf2xla/kernels/random_ops.cc#L83-L143 for more
Base.@pure calc_rounds(L; exponent=3) = ceil(UInt32, exponent * log(L) / log(typemax(UInt32)))
function shuffle(x::XRTArray)
    round_idx = XRTArray(calc_rounds(length(x)))
    while round_idx > XRTArray(0x00000000)
        keys = rand(XRTArray{UInt32}, length(x))
        x = sort(x, keys=keys)
        round_idx -= XRTArray(0x00000001)
    end
    return x
end
