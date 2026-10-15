struct NonlinearTemplate{F,J,S}
    key::UInt64
    variable_names::Vector{Symbol}
    parameter_names::Vector{Symbol}
    residuals::Vector{Any}
    jacobian_sparsity::S
    residual_function::F
    jacobian_function::J
end

struct NonlinearInstance{T}
    template_key::UInt64
    owner::OwnerRef
    index::Int
    variable_ids::Vector{VariableId}
    parameters::Vector{T}
end

struct SymbolicAffineUpdate{F} <: AbstractParameterUpdate
    parameter_names::Vector{Symbol}
    block_index::Int
    coefficient_count::Int
    value_function::F
end

struct HybridCompiledSystem{T}
    linear::CompiledSystem{T}
    nonlinear_templates::Dict{UInt64,NonlinearTemplate}
    nonlinear_instances::Vector{NonlinearInstance{T}}
end

evaluate_residuals(template::NonlinearTemplate, variables, parameters) =
    template.residual_function(variables, parameters)

evaluate_jacobian(template::NonlinearTemplate, variables, parameters) =
    template.jacobian_function(variables, parameters)

_is_affine(model::SymbolicComponentModel, residual) =
    Symbolics.isaffine(residual, symbolic_variables(model))

function _template_key(model::SymbolicComponentModel, nonlinear_residuals)
    signature = (
        map(specification -> (specification.name, specification.axes), variables(model)),
        map(specification -> specification.name, parameters(model)),
        string.(nonlinear_residuals),
    )
    return UInt64(hash(signature))
end

function _compile_template(model::SymbolicComponentModel, nonlinear_residuals)
    symbolic_x = symbolic_variables(model)
    symbolic_p = symbolic_parameters(model)
    jacobian = Symbolics.jacobian(nonlinear_residuals, symbolic_x)
    sparsity = Symbolics.jacobian_sparsity(nonlinear_residuals, symbolic_x)
    residual_functions = Symbolics.build_function(
        nonlinear_residuals,
        symbolic_x,
        symbolic_p;
        expression=Val(false),
    )
    jacobian_functions = Symbolics.build_function(
        jacobian,
        symbolic_x,
        symbolic_p;
        expression=Val(false),
    )
    residual_function = residual_functions isa Tuple ? first(residual_functions) : residual_functions
    jacobian_function = jacobian_functions isa Tuple ? first(jacobian_functions) : jacobian_functions
    return NonlinearTemplate(
        _template_key(model, nonlinear_residuals),
        map(specification -> specification.name, variables(model)),
        map(specification -> specification.name, parameters(model)),
        Any[nonlinear_residuals...],
        sparsity,
        residual_function,
        jacobian_function,
    )
end

function _symbolic_parameter_map(model::SymbolicComponentModel, values)
    replacements = Dict{Any,Any}()
    for (specification, symbol) in zip(parameters(model), symbolic_parameters(model))
        replacements[symbol] = parameter_value(specification, values)
    end
    return replacements
end

function _symbolic_number(expression, replacements)
    substituted = Symbolics.substitute(expression, replacements)
    return Symbolics.value(substituted)
end

function _residual_instances(model::SymbolicComponentModel, residual, system::HubSystem)
    present = Set(Symbolics.get_variables(residual))
    for (specification, symbol) in zip(variables(model), symbolic_variables(model))
        symbol in present && specification.axes == (:time,) && return system.steps
    end
    return 1
end

function _compile_affine_symbolic_block(
    compiled::CompiledSystem{T},
    system::HubSystem,
    owner,
    model::SymbolicComponentModel,
    parameter_values,
    affine_residuals,
    block_index::Int,
) where {T}
    isempty(affine_residuals) && return (nothing, nothing)
    variable_specs = variables(model)
    symbolic_x = symbolic_variables(model)
    replacements = _symbolic_parameter_map(model, parameter_values)
    zero_replacements = Dict{Any,Any}()
    for symbol in symbolic_x
        zero_replacements[symbol] = zero(T)
    end

    coefficients_by_residual = Vector{Vector{T}}(undef, length(affine_residuals))
    coefficient_expressions_by_residual = Vector{Vector{Any}}(undef, length(affine_residuals))
    constants = Vector{T}(undef, length(affine_residuals))
    constant_expressions = Vector{Any}(undef, length(affine_residuals))
    instances = Vector{Int}(undef, length(affine_residuals))
    total_rows = 0
    total_terms = 0
    for (residual_index, residual) in enumerate(affine_residuals)
        coefficients = Vector{T}(undef, length(symbolic_x))
        coefficient_expressions = Vector{Any}(undef, length(symbolic_x))
        nonzeros = 0
        for variable_index in eachindex(symbolic_x)
            derivative = Symbolics.expand_derivatives(Symbolics.derivative(residual, symbolic_x[variable_index]))
            coefficient_expressions[variable_index] = derivative
            structurally_zero = iszero(Symbolics.simplify(derivative))
            coefficient = structurally_zero ? zero(T) : T(_symbolic_number(derivative, replacements))
            coefficients[variable_index] = coefficient
            nonzeros += !structurally_zero
        end
        coefficients_by_residual[residual_index] = coefficients
        coefficient_expressions_by_residual[residual_index] = coefficient_expressions
        constant_expression = Symbolics.substitute(residual, zero_replacements)
        constant_expressions[residual_index] = constant_expression
        constants[residual_index] = T(_symbolic_number(constant_expression, replacements))
        instances[residual_index] = _residual_instances(model, residual, system)
        total_rows += instances[residual_index]
        total_terms += nonzeros * instances[residual_index]
    end

    rowptr = Vector{Int}(undef, total_rows + 1)
    variable_ids = Vector{VariableId}(undef, total_terms)
    coefficient_values = Vector{T}(undef, total_terms)
    rhs = Vector{T}(undef, total_rows)
    senses = fill(EqualTo, total_rows)
    rows = Vector{ConstraintKey}(undef, total_rows)
    coefficient_expressions = Vector{Any}(undef, total_terms)
    rhs_expressions = Vector{Any}(undef, total_rows)
    rowptr[1] = 1
    row = 0
    position = 0
    for (residual_index, _) in enumerate(affine_residuals)
        for instance in 1:instances[residual_index]
            row += 1
            rows[row] = ConstraintKey(OwnerRef(owner), Symbol("symbolic_affine_", residual_index), instances[residual_index] == 1 ? 0 : instance)
            rhs[row] = -constants[residual_index]
            rhs_expressions[row] = -constant_expressions[residual_index]
            for variable_index in eachindex(variable_specs)
                coefficient = coefficients_by_residual[residual_index][variable_index]
                derivative = coefficient_expressions_by_residual[residual_index][variable_index]
                iszero(Symbolics.simplify(derivative)) && continue
                position += 1
                specification = variable_specs[variable_index]
                local_index = isempty(specification.axes) ? 0 : instance
                variable_ids[position] = compiled.variable_lookup[
                    VariableKey(OwnerRef(owner), specification.name, local_index)
                ]
                coefficient_values[position] = coefficient
                coefficient_expressions[position] = derivative
            end
            rowptr[row + 1] = position + 1
        end
    end
    block = LinearBlock{T}(
        OwnerRef(owner), rowptr, variable_ids, coefficient_values, rhs, senses, rows,
    )
    value_functions = Symbolics.build_function(
        vcat(coefficient_expressions, rhs_expressions),
        symbolic_parameters(model);
        expression=Val(false),
    )
    value_function = value_functions isa Tuple ? first(value_functions) : value_functions
    update = SymbolicAffineUpdate(
        map(specification -> specification.name, parameters(model)),
        block_index,
        length(coefficient_values),
        value_function,
    )
    return block, update
end

function _apply_parameter_update!(compiled::CompiledSystem, update::SymbolicAffineUpdate, values)
    parameter_values = [values[name] for name in update.parameter_names]
    result = update.value_function(parameter_values)
    result = result isa Tuple ? first(result) : result
    block = compiled.blocks[update.block_index]
    copyto!(block.coefficients, 1, result, 1, update.coefficient_count)
    copyto!(block.rhs, 1, result, update.coefficient_count + 1, length(block.rhs))
    return nothing
end

function _symbolic_instance_count(model::SymbolicComponentModel, residuals_to_compile, system::HubSystem)
    return any(_residual_instances(model, residual, system) == system.steps for residual in residuals_to_compile) ? system.steps : 1
end

function _compile_symbolic_component!(
    templates::Dict{UInt64,NonlinearTemplate},
    instances::Vector{NonlinearInstance{T}},
    linear_blocks::Vector{LinearBlock{T}},
    compiled::CompiledSystem{T},
    system::HubSystem,
    owner,
    component,
) where {T}
    model = component.model
    model.objective === nothing ||
        throw(ArgumentError("symbolic objectives are not implemented yet; use linear objective terms"))
    affine_residuals = Any[]
    nonlinear_residuals = Any[]
    for residual in residuals(model)
        push!(_is_affine(model, residual) ? affine_residuals : nonlinear_residuals, residual)
    end

    affine_block, affine_update = _compile_affine_symbolic_block(
        compiled,
        system,
        owner,
        model,
        component.parameters,
        affine_residuals,
        length(linear_blocks) + 1,
    )
    if !isnothing(affine_block)
        push!(linear_blocks, affine_block)
        push!(get!(Vector{AbstractParameterUpdate}, compiled.parameter_updates, OwnerRef(owner)), affine_update)
    end
    isempty(nonlinear_residuals) && return nothing

    template_key = _template_key(model, nonlinear_residuals)
    template = get!(templates, template_key) do
        _compile_template(model, nonlinear_residuals)
    end
    template.key == template_key || throw(ArgumentError("nonlinear template cache collision"))

    parameter_values = T[
        parameter_value(specification, component.parameters)
        for specification in parameters(model)
    ]
    count = _symbolic_instance_count(model, nonlinear_residuals, system)
    for instance_index in 1:count
        bindings = Vector{VariableId}(undef, length(variables(model)))
        for (variable_index, specification) in enumerate(variables(model))
            local_index = isempty(specification.axes) ? 0 : instance_index
            bindings[variable_index] = compiled.variable_lookup[
                VariableKey(OwnerRef(owner), specification.name, local_index)
            ]
        end
        push!(instances, NonlinearInstance{T}(
            template_key,
            OwnerRef(owner),
            count == 1 ? 0 : instance_index,
            bindings,
            copy(parameter_values),
        ))
    end
    return nothing
end

function compile_hybrid(system::HubSystem{T}) where {T}
    base = compile_linear(system)
    linear_blocks = copy(base.blocks)
    templates = Dict{UInt64,NonlinearTemplate}()
    instances = NonlinearInstance{T}[]
    for registry in (system.processes, system.storages, system.networks, system.boundaries)
        for (owner, component) in registry
            component.model isa SymbolicComponentModel || continue
            _compile_symbolic_component!(
                templates, instances, linear_blocks, base, system, owner, component,
            )
        end
    end
    linear = CompiledSystem{T}(
        base.variables,
        base.variable_lookup,
        linear_blocks,
        base.objective,
        base.parameter_updates,
        base.source_revision,
    )
    return HybridCompiledSystem{T}(linear, templates, instances)
end

function refreshParameters(compiled::HybridCompiledSystem{T}, system::HubSystem) where {T}
    _, owners = _changed_parameter_owners(compiled.linear, system)
    refreshParameters(compiled.linear, system)
    changed = Set(owners)
    for instance in compiled.nonlinear_instances
        instance.owner in changed || continue
        component = _component(system, instance.owner)
        values = _resolved_parameters(component.model, component.parameters)
        for (position, specification) in enumerate(parameters(component.model))
            instance.parameters[position] = T(values[specification.name])
        end
    end
    return compiled
end
