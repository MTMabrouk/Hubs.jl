@enum PortDirection begin
    Input
    Output
    Bidirectional
end

@enum BoundaryDirection begin
    Import
    Export
end

abstract type AbstractComponentModel end
struct NoModel <: AbstractComponentModel end

struct Carrier{U,M}
    name::Symbol
    unit::U
    metadata::M
end

Carrier(name::Union{Symbol,AbstractString}; unit=nothing, metadata=NamedTuple()) =
    Carrier(Symbol(name), unit, metadata)

struct Port
    name::Symbol
    carrier::CarrierId
    direction::PortDirection
    variable::Symbol
end

Port(name::Union{Symbol,AbstractString}, carrier::CarrierId, direction::PortDirection; variable=name) =
    Port(Symbol(name), carrier, direction, Symbol(variable))

struct LocatedPort
    hub::HubId
    port::Port
end

struct Process{M<:AbstractComponentModel,P}
    name::Symbol
    ports::Vector{Port}
    model::M
    parameters::P
end

Process(name::Union{Symbol,AbstractString}, ports, model::AbstractComponentModel=NoModel(); parameters=NamedTuple()) =
    Process(Symbol(name), collect(Port, ports), model, parameters)

struct Storage{M<:AbstractComponentModel,P}
    name::Symbol
    ports::Vector{Port}
    model::M
    parameters::P
end

Storage(name::Union{Symbol,AbstractString}, ports, model::AbstractComponentModel=NoModel(); parameters=NamedTuple()) =
    Storage(Symbol(name), collect(Port, ports), model, parameters)

struct Network{M<:AbstractComponentModel,P}
    name::Symbol
    ports::Vector{LocatedPort}
    model::M
    parameters::P
end

Network(name::Union{Symbol,AbstractString}, ports, model::AbstractComponentModel=NoModel(); parameters=NamedTuple()) =
    Network(Symbol(name), collect(LocatedPort, ports), model, parameters)

struct Boundary{M<:AbstractComponentModel,P}
    name::Symbol
    port::Port
    direction::BoundaryDirection
    model::M
    parameters::P
end

Boundary(name::Union{Symbol,AbstractString}, port::Port, direction::BoundaryDirection, model::AbstractComponentModel=NoModel(); parameters=NamedTuple()) =
    Boundary(Symbol(name), port, direction, model, parameters)

struct Demand{P}
    name::Symbol
    port::Port
    profile::P
end

Demand(name::Union{Symbol,AbstractString}, port::Port, profile) =
    Demand(Symbol(name), port, profile)

struct PortReference{K}
    component::EntityId{K}
    port::Symbol
end

PortReference(component::EntityId{K}, port::Union{Symbol,AbstractString}) where {K} =
    PortReference{K}(component, Symbol(port))

struct RecycleLink{S,T,M<:AbstractComponentModel,P}
    name::Symbol
    source::S
    target::T
    model::M
    parameters::P
end

RecycleLink(name::Union{Symbol,AbstractString}, source::PortReference, target::PortReference, model::AbstractComponentModel=NoModel(); parameters=NamedTuple()) =
    RecycleLink(Symbol(name), source, target, model, parameters)

mutable struct Hub
    name::Symbol
    processes::Vector{ProcessId}
    storages::Vector{StorageId}
    boundaries::Vector{BoundaryId}
    demands::Vector{DemandId}
    recycle_links::Vector{RecycleLinkId}
end

Hub(name::Union{Symbol,AbstractString}) =
    Hub(Symbol(name), ProcessId[], StorageId[], BoundaryId[], DemandId[], RecycleLinkId[])

Base.show(io::IO, carrier::Carrier) = print(io, "Carrier(name=", repr(carrier.name), ")")
Base.show(io::IO, process::Process) = print(io, "Process(name=", repr(process.name), ", ports=", length(process.ports), ")")
Base.show(io::IO, storage::Storage) = print(io, "Storage(name=", repr(storage.name), ", ports=", length(storage.ports), ")")
Base.show(io::IO, network::Network) = print(io, "Network(name=", repr(network.name), ", ports=", length(network.ports), ")")
Base.show(io::IO, hub::Hub) = print(io, "Hub(name=", repr(hub.name), ", processes=", length(hub.processes), ")")

for DomainType in (Carrier, Process, Storage, Network, Hub)
    @eval Base.show(io::IO, ::MIME"text/plain", value::$DomainType) = show(io, value)
end
