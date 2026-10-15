@enum VariableRole begin
    InputFlow
    OutputFlow
    State
    Operation
    Capacity
    NetworkFlow
    Potential
    Auxiliary
end

@enum VariableDomain begin
    ContinuousDomain
    IntegerDomain
    BinaryDomain
end

@enum ConstraintSense begin
    EqualTo
    LessThan
    GreaterThan
end

struct VariableSpec{L,U,N,A}
    name::Symbol
    role::VariableRole
    domain::VariableDomain
    lower_bound::L
    upper_bound::U
    unit::N
    axes::A
end

function VariableSpec(
    name::Union{Symbol,AbstractString},
    role::VariableRole;
    domain::VariableDomain=ContinuousDomain,
    lower_bound=-Inf,
    upper_bound=Inf,
    unit=nothing,
    axes=(:time,),
)
    lower_bound <= upper_bound || throw(ArgumentError("lower bound exceeds upper bound for $name"))
    return VariableSpec(Symbol(name), role, domain, lower_bound, upper_bound, unit, Tuple(axes))
end

struct ParameterSpec{D,N,A}
    name::Symbol
    default::D
    unit::N
    axes::A
end

ParameterSpec(name::Union{Symbol,AbstractString}; default=missing, unit=nothing, axes=()) =
    ParameterSpec(Symbol(name), default, unit, Tuple(axes))

abstract type AbstractCoefficient end

struct ConstantCoefficient{T} <: AbstractCoefficient
    value::T
end

struct ParameterCoefficient{T} <: AbstractCoefficient
    parameter::Symbol
    multiplier::T
end

ParameterCoefficient(parameter::Union{Symbol,AbstractString}, multiplier=1) =
    ParameterCoefficient{typeof(multiplier)}(Symbol(parameter), multiplier)

struct LinearTerm{C<:AbstractCoefficient}
    variable::Symbol
    coefficient::C
end

LinearTerm(variable::Union{Symbol,AbstractString}, coefficient::AbstractCoefficient) =
    LinearTerm(Symbol(variable), coefficient)
LinearTerm(variable::Union{Symbol,AbstractString}, coefficient::Number) =
    LinearTerm(Symbol(variable), ConstantCoefficient(coefficient))

struct LinearEquation{R}
    name::Symbol
    terms::Vector{LinearTerm}
    sense::ConstraintSense
    rhs::R
end

function LinearEquation(
    name::Union{Symbol,AbstractString},
    terms;
    sense::ConstraintSense=EqualTo,
    rhs=0,
)
    return LinearEquation(Symbol(name), collect(LinearTerm, terms), sense, rhs)
end

struct LinearObjectiveTerm{C<:AbstractCoefficient}
    variable::Symbol
    coefficient::C
end

LinearObjectiveTerm(variable::Union{Symbol,AbstractString}, coefficient::AbstractCoefficient) =
    LinearObjectiveTerm(Symbol(variable), coefficient)
LinearObjectiveTerm(variable::Union{Symbol,AbstractString}, coefficient::Number) =
    LinearObjectiveTerm(Symbol(variable), ConstantCoefficient(coefficient))

struct LinearComponentModel <: AbstractComponentModel
    variables::Vector{VariableSpec}
    parameters::Vector{ParameterSpec}
    equations::Vector{LinearEquation}
    objective_terms::Vector{LinearObjectiveTerm}

    function LinearComponentModel(variables, parameters, equations, objective_terms=LinearObjectiveTerm[])
        model = new(
            collect(VariableSpec, variables),
            collect(ParameterSpec, parameters),
            collect(LinearEquation, equations),
            collect(LinearObjectiveTerm, objective_terms),
        )
        validate(model)
        return model
    end
end

variables(::NoModel) = VariableSpec[]
parameters(::NoModel) = ParameterSpec[]
equations(::NoModel) = LinearEquation[]
objective_terms(::NoModel) = LinearObjectiveTerm[]

variables(model::LinearComponentModel) = model.variables
parameters(model::LinearComponentModel) = model.parameters
equations(model::LinearComponentModel) = model.equations
objective_terms(model::LinearComponentModel) = model.objective_terms

function _unique_names(specifications, kind)
    names = map(specification -> specification.name, specifications)
    length(unique(names)) == length(names) || throw(ArgumentError("duplicate $kind name"))
    return Set(names)
end

function validate(model::LinearComponentModel)
    variable_names = _unique_names(model.variables, "variable")
    parameter_names = _unique_names(model.parameters, "parameter")

    for equation in model.equations
        isempty(equation.terms) && throw(ArgumentError("equation $(equation.name) has no terms"))
        for term in equation.terms
            term.variable in variable_names ||
                throw(ArgumentError("equation $(equation.name) references unknown variable $(term.variable)"))
            if term.coefficient isa ParameterCoefficient
                term.coefficient.parameter in parameter_names ||
                    throw(ArgumentError("equation $(equation.name) references unknown parameter $(term.coefficient.parameter)"))
            end
        end
    end

    for term in model.objective_terms
        term.variable in variable_names ||
            throw(ArgumentError("objective references unknown variable $(term.variable)"))
        if term.coefficient isa ParameterCoefficient
            term.coefficient.parameter in parameter_names ||
                throw(ArgumentError("objective references unknown parameter $(term.coefficient.parameter)"))
        end
    end
    return model
end

validate(::NoModel) = nothing

_hasvalue(values::NamedTuple, name::Symbol) = haskey(values, name)
_hasvalue(values::AbstractDict, name::Symbol) = haskey(values, name)
_getvalue(values::NamedTuple, name::Symbol) = getproperty(values, name)
_getvalue(values::AbstractDict, name::Symbol) = values[name]

function parameter_value(specification::ParameterSpec, values)
    if _hasvalue(values, specification.name)
        return _getvalue(values, specification.name)
    elseif !ismissing(specification.default)
        return specification.default
    end
    throw(ArgumentError("missing value for parameter $(specification.name)"))
end

coefficient_value(coefficient::ConstantCoefficient, _) = coefficient.value
coefficient_value(coefficient::ParameterCoefficient, values) =
    coefficient.multiplier * _getvalue(values, coefficient.parameter)

validate_component(::NoModel, ports, parameter_values) = nothing

function validate_component(model::LinearComponentModel, ports, parameter_values)
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

function validate_component(component::Union{Process,Storage})
    validate_component(component.model, component.ports, component.parameters)
    return component
end

function validate_component(component::Network)
    validate_component(component.model, (located.port for located in component.ports), component.parameters)
    return component
end

function validate_component(component::Boundary)
    validate_component(component.model, (component.port,), component.parameters)
    return component
end
