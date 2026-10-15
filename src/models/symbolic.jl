struct SymbolicComponentModel{V,P,R,O} <: AbstractComponentModel
    variables::Vector{VariableSpec}
    parameters::Vector{ParameterSpec}
    variable_symbols::V
    parameter_symbols::P
    residuals::R
    objective::O
end

function _ordered_symbols(specifications, symbols, kind)
    ordered = Any[]
    sizehint!(ordered, length(specifications))
    for specification in specifications
        symbol = if symbols isa NamedTuple
            haskey(symbols, specification.name) ||
                throw(ArgumentError("missing symbolic $kind $(specification.name)"))
            getproperty(symbols, specification.name)
        elseif symbols isa AbstractDict
            haskey(symbols, specification.name) ||
                throw(ArgumentError("missing symbolic $kind $(specification.name)"))
            symbols[specification.name]
        else
            throw(ArgumentError("symbolic $kind bindings must be a NamedTuple or dictionary"))
        end
        push!(ordered, symbol)
    end
    return ordered
end

function SymbolicComponentModel(
    variable_specifications,
    parameter_specifications,
    variable_symbols,
    parameter_symbols,
    residuals;
    objective=nothing,
)
    variable_specs = collect(VariableSpec, variable_specifications)
    parameter_specs = collect(ParameterSpec, parameter_specifications)
    ordered_variables = _ordered_symbols(variable_specs, variable_symbols, "variable")
    ordered_parameters = _ordered_symbols(parameter_specs, parameter_symbols, "parameter")
    model = SymbolicComponentModel(
        variable_specs,
        parameter_specs,
        ordered_variables,
        ordered_parameters,
        collect(residuals),
        objective,
    )
    validate(model)
    return model
end

variables(model::SymbolicComponentModel) = model.variables
parameters(model::SymbolicComponentModel) = model.parameters
equations(model::SymbolicComponentModel) = model.residuals
objective_terms(::SymbolicComponentModel) = LinearObjectiveTerm[]
symbolic_variables(model::SymbolicComponentModel) = model.variable_symbols
symbolic_parameters(model::SymbolicComponentModel) = model.parameter_symbols
residuals(model::SymbolicComponentModel) = model.residuals

function validate(model::SymbolicComponentModel)
    _unique_names(model.variables, "variable")
    _unique_names(model.parameters, "parameter")
    isempty(model.residuals) && throw(ArgumentError("a symbolic model must contain at least one residual"))
    declared = Set(vcat(model.variable_symbols, model.parameter_symbols))
    for residual in model.residuals
        unknown = setdiff(Set(Symbolics.get_variables(residual)), declared)
        isempty(unknown) || throw(ArgumentError("symbolic residual contains undeclared symbols: $unknown"))
    end
    return model
end

function validate_component(model::SymbolicComponentModel, ports, parameter_values)
    variable_names = Set(specification.name for specification in model.variables)
    for port in ports
        port.variable in variable_names ||
            throw(ArgumentError("port $(port.name) references undeclared variable $(port.variable)"))
    end
    for specification in model.parameters
        parameter_value(specification, parameter_values)
    end
    return nothing
end
