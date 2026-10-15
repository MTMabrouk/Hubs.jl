struct EntityId{K}
    slot::Int
    generation::UInt32

    function EntityId{K}(slot::Integer, generation::Integer=0) where {K}
        slot > 0 || throw(ArgumentError("entity slots are one-based"))
        generation >= 0 || throw(ArgumentError("entity generations cannot be negative"))
        new{K}(Int(slot), UInt32(generation))
    end
end

const CarrierId = EntityId{:carrier}
const HubId = EntityId{:hub}
const ProcessId = EntityId{:process}
const StorageId = EntityId{:storage}
const NetworkId = EntityId{:network}
const BoundaryId = EntityId{:boundary}
const DemandId = EntityId{:demand}
const RecycleLinkId = EntityId{:recycle_link}
const VariableId = EntityId{:variable}
const ParameterId = EntityId{:parameter}
const ConstraintId = EntityId{:constraint}
const BlockId = EntityId{:block}

Base.show(io::IO, id::EntityId{K}) where {K} =
    print(io, "EntityId(", K, ", ", id.slot, ", generation=", id.generation, ")")

mutable struct Registry{K}
    values::Vector{Any}
    generations::Vector{UInt32}
    active::BitVector
    free_slots::Vector{Int}
end

Registry{K}() where {K} = Registry{K}(Any[], UInt32[], BitVector(), Int[])

function Base.push!(registry::Registry{K}, value) where {K}
    if isempty(registry.free_slots)
        push!(registry.values, value)
        push!(registry.generations, UInt32(0))
        push!(registry.active, true)
        slot = length(registry.values)
    else
        slot = pop!(registry.free_slots)
        registry.values[slot] = value
        registry.active[slot] = true
    end
    return EntityId{K}(slot, registry.generations[slot])
end

function isvalid(registry::Registry{K}, id::EntityId{K}) where {K}
    return 1 <= id.slot <= length(registry.values) &&
           registry.active[id.slot] &&
           registry.generations[id.slot] == id.generation
end

function _checkvalid(registry::Registry{K}, id::EntityId{K}) where {K}
    isvalid(registry, id) || throw(InvalidStateException("stale or deleted entity ID: $id", :invalid))
    return id.slot
end

Base.getindex(registry::Registry{K}, id::EntityId{K}) where {K} =
    registry.values[_checkvalid(registry, id)]

function Base.setindex!(registry::Registry{K}, value, id::EntityId{K}) where {K}
    registry.values[_checkvalid(registry, id)] = value
    return value
end

function Base.delete!(registry::Registry{K}, id::EntityId{K}) where {K}
    slot = _checkvalid(registry, id)
    registry.values[slot] = nothing
    registry.active[slot] = false
    registry.generations[slot] += UInt32(1)
    push!(registry.free_slots, slot)
    return registry
end

Base.length(registry::Registry) = count(registry.active)

function Base.iterate(registry::Registry{K}, state::Int=1) where {K}
    slot = findnext(registry.active, state)
    isnothing(slot) && return nothing
    id = EntityId{K}(slot, registry.generations[slot])
    return ((id, registry.values[slot]), slot + 1)
end
