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
    unit::Any
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

struct TemplateVariable{T}
    name::Symbol
    index::Int
    role::VariableRole
    domain::VariableDomain
    lower_bound::T
    upper_bound::T
    unit::Any
end

"""
The solver-independent, owner-independent expansion of a linear component model.

Column indices are local to the template. Instantiating the template only binds
those local columns to an owner's global variables and scatters parameter values.
"""
struct CompiledLinearTemplate{T}
    key::Any
    parameter_specs::Vector{ParameterSpec}
    variables::Vector{TemplateVariable{T}}
    rowptr::Vector{Int}
    local_columns::Vector{Int}
    coefficient_constants::Vector{T}
    coefficient_parameter_slots::Vector{Int}
    coefficient_multipliers::Vector{T}
    rhs::Vector{T}
    senses::Vector{ConstraintSense}
    row_names::Vector{Symbol}
    row_indices::Vector{Int}
    objective_local_columns::Vector{Int}
    objective_constants::Vector{T}
    objective_parameter_slots::Vector{Int}
    objective_multipliers::Vector{T}
end

"""
    ComponentLibrary()

Cache solver-independent component templates across component instances and
structural recompilations. A model definition is treated as immutable after it is
prepared; use a new model definition for structural changes.
"""
mutable struct ComponentLibrary
    linear_templates::Dict{Any,Any}
    linear_model_variants::IdDict{Any,Dict{Tuple{DataType,Int},Any}}
    language_model_variants::IdDict{Any,Dict{Tuple{DataType,Int},Any}}
    hits::Int
    misses::Int
end

ComponentLibrary() = ComponentLibrary(
    Dict{Any,Any}(),
    IdDict{Any,Dict{Tuple{DataType,Int},Any}}(),
    IdDict{Any,Dict{Tuple{DataType,Int},Any}}(),
    0,
    0,
)

"""Return the number of cached templates, cache hits, and cache misses."""
templateStatistics(library::ComponentLibrary) = (
    templates=length(library.linear_templates) + sum(length, values(library.language_model_variants); init=0),
    hits=library.hits,
    misses=library.misses,
)

abstract type AbstractParameterUpdate end

struct LinearCoefficientUpdate{T} <: AbstractParameterUpdate
    parameter::Symbol
    block_index::Int
    position::Int
    multiplier::T
end

struct ObjectiveCoefficientUpdate{T} <: AbstractParameterUpdate
    parameter::Symbol
    position::Int
    multiplier::T
end

mutable struct CompiledSystem{T}
    variables::Registry{:variable}
    variable_lookup::Dict{VariableKey,VariableId}
    blocks::Vector{LinearBlock{T}}
    objective::LinearObjective{T}
    parameter_updates::Dict{OwnerRef,Vector{AbstractParameterUpdate}}
    source_revision::UInt64
    component_library::ComponentLibrary
end

mutable struct CompilationContext{T}
    variables::Registry{:variable}
    variable_lookup::Dict{VariableKey,VariableId}
    blocks::Vector{LinearBlock{T}}
    objective_variable_ids::Vector{VariableId}
    objective_coefficients::Vector{T}
    parameter_updates::Dict{OwnerRef,Vector{AbstractParameterUpdate}}
end

CompilationContext{T}() where {T} = CompilationContext{T}(
    Registry{:variable}(),
    Dict{VariableKey,VariableId}(),
    LinearBlock{T}[],
    VariableId[],
    T[],
    Dict{OwnerRef,Vector{AbstractParameterUpdate}}(),
)

function _record_parameter_update!(context::CompilationContext, owner, update::AbstractParameterUpdate)
    push!(get!(Vector{AbstractParameterUpdate}, context.parameter_updates, OwnerRef(owner)), update)
    return context
end

_axis_length(specification::VariableSpec, system::HubSystem) = if isempty(specification.axes)
    1
elseif specification.axes == (:time,)
    system.steps
else
    throw(ArgumentError("unsupported variable axes $(specification.axes); currently supported axes are () and (:time,)"))
end

_axis_length(specification::VariableSpec, steps::Int) = if isempty(specification.axes)
    1
elseif specification.axes == (:time,)
    steps
else
    throw(ArgumentError("unsupported variable axes $(specification.axes); currently supported axes are () and (:time,)"))
end

_variable_index(specification::VariableSpec, position::Int) = isempty(specification.axes) ? 0 : position

_coefficient_signature(coefficient::ConstantCoefficient) = (:constant, coefficient.value)
_coefficient_signature(coefficient::ParameterCoefficient) =
    (:parameter, coefficient.parameter, coefficient.multiplier)

function _linear_template_key(model::LinearComponentModel, steps::Int, ::Type{T}) where {T}
    variable_signature = Tuple(
        (
            specification.name,
            specification.role,
            specification.domain,
            specification.lower_bound,
            specification.upper_bound,
            specification.unit,
            specification.axes,
        ) for specification in variables(model)
    )
    parameter_signature = Tuple(
        (specification.name, specification.default, specification.unit, specification.axes)
        for specification in parameters(model)
    )
    equation_signature = Tuple(
        (
            equation.name,
            equation.sense,
            equation.rhs,
            Tuple((term.variable, _coefficient_signature(term.coefficient)) for term in equation.terms),
        ) for equation in equations(model)
    )
    objective_signature = Tuple(
        (term.variable, _coefficient_signature(term.coefficient))
        for term in objective_terms(model)
    )
    return (T, steps, variable_signature, parameter_signature, equation_signature, objective_signature)
end

function _build_linear_template(model::LinearComponentModel, steps::Int, ::Type{T}, key) where {T}
    specifications = Dict(specification.name => specification for specification in variables(model))
    parameter_slots = Dict(
        specification.name => position
        for (position, specification) in enumerate(parameters(model))
    )

    template_variables = TemplateVariable{T}[]
    local_lookup = Dict{Tuple{Symbol,Int},Int}()
    for specification in variables(model)
        for position in 1:_axis_length(specification, steps)
            index = _variable_index(specification, position)
            push!(template_variables, TemplateVariable{T}(
                specification.name,
                index,
                specification.role,
                specification.domain,
                T(specification.lower_bound),
                T(specification.upper_bound),
                specification.unit,
            ))
            local_lookup[(specification.name, index)] = length(template_variables)
        end
    end

    equation_instances = Int[]
    total_rows = 0
    total_terms = 0
    for equation in equations(model)
        timed = any(specifications[term.variable].axes == (:time,) for term in equation.terms)
        instances = timed ? steps : 1
        push!(equation_instances, instances)
        total_rows += instances
        total_terms += length(equation.terms) * instances
    end

    rowptr = Vector{Int}(undef, total_rows + 1)
    local_columns = Vector{Int}(undef, total_terms)
    coefficient_constants = zeros(T, total_terms)
    coefficient_parameter_slots = zeros(Int, total_terms)
    coefficient_multipliers = zeros(T, total_terms)
    rhs = Vector{T}(undef, total_rows)
    senses = Vector{ConstraintSense}(undef, total_rows)
    row_names = Vector{Symbol}(undef, total_rows)
    row_indices = Vector{Int}(undef, total_rows)
    rowptr[1] = 1

    row = 0
    term_position = 0
    for (equation_position, equation) in enumerate(equations(model))
        instances = equation_instances[equation_position]
        for instance in 1:instances
            row += 1
            row_names[row] = equation.name
            row_indices[row] = instances == 1 ? 0 : instance
            rhs[row] = T(equation.rhs)
            senses[row] = equation.sense
            for term in equation.terms
                term_position += 1
                specification = specifications[term.variable]
                local_index = isempty(specification.axes) ? 0 : instance
                local_columns[term_position] = local_lookup[(term.variable, local_index)]
                if term.coefficient isa ConstantCoefficient
                    coefficient_constants[term_position] = T(term.coefficient.value)
                else
                    coefficient_parameter_slots[term_position] = parameter_slots[term.coefficient.parameter]
                    coefficient_multipliers[term_position] = T(term.coefficient.multiplier)
                end
            end
            rowptr[row + 1] = term_position + 1
        end
    end

    objective_count = sum(
        _axis_length(specifications[term.variable], steps)
        for term in objective_terms(model);
        init=0,
    )
    objective_local_columns = Vector{Int}(undef, objective_count)
    objective_constants = zeros(T, objective_count)
    objective_parameter_slots = zeros(Int, objective_count)
    objective_multipliers = zeros(T, objective_count)
    objective_position = 0
    for term in objective_terms(model)
        specification = specifications[term.variable]
        for position in 1:_axis_length(specification, steps)
            objective_position += 1
            index = _variable_index(specification, position)
            objective_local_columns[objective_position] = local_lookup[(term.variable, index)]
            if term.coefficient isa ConstantCoefficient
                objective_constants[objective_position] = T(term.coefficient.value)
            else
                objective_parameter_slots[objective_position] = parameter_slots[term.coefficient.parameter]
                objective_multipliers[objective_position] = T(term.coefficient.multiplier)
            end
        end
    end

    return CompiledLinearTemplate{T}(
        key,
        copy(parameters(model)),
        template_variables,
        rowptr,
        local_columns,
        coefficient_constants,
        coefficient_parameter_slots,
        coefficient_multipliers,
        rhs,
        senses,
        row_names,
        row_indices,
        objective_local_columns,
        objective_constants,
        objective_parameter_slots,
        objective_multipliers,
    )
end

"""
    prepareModel(library, model; steps=1, numeric_type=Float64)

Expand a linear component definition into a reusable local sparse template. Calls
with the same model, numeric type, and time-axis length reuse the cached template.
"""
function prepareModel(
    library::ComponentLibrary,
    model::LinearComponentModel;
    steps::Integer=1,
    numeric_type::Type{T}=Float64,
) where {T<:Real}
    steps > 0 || throw(ArgumentError("steps must be positive"))
    variant_key = (T, Int(steps))
    variants = get!(library.linear_model_variants, model) do
        Dict{Tuple{DataType,Int},Any}()
    end
    if haskey(variants, variant_key)
        library.hits += 1
        return variants[variant_key]::CompiledLinearTemplate{T}
    end

    key = _linear_template_key(model, variant_key[2], T)
    if haskey(library.linear_templates, key)
        library.hits += 1
        template = library.linear_templates[key]::CompiledLinearTemplate{T}
        variants[variant_key] = template
        return template
    end
    template = _build_linear_template(model, variant_key[2], T, key)
    library.linear_templates[key] = template
    variants[variant_key] = template
    library.misses += 1
    return template
end

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
                specification.unit,
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

function _instantiate_template!(
    context::CompilationContext{T},
    owner,
    template::CompiledLinearTemplate{T},
    parameter_values,
) where {T}
    owner_ref = OwnerRef(owner)
    local_variable_ids = Vector{VariableId}(undef, length(template.variables))
    for (position, specification) in enumerate(template.variables)
        key = VariableKey(owner_ref, specification.name, specification.index)
        haskey(context.variable_lookup, key) && throw(ArgumentError("duplicate compiled variable $key"))
        variable = CompiledVariable{T}(
            key,
            specification.role,
            specification.domain,
            specification.lower_bound,
            specification.upper_bound,
            specification.unit,
        )
        id = push!(context.variables, variable)
        context.variable_lookup[key] = id
        local_variable_ids[position] = id
    end

    resolved_parameters = Vector{T}(undef, length(template.parameter_specs))
    for (position, specification) in enumerate(template.parameter_specs)
        resolved_parameters[position] = T(parameter_value(specification, parameter_values))
    end

    block_index = length(context.blocks) + 1
    variable_ids = Vector{VariableId}(undef, length(template.local_columns))
    coefficients = copy(template.coefficient_constants)
    for position in eachindex(template.local_columns)
        variable_ids[position] = local_variable_ids[template.local_columns[position]]
        parameter_slot = template.coefficient_parameter_slots[position]
        if parameter_slot != 0
            multiplier = template.coefficient_multipliers[position]
            coefficients[position] = multiplier * resolved_parameters[parameter_slot]
            _record_parameter_update!(context, owner, LinearCoefficientUpdate{T}(
                template.parameter_specs[parameter_slot].name,
                block_index,
                position,
                multiplier,
            ))
        end
    end

    rows = Vector{ConstraintKey}(undef, length(template.row_names))
    for position in eachindex(rows)
        rows[position] = ConstraintKey(
            owner_ref,
            template.row_names[position],
            template.row_indices[position],
        )
    end
    push!(context.blocks, LinearBlock{T}(
        owner_ref,
        copy(template.rowptr),
        variable_ids,
        coefficients,
        copy(template.rhs),
        copy(template.senses),
        rows,
    ))

    objective_start = length(context.objective_variable_ids)
    objective_count = length(template.objective_local_columns)
    sizehint!(context.objective_variable_ids, objective_start + objective_count)
    sizehint!(context.objective_coefficients, objective_start + objective_count)
    for position in eachindex(template.objective_local_columns)
        push!(
            context.objective_variable_ids,
            local_variable_ids[template.objective_local_columns[position]],
        )
        parameter_slot = template.objective_parameter_slots[position]
        coefficient = template.objective_constants[position]
        if parameter_slot != 0
            multiplier = template.objective_multipliers[position]
            coefficient = multiplier * resolved_parameters[parameter_slot]
            _record_parameter_update!(context, owner, ObjectiveCoefficientUpdate{T}(
                template.parameter_specs[parameter_slot].name,
                objective_start + position,
                multiplier,
            ))
        end
        push!(context.objective_coefficients, coefficient)
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

function _compile_registry!(
    context::CompilationContext{T},
    system::HubSystem,
    registry,
    library::ComponentLibrary,
) where {T}
    for (id, component) in registry
        component.model isa NoModel && continue
        if component.model isa LinearComponentModel
            template = prepareModel(
                library,
                component.model;
                steps=system.steps,
                numeric_type=T,
            )
            _instantiate_template!(context, id, template, component.parameters)
        elseif component.model isa LanguageComponentModel
            _register_variables!(context, system, id, component.model)
            _compile_language_component!(context, system, id, component, library)
        elseif component.model isa SymbolicComponentModel
            _register_variables!(context, system, id, component.model)
        else
            throw(ArgumentError("unsupported component model $(typeof(component.model))"))
        end
    end
    return context
end

function compile_linear(
    system::HubSystem{T};
    library::ComponentLibrary=ComponentLibrary(),
) where {T}
    context = CompilationContext{T}()
    _compile_registry!(context, system, system.processes, library)
    _compile_registry!(context, system, system.storages, library)
    _compile_registry!(context, system, system.networks, library)
    _compile_registry!(context, system, system.boundaries, library)

    for (hub_id, hub) in system.hubs
        _compile_hub_block(context, system, hub_id, hub)
    end

    return CompiledSystem{T}(
        context.variables,
        context.variable_lookup,
        context.blocks,
        LinearObjective{T}(context.objective_variable_ids, context.objective_coefficients),
        context.parameter_updates,
        system.revision,
        library,
    )
end

function _component(system::HubSystem, owner::OwnerRef)
    id = EntityId{owner.kind}(owner.slot, owner.generation)
    registry = if owner.kind == :process
        system.processes
    elseif owner.kind == :storage
        system.storages
    elseif owner.kind == :network
        system.networks
    elseif owner.kind == :boundary
        system.boundaries
    elseif owner.kind == :recycle_link
        system.recycle_links
    else
        throw(ArgumentError("entity $(owner.kind) does not carry parameters"))
    end
    return registry[id]
end

function _apply_parameter_update!(compiled::CompiledSystem, update::LinearCoefficientUpdate, values)
    compiled.blocks[update.block_index].coefficients[update.position] =
        update.multiplier * values[update.parameter]
    return nothing
end

function _apply_parameter_update!(compiled::CompiledSystem, update::ObjectiveCoefficientUpdate, values)
    compiled.objective.coefficients[update.position] = update.multiplier * values[update.parameter]
    return nothing
end

function _changed_parameter_owners(compiled::CompiledSystem, system::HubSystem)
    changes = changesSince(system, compiled.source_revision)
    isstructural(changes) && throw(ArgumentError(
        "structural changes exist after revision $(compiled.source_revision); use recompileStructure",
    ))
    owners = OwnerRef[]
    for change in changes.changes
        change.kind == ParameterUpdate || continue
        owner = OwnerRef(change.entity_kind, change.slot, change.generation)
        owner in owners || push!(owners, owner)
    end
    return changes, owners
end

function _refresh_owner_parameters!(compiled::CompiledSystem, system::HubSystem, owner::OwnerRef)
    component = _component(system, owner)
    values = _resolved_parameters(component.model, component.parameters)
    for update in get(compiled.parameter_updates, owner, AbstractParameterUpdate[])
        _apply_parameter_update!(compiled, update, values)
    end
    return compiled
end

function refreshParameters(compiled::CompiledSystem, system::HubSystem)
    changes, owners = _changed_parameter_owners(compiled, system)
    for owner in owners
        _refresh_owner_parameters!(compiled, system, owner)
    end
    compiled.source_revision = changes.to_revision
    return compiled
end
