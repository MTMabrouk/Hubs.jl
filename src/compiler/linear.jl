struct OwnerRef
    kind::Symbol
    slot::Int
    generation::UInt32
end

OwnerRef(id::EntityId{K}) where {K} = OwnerRef(K, id.slot, id.generation)

struct VariableKey
    owner::OwnerRef
    name::Symbol
    index::Int
end

struct CompiledVariable{T}
    key::VariableKey
    role::VariableRole
    domain::VariableDomain
    lower_bound::T
    upper_bound::T
end

struct ConstraintKey
    owner::OwnerRef
    name::Symbol
    index::Int
end

struct LinearBlock{T}
    owner::OwnerRef
    rowptr::Vector{Int}
    variable_ids::Vector{VariableId}
    coefficients::Vector{T}
    rhs::Vector{T}
    senses::Vector{ConstraintSense}
    rows::Vector{ConstraintKey}
end

Base.length(block::LinearBlock) = length(block.rhs)

struct LinearObjective{T}
    variable_ids::Vector{VariableId}
    coefficients::Vector{T}
end

struct CompiledSystem{T}
    variables::Registry{:variable}
    variable_lookup::Dict{VariableKey,VariableId}
    blocks::Vector{LinearBlock{T}}
    objective::LinearObjective{T}
    source_revision::UInt64
end

mutable struct CompilationContext{T}
    variables::Registry{:variable}
    variable_lookup::Dict{VariableKey,VariableId}
    blocks::Vector{LinearBlock{T}}
    objective_variable_ids::Vector{VariableId}
    objective_coefficients::Vector{T}
end

CompilationContext{T}() where {T} = CompilationContext{T}(
    Registry{:variable}(),
    Dict{VariableKey,VariableId}(),
    LinearBlock{T}[],
    VariableId[],
    T[],
)

_axis_length(specification::VariableSpec, system::HubSystem) = if isempty(specification.axes)
    1
elseif specification.axes == (:time,)
    system.steps
else
    throw(ArgumentError("unsupported variable axes $(specification.axes); currently supported axes are () and (:time,)"))
end

_variable_index(specification::VariableSpec, position::Int) = isempty(specification.axes) ? 0 : position

function _register_variables!(context::CompilationContext{T}, system::HubSystem, owner, model) where {T}
    for specification in variables(model)
        for position in 1:_axis_length(specification, system)
            key = VariableKey(OwnerRef(owner), specification.name, _variable_index(specification, position))
            haskey(context.variable_lookup, key) && throw(ArgumentError("duplicate compiled variable $key"))
            variable = CompiledVariable{T}(
                key,
                specification.role,
                specification.domain,
                T(specification.lower_bound),
                T(specification.upper_bound),
            )
            id = push!(context.variables, variable)
            context.variable_lookup[key] = id
        end
    end
    return context
end

function variable_id(compiled::CompiledSystem, owner::EntityId, name::Union{Symbol,AbstractString}, index::Integer=0)
    key = VariableKey(OwnerRef(owner), Symbol(name), Int(index))
    return get(compiled.variable_lookup, key) do
        throw(KeyError(key))
    end
end

function _resolved_parameters(model, values)
    resolved = Dict{Symbol,Any}()
    for specification in parameters(model)
        resolved[specification.name] = parameter_value(specification, values)
    end
    return resolved
end

function _equation_instances(equation::LinearEquation, model::LinearComponentModel, system::HubSystem)
    by_name = Dict(specification.name => specification for specification in variables(model))
    timed = any(by_name[term.variable].axes == (:time,) for term in equation.terms)
    return timed ? system.steps : 1
end

function _compile_component_block(
    context::CompilationContext{T},
    system::HubSystem,
    owner,
    model::LinearComponentModel,
    parameter_values,
) where {T}
    total_rows = sum(
        (_equation_instances(equation, model, system) for equation in equations(model));
        init=0,
    )
    total_terms = sum(
        length(equation.terms) * _equation_instances(equation, model, system)
        for equation in equations(model);
        init=0,
    )

    rowptr = Vector{Int}(undef, total_rows + 1)
    variable_ids = Vector{VariableId}(undef, total_terms)
    coefficients = Vector{T}(undef, total_terms)
    rhs = Vector{T}(undef, total_rows)
    senses = Vector{ConstraintSense}(undef, total_rows)
    rows = Vector{ConstraintKey}(undef, total_rows)
    rowptr[1] = 1

    specifications = Dict(specification.name => specification for specification in variables(model))
    parameter_map = _resolved_parameters(model, parameter_values)
    row = 0
    term_position = 0
    for equation in equations(model)
        instances = _equation_instances(equation, model, system)
        for instance in 1:instances
            row += 1
            rows[row] = ConstraintKey(OwnerRef(owner), equation.name, instances == 1 ? 0 : instance)
            rhs[row] = T(equation.rhs)
            senses[row] = equation.sense
            for term in equation.terms
                term_position += 1
                specification = specifications[term.variable]
                variable_index = isempty(specification.axes) ? 0 : instance
                key = VariableKey(OwnerRef(owner), term.variable, variable_index)
                variable_ids[term_position] = context.variable_lookup[key]
                coefficients[term_position] = T(coefficient_value(term.coefficient, parameter_map))
            end
            rowptr[row + 1] = term_position + 1
        end
    end

    block = LinearBlock{T}(OwnerRef(owner), rowptr, variable_ids, coefficients, rhs, senses, rows)
    push!(context.blocks, block)

    objective_count = sum(
        _axis_length(specifications[term.variable], system)
        for term in objective_terms(model);
        init=0,
    )
    sizehint!(context.objective_variable_ids, length(context.objective_variable_ids) + objective_count)
    sizehint!(context.objective_coefficients, length(context.objective_coefficients) + objective_count)
    for term in objective_terms(model)
        specification = specifications[term.variable]
        for position in 1:_axis_length(specification, system)
            index = _variable_index(specification, position)
            push!(context.objective_variable_ids, context.variable_lookup[VariableKey(OwnerRef(owner), term.variable, index)])
            push!(context.objective_coefficients, T(coefficient_value(term.coefficient, parameter_map)))
        end
    end
    return context
end

_flow_sign(direction::PortDirection) = direction == Input ? -1 : one(Int)

function _component_ports(system::HubSystem, hub::Hub)
    return (
        ((id, system.processes[id].ports, system.processes[id].model) for id in hub.processes),
        ((id, system.storages[id].ports, system.storages[id].model) for id in hub.storages),
    )
end

function _visit_hub_ports(visitor, system::HubSystem, hub_id::HubId, hub::Hub)
    for collection in _component_ports(system, hub)
        for (owner, ports, _) in collection
            for port in ports
                visitor(owner, port, _flow_sign(port.direction))
            end
        end
    end
    for boundary_id in hub.boundaries
        boundary = system.boundaries[boundary_id]
        sign = boundary.direction == Import ? 1 : -1
        visitor(boundary_id, boundary.port, sign)
    end
    for (network_id, network) in system.networks
        for located in network.ports
            located.hub == hub_id || continue
            visitor(network_id, located.port, _flow_sign(located.port.direction))
        end
    end
    return nothing
end

function _demand_profile_value(demand::Demand, time::Int, steps::Int)
    if demand.profile isa Number
        return demand.profile
    end
    length(demand.profile) == steps ||
        throw(DimensionMismatch("demand $(demand.name) has $(length(demand.profile)) values, expected $steps"))
    return demand.profile[time]
end

function _compile_hub_block(context::CompilationContext{T}, system::HubSystem, hub_id::HubId, hub::Hub) where {T}
    carrier_capacity = length(system.carriers.values)
    counts = zeros(Int, carrier_capacity)
    active = falses(carrier_capacity)

    _visit_hub_ports(system, hub_id, hub) do _, port, _
        counts[port.carrier.slot] += 1
        active[port.carrier.slot] = true
    end
    for demand_id in hub.demands
        demand = system.demands[demand_id]
        active[demand.port.carrier.slot] = true
    end

    active_carriers = findall(active)
    total_rows = length(active_carriers) * system.steps
    total_terms = sum(counts[carrier] * system.steps for carrier in active_carriers)
    rowptr = Vector{Int}(undef, total_rows + 1)
    variable_ids = Vector{VariableId}(undef, total_terms)
    coefficients = Vector{T}(undef, total_terms)
    rhs = zeros(T, total_rows)
    senses = fill(EqualTo, total_rows)
    rows = Vector{ConstraintKey}(undef, total_rows)
    rowptr[1] = 1

    carrier_row = zeros(Int, carrier_capacity)
    row = 0
    term_start = 1
    for carrier in active_carriers
        carrier_row[carrier] = row + 1
        for time in 1:system.steps
            row += 1
            rows[row] = ConstraintKey(OwnerRef(hub_id), Symbol("carrier_balance_", carrier), time)
            rowptr[row] = term_start
            term_start += counts[carrier]
            rowptr[row + 1] = term_start
        end
    end
    cursors = copy(rowptr[1:end-1])

    _visit_hub_ports(system, hub_id, hub) do owner, port, sign
        base_row = carrier_row[port.carrier.slot]
        for time in 1:system.steps
            row_index = base_row + time - 1
            position = cursors[row_index]
            key = VariableKey(OwnerRef(owner), port.variable, time)
            variable_ids[position] = get(context.variable_lookup, key) do
                throw(ArgumentError("port $(port.name) must expose a (:time,) variable"))
            end
            coefficients[position] = T(sign)
            cursors[row_index] += 1
        end
    end

    for demand_id in hub.demands
        demand = system.demands[demand_id]
        base_row = carrier_row[demand.port.carrier.slot]
        for time in 1:system.steps
            rhs[base_row + time - 1] += T(_demand_profile_value(demand, time, system.steps))
        end
    end

    push!(context.blocks, LinearBlock{T}(
        OwnerRef(hub_id), rowptr, variable_ids, coefficients, rhs, senses, rows,
    ))
    return context
end

function _compile_registry!(context::CompilationContext{T}, system::HubSystem, registry) where {T}
    for (id, component) in registry
        component.model isa NoModel && continue
        _register_variables!(context, system, id, component.model)
    end
    for (id, component) in registry
        component.model isa NoModel && continue
        if component.model isa LinearComponentModel
            _compile_component_block(context, system, id, component.model, component.parameters)
        elseif !(component.model isa SymbolicComponentModel)
            throw(ArgumentError("unsupported component model $(typeof(component.model))"))
        end
    end
    return context
end

function compile_linear(system::HubSystem{T}) where {T}
    context = CompilationContext{T}()
    _compile_registry!(context, system, system.processes)
    _compile_registry!(context, system, system.storages)
    _compile_registry!(context, system, system.networks)
    _compile_registry!(context, system, system.boundaries)

    for (hub_id, hub) in system.hubs
        _compile_hub_block(context, system, hub_id, hub)
    end

    return CompiledSystem{T}(
        context.variables,
        context.variable_lookup,
        context.blocks,
        LinearObjective{T}(context.objective_variable_ids, context.objective_coefficients),
        system.revision,
    )
end
