@enum ChangeKind begin
    ParameterUpdate
    StructuralUpdate
end

struct ModelChange
    revision::UInt64
    kind::ChangeKind
    entity_kind::Symbol
    slot::Int
    generation::UInt32
    fields::Vector{Symbol}
    affected_hubs::Vector{HubId}
end

struct ChangeSet
    from_revision::UInt64
    to_revision::UInt64
    changes::Vector{ModelChange}
end

mutable struct HubSystem{T<:Real}
    steps::Int
    time_step::T
    carriers::Registry{:carrier}
    hubs::Registry{:hub}
    processes::Registry{:process}
    storages::Registry{:storage}
    networks::Registry{:network}
    boundaries::Registry{:boundary}
    demands::Registry{:demand}
    recycle_links::Registry{:recycle_link}
    revision::UInt64
    changes::Vector{ModelChange}
end

function HubSystem{T}(; steps::Integer=1, time_step::Real=1) where {T<:Real}
    steps > 0 || throw(ArgumentError("steps must be positive"))
    return HubSystem{T}(
        Int(steps),
        T(time_step),
        Registry{:carrier}(),
        Registry{:hub}(),
        Registry{:process}(),
        Registry{:storage}(),
        Registry{:network}(),
        Registry{:boundary}(),
        Registry{:demand}(),
        Registry{:recycle_link}(),
        UInt64(0),
        ModelChange[],
    )
end

HubSystem(; kwargs...) = HubSystem{Float64}(; kwargs...)

function _changed!(
    system::HubSystem,
    kind::ChangeKind,
    id::EntityId{K};
    fields=Symbol[],
    affected_hubs=HubId[],
) where {K}
    system.revision += UInt64(1)
    push!(system.changes, ModelChange(
        system.revision,
        kind,
        K,
        id.slot,
        id.generation,
        collect(Symbol, fields),
        collect(HubId, affected_hubs),
    ))
    return system
end

function changesSince(system::HubSystem, revision::Integer)
    revision >= 0 || throw(ArgumentError("revision cannot be negative"))
    revision <= system.revision || throw(ArgumentError("revision $revision is newer than the system"))
    changes = ModelChange[change for change in system.changes if change.revision > revision]
    return ChangeSet(UInt64(revision), system.revision, changes)
end

isstructural(changes::ChangeSet) = any(change.kind == StructuralUpdate for change in changes.changes)

function addCarrier(system::HubSystem, carrier::Carrier)
    any(existing.name == carrier.name for (_, existing) in system.carriers) &&
        throw(ArgumentError("carrier $(carrier.name) already exists"))
    id = push!(system.carriers, carrier)
    _changed!(system, StructuralUpdate, id)
    return id
end

function addHub(system::HubSystem, hub::Hub)
    id = push!(system.hubs, hub)
    _changed!(system, StructuralUpdate, id; affected_hubs=[id])
    return id
end

function _attach!(system::HubSystem, hub_id::HubId, registry, component, field::Symbol)
    hub = system.hubs[hub_id]
    validate_component(component)
    id = push!(registry, component)
    push!(getfield(hub, field), id)
    _changed!(system, StructuralUpdate, id; affected_hubs=[hub_id])
    return id
end

addProcess(system::HubSystem, hub::HubId, process::Process) =
    _attach!(system, hub, system.processes, process, :processes)

addStorage(system::HubSystem, hub::HubId, storage::Storage) =
    _attach!(system, hub, system.storages, storage, :storages)

addBoundary(system::HubSystem, hub::HubId, boundary::Boundary) =
    _attach!(system, hub, system.boundaries, boundary, :boundaries)

addDemand(system::HubSystem, hub::HubId, demand::Demand) =
    _attach!(system, hub, system.demands, demand, :demands)

addRecycleLink(system::HubSystem, hub::HubId, link::RecycleLink) =
    _attach!(system, hub, system.recycle_links, link, :recycle_links)

function addNetwork(system::HubSystem, network::Network)
    validate_component(network)
    for located_port in network.ports
        system.hubs[located_port.hub]
        system.carriers[located_port.port.carrier]
    end
    id = push!(system.networks, network)
    affected_hubs = unique(collect(located_port.hub for located_port in network.ports))
    _changed!(system, StructuralUpdate, id; affected_hubs=affected_hubs)
    return id
end

function _detach!(system::HubSystem, hub_id::HubId, registry, id, field::Symbol)
    hub = system.hubs[hub_id]
    position = findfirst(==(id), getfield(hub, field))
    isnothing(position) && throw(ArgumentError("entity $id is not attached to hub $hub_id"))
    deleteat!(getfield(hub, field), position)
    delete!(registry, id)
    _changed!(system, StructuralUpdate, id; affected_hubs=[hub_id])
    return system
end

removeProcess(system::HubSystem, hub::HubId, id::ProcessId) =
    _detach!(system, hub, system.processes, id, :processes)

removeStorage(system::HubSystem, hub::HubId, id::StorageId) =
    _detach!(system, hub, system.storages, id, :storages)

removeBoundary(system::HubSystem, hub::HubId, id::BoundaryId) =
    _detach!(system, hub, system.boundaries, id, :boundaries)

removeDemand(system::HubSystem, hub::HubId, id::DemandId) =
    _detach!(system, hub, system.demands, id, :demands)

removeRecycleLink(system::HubSystem, hub::HubId, id::RecycleLinkId) =
    _detach!(system, hub, system.recycle_links, id, :recycle_links)

_registry(system::HubSystem, ::EntityId{:process}) = system.processes
_registry(system::HubSystem, ::EntityId{:storage}) = system.storages
_registry(system::HubSystem, ::EntityId{:network}) = system.networks
_registry(system::HubSystem, ::EntityId{:boundary}) = system.boundaries
_registry(system::HubSystem, ::EntityId{:recycle_link}) = system.recycle_links

_with_parameters(component::Process, values) =
    Process(component.name, component.ports, component.model; parameters=values)
_with_parameters(component::Storage, values) =
    Storage(component.name, component.ports, component.model; parameters=values)
_with_parameters(component::Network, values) =
    Network(component.name, component.ports, component.model; parameters=values)
_with_parameters(component::Boundary, values) =
    Boundary(component.name, component.port, component.direction, component.model; parameters=values)
_with_parameters(component::RecycleLink, values) =
    RecycleLink(component.name, component.source, component.target, component.model; parameters=values)

_merge_parameters(values::NamedTuple, updates::NamedTuple) = merge(values, updates)
_merge_parameters(values::AbstractDict, updates::NamedTuple) = merge(copy(values), Dict(pairs(updates)))

function setParameters(system::HubSystem, id::EntityId, updates::NamedTuple)
    isempty(updates) && return system
    registry = _registry(system, id)
    component = registry[id]
    declared = Set(specification.name for specification in parameters(component.model))
    unknown = setdiff(Set(keys(updates)), declared)
    isempty(unknown) || throw(ArgumentError("unknown parameters for $(component.name): $unknown"))
    values = _merge_parameters(component.parameters, updates)
    replacement = _with_parameters(component, values)
    validate_component(replacement)
    registry[id] = replacement
    _changed!(system, ParameterUpdate, id; fields=collect(keys(updates)))
    return system
end

setParameters(system::HubSystem, id::EntityId; values...) =
    setParameters(system, id, (; values...))

Base.show(io::IO, system::HubSystem) = print(
    io,
    "HubSystem(steps=", system.steps,
    ", hubs=", length(system.hubs),
    ", carriers=", length(system.carriers),
    ", revision=", system.revision,
    ")",
)

Base.show(io::IO, ::MIME"text/plain", system::HubSystem) = show(io, system)
