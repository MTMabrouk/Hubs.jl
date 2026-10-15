import ..Domain: addProcess,
    addStorage,
    equations,
    objective_terms,
    parameters,
    validate,
    validate_component,
    variables

struct LanguageComponentModel <: AbstractComponentModel
    definition::ComponentDefinition
    variable_specs::Vector{VariableSpec}
    parameter_specs::Vector{ParameterSpec}
end

variables(model::LanguageComponentModel) = model.variable_specs
parameters(model::LanguageComponentModel) = model.parameter_specs
equations(model::LanguageComponentModel) = model.definition.equations
objective_terms(::LanguageComponentModel) = LinearObjectiveTerm[]
validate(model::LanguageComponentModel) = model

function _contains_shifted_reference(expression::ExprNode, name::Symbol)
    if expression isa CallExpr
        if expression.callee isa IdentifierExpr && expression.callee.parts == [name]
            for argument in expression.arguments
                if argument isa BinaryExpr && argument.operator in (:+, :-)
                    return true
                end
            end
        end
        return any(argument -> _contains_shifted_reference(argument, name), expression.arguments)
    elseif expression isa UnaryExpr
        return _contains_shifted_reference(expression.operand, name)
    elseif expression isa BinaryExpr
        return _contains_shifted_reference(expression.left, name) ||
            _contains_shifted_reference(expression.right, name)
    end
    return false
end

function _variable_role(definition::VariableDefinition, component::ComponentDefinition)
    definition.port !== nothing && return definition.port.direction == Input ? InputFlow : OutputFlow
    any(equation -> _contains_shifted_reference(equation.expression, definition.name), component.equations) && return State
    isempty(definition.axes) && return Capacity
    return Operation
end

function _numeric_bound(expression::ExprNode, variable, side)
    value = _number(expression)
    value === nothing && _semantic_error(
        "$side bound for $variable must currently be numeric; parameterized bounds are reserved in the language but not yet compiled",
        expression,
    )
    return value
end

function component_model(component::ComponentDefinition)
    variable_specs = VariableSpec[]
    for definition in component.variables
        domain = if definition.domain == :continuous
            ContinuousDomain
        elseif definition.domain == :integer
            IntegerDomain
        else
            BinaryDomain
        end
        push!(variable_specs, VariableSpec(
            definition.name,
            _variable_role(definition, component);
            domain=domain,
            lower_bound=_numeric_bound(definition.lower, definition.name, "lower"),
            upper_bound=_numeric_bound(definition.upper, definition.name, "upper"),
            unit=isnothing(definition.unit) ? nothing : Symbol(definition.unit),
            axes=Tuple(definition.axes),
        ))
    end

    parameter_specs = ParameterSpec[]
    for definition in component.parameters
        default = definition.default === nothing ? missing : _number(definition.default)
        definition.default !== nothing && default === nothing && _semantic_error(
            "default for parameter $(definition.name) must currently be numeric",
            definition.default,
        )
        push!(parameter_specs, ParameterSpec(
            definition.name;
            default=default,
            unit=isnothing(definition.unit) ? nothing : Symbol(definition.unit),
            axes=Tuple(definition.axes),
        ))
    end
    return LanguageComponentModel(component, variable_specs, parameter_specs)
end

function _carrier_id(system::HubSystem, name::Symbol)
    matches = CarrierId[id for (id, carrier) in system.carriers if carrier.name == name]
    isempty(matches) && throw(ArgumentError("carrier $name is not registered in the system"))
    length(matches) == 1 || throw(ArgumentError("carrier $name is registered more than once"))
    return only(matches)
end

function component_ports(system::HubSystem, component::ComponentDefinition)
    result = Port[]
    for definition in component.variables
        definition.port === nothing && continue
        push!(result, Port(
            definition.name,
            _carrier_id(system, definition.port.carrier),
            definition.port.direction;
            variable=definition.name,
        ))
    end
    return result
end

function addProcess(
    system::HubSystem,
    hub::HubId,
    definition::ComponentDefinition;
    name=definition.id,
    parameters=NamedTuple(),
)
    definition.kind == :process || throw(ArgumentError("$(definition.id) is a $(definition.kind) model, not a process model"))
    model = component_model(definition)
    return addProcess(system, hub, Process(name, component_ports(system, definition), model; parameters=parameters))
end

function addStorage(
    system::HubSystem,
    hub::HubId,
    definition::ComponentDefinition;
    name=definition.id,
    parameters=NamedTuple(),
)
    definition.kind == :storage || throw(ArgumentError("$(definition.id) is a $(definition.kind) model, not a storage model"))
    model = component_model(definition)
    return addStorage(system, hub, Storage(name, component_ports(system, definition), model; parameters=parameters))
end

function validate_component(model::LanguageComponentModel, ports, parameter_values)
    variable_names = Set(specification.name for specification in variables(model))
    for port in ports
        port.variable in variable_names ||
            throw(ArgumentError("port $(port.name) references undeclared variable $(port.variable)"))
    end
    for specification in parameters(model)
        parameter_value(specification, parameter_values)
    end
    return nothing
end
