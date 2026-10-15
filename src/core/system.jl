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
    )
end

HubSystem(; kwargs...) = HubSystem{Float64}(; kwargs...)

_changed!(system::HubSystem) = (system.revision += UInt64(1); system)

function addCarrier(system::HubSystem, carrier::Carrier)
    any(existing.name == carrier.name for (_, existing) in system.carriers) &&
        throw(ArgumentError("carrier $(carrier.name) already exists"))
    id = push!(system.carriers, carrier)
    _changed!(system)
    return id
end

function addHub(system::HubSystem, hub::Hub)
    id = push!(system.hubs, hub)
    _changed!(system)
    return id
end

function _attach!(system::HubSystem, hub_id::HubId, registry, component, field::Symbol)
    hub = system.hubs[hub_id]
    validate_component(component)
    id = push!(registry, component)
    push!(getfield(hub, field), id)
    _changed!(system)
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
    _changed!(system)
    return id
end

function _detach!(system::HubSystem, hub_id::HubId, registry, id, field::Symbol)
    hub = system.hubs[hub_id]
    position = findfirst(==(id), getfield(hub, field))
    isnothing(position) && throw(ArgumentError("entity $id is not attached to hub $hub_id"))
    deleteat!(getfield(hub, field), position)
    delete!(registry, id)
    _changed!(system)
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

Base.show(io::IO, system::HubSystem) = print(
    io,
    "HubSystem(steps=", system.steps,
    ", hubs=", length(system.hubs),
    ", carriers=", length(system.carriers),
    ", revision=", system.revision,
    ")",
)

Base.show(io::IO, ::MIME"text/plain", system::HubSystem) = show(io, system)
