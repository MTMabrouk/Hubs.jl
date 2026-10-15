struct SemanticError <: Exception
    message::String
    span::SourceSpan
end

function Base.showerror(io::IO, error::SemanticError)
    location = isempty(error.span.source) ? "<input>" : error.span.source
    print(io, location, ':', error.span.first.line, ':', error.span.first.column, ": ", error.message)
end

struct PortDefinition
    carrier::Symbol
    direction::PortDirection
end

struct ParameterDefinition
    name::Symbol
    axes::Vector{Symbol}
    unit::Union{Nothing,String}
    default::Union{Nothing,ExprNode}
    span::SourceSpan
end

struct VariableDefinition
    name::Symbol
    axes::Vector{Symbol}
    unit::Union{Nothing,String}
    domain::Symbol
    lower::ExprNode
    upper::ExprNode
    port::Union{Nothing,PortDefinition}
    span::SourceSpan
end

struct EquationDefinition
    name::Symbol
    expression::ExprNode
    boundary::Union{Nothing,Symbol}
    span::SourceSpan
end

struct ExpressionDefinition
    name::Symbol
    axes::Vector{Symbol}
    expression::ExprNode
    span::SourceSpan
end

struct ObjectiveDefinition
    sense::Symbol
    expression::ExprNode
    span::SourceSpan
end

struct ComponentDefinition
    id::Symbol
    kind::Symbol
    parameters::Vector{ParameterDefinition}
    variables::Vector{VariableDefinition}
    equations::Vector{EquationDefinition}
    expressions::Vector{ExpressionDefinition}
    objective::Union{Nothing,ObjectiveDefinition}
    source::String
end

struct ObjectiveProgram
    parameters::Vector{ParameterDefinition}
    objective::ObjectiveDefinition
    source::String
end

_semantic_error(message, node) = throw(SemanticError(String(message), node.span))

function _only_section(document::Document, name::Symbol; required=false)
    matches = filter(candidate -> candidate.path == [name], document.sections)
    if isempty(matches)
        required && throw(ArgumentError("required section [$name] is missing from $(document.source)"))
        return nothing
    end
    length(matches) == 1 || _semantic_error("section [$name] is declared more than once", matches[2])
    return only(matches)
end

function _unique_declarations(section::Union{Nothing,Section})
    section === nothing && return Declaration[]
    seen = Set{Symbol}()
    for declaration in section.declarations
        declaration.name in seen && _semantic_error("duplicate declaration $(declaration.name)", declaration)
        push!(seen, declaration.name)
    end
    return section.declarations
end

function _property_map(declaration::Declaration)
    declaration.value isa MapExpr || _semantic_error("$(declaration.name) must use a property map", declaration)
    properties = Dict{Symbol,ExprNode}()
    for (name, value) in declaration.value.entries
        haskey(properties, name) && _semantic_error("duplicate property $name", value)
        properties[name] = value
    end
    return properties
end

function _reject_unknown(properties, allowed, declaration)
    unknown = setdiff(Set(keys(properties)), Set(allowed))
    isempty(unknown) || _semantic_error("unknown properties: $(join(sort!(string.(collect(unknown))), ", "))", declaration)
end

function _identifier(value::ExprNode, description)
    value isa IdentifierExpr && length(value.parts) == 1 || _semantic_error("$description must be an identifier", value)
    return only(value.parts)
end

function _unit(value::ExprNode)
    if value isa IdentifierExpr
        return join(string.(value.parts), '.')
    elseif value isa StringLiteral
        return value.value
    end
    _semantic_error("unit must be an identifier or string", value)
end

function _axes(value::ExprNode)
    value isa ArrayExpr || _semantic_error("axes must be an array", value)
    return [_identifier(element, "axis") for element in value.elements]
end

function _number(value)
    if value isa NumberLiteral
        return value.value
    elseif value isa UnaryExpr && value.operator in (:+, :-) && value.operand isa NumberLiteral
        return value.operator == :- ? -value.operand.value : value.operand.value
    elseif value isa IdentifierExpr && value.parts == [:Inf]
        return Inf
    end
    return nothing
end

_literal(value, fallback, span) = value === nothing ? NumberLiteral(fallback, span) : value

function _annotation(declaration, names)
    matches = filter(annotation -> annotation.name in names, declaration.annotations)
    length(matches) <= 1 || _semantic_error("conflicting annotations on $(declaration.name)", matches[2])
    return isempty(matches) ? nothing : only(matches)
end

function _port(declaration::Declaration, properties)
    annotation = _annotation(declaration, (:inlet, :outlet))
    if annotation === nothing
        haskey(properties, :carrier) && _semantic_error("carrier is only valid on @inlet or @outlet variables", properties[:carrier])
        return nothing
    end
    isempty(annotation.arguments) || _semantic_error("@$(annotation.name) does not take arguments", annotation)
    haskey(properties, :carrier) || _semantic_error("@$(annotation.name) variable requires carrier", declaration)
    carrier = _identifier(properties[:carrier], "carrier")
    direction = annotation.name == :inlet ? Input : Output
    return PortDefinition(carrier, direction)
end

function _lower_parameter(declaration::Declaration)
    isempty(declaration.annotations) || _semantic_error("parameters do not accept annotations", declaration)
    isempty(declaration.indices) || _semantic_error("parameter axes belong in the property map", declaration)
    properties = _property_map(declaration)
    _reject_unknown(properties, (:axes, :unit, :default), declaration)
    axes = haskey(properties, :axes) ? _axes(properties[:axes]) : Symbol[]
    unit = haskey(properties, :unit) ? _unit(properties[:unit]) : nothing
    default = get(properties, :default, nothing)
    return ParameterDefinition(declaration.name, axes, unit, default, declaration.span)
end

function _lower_variable(declaration::Declaration)
    isempty(declaration.indices) || _semantic_error("variable axes belong in the property map", declaration)
    unknown_annotations = filter(annotation -> !(annotation.name in (:inlet, :outlet)), declaration.annotations)
    isempty(unknown_annotations) || _semantic_error("unknown variable annotation @$(first(unknown_annotations).name)", first(unknown_annotations))
    properties = _property_map(declaration)
    _reject_unknown(properties, (:axes, :unit, :domain, :lower, :upper, :carrier), declaration)
    port = _port(declaration, properties)
    axes = haskey(properties, :axes) ? _axes(properties[:axes]) : Symbol[:time]
    unit = haskey(properties, :unit) ? _unit(properties[:unit]) : nothing
    domain = haskey(properties, :domain) ? _identifier(properties[:domain], "domain") : :continuous
    domain in (:continuous, :integer, :binary) || _semantic_error("domain must be continuous, integer, or binary", properties[:domain])
    lower = _literal(get(properties, :lower, nothing), port === nothing ? -Inf : 0.0, declaration.span)
    upper = _literal(get(properties, :upper, nothing), domain == :binary ? 1.0 : Inf, declaration.span)
    lower_number = _number(lower)
    upper_number = _number(upper)
    lower_number !== nothing && upper_number !== nothing && lower_number > upper_number &&
        _semantic_error("lower bound exceeds upper bound", declaration)
    return VariableDefinition(declaration.name, axes, unit, domain, lower, upper, port, declaration.span)
end

function _boundary(declaration::Declaration)
    unknown = filter(annotation -> annotation.name != :boundary, declaration.annotations)
    isempty(unknown) || _semantic_error("unknown equation annotation @$(first(unknown).name)", first(unknown))
    matches = filter(annotation -> annotation.name == :boundary, declaration.annotations)
    isempty(matches) && return nothing
    length(matches) == 1 || _semantic_error("@boundary is declared more than once", matches[2])
    annotation = only(matches)
    length(annotation.arguments) == 1 || _semantic_error("@boundary expects exactly one mode", annotation)
    mode = _identifier(only(annotation.arguments), "boundary mode")
    mode in (:drop, :cyclic) || _semantic_error("boundary mode must be drop or cyclic", annotation)
    return mode
end

function _lower_equation(declaration::Declaration)
    isempty(declaration.indices) || _semantic_error("equations cannot declare axes", declaration)
    expression = declaration.value
    expression isa BinaryExpr && expression.operator in (:~, :<=, :>=, :(==)) ||
        _semantic_error("equation must be an equality or inequality", declaration)
    return EquationDefinition(declaration.name, expression, _boundary(declaration), declaration.span)
end

function _lower_expression(declaration::Declaration)
    isempty(declaration.annotations) || _semantic_error("expressions do not accept annotations", declaration)
    return ExpressionDefinition(declaration.name, copy(declaration.indices), declaration.value, declaration.span)
end

function _lower_objective(section::Union{Nothing,Section})
    declarations = _unique_declarations(section)
    isempty(declarations) && return nothing
    length(declarations) == 1 || _semantic_error("objective must declare exactly one of minimize or maximize", declarations[2])
    declaration = only(declarations)
    declaration.name in (:minimize, :maximize) || _semantic_error("objective must be named minimize or maximize", declaration)
    isempty(declaration.indices) || _semantic_error("objective cannot declare axes", declaration)
    isempty(declaration.annotations) || _semantic_error("objective does not accept annotations", declaration)
    return ObjectiveDefinition(declaration.name, declaration.value, declaration.span)
end

function _model_identity(section::Section)
    declarations = _unique_declarations(section)
    values = Dict(declaration.name => declaration for declaration in declarations)
    haskey(values, :id) || _semantic_error("model id is required", section)
    haskey(values, :kind) || _semantic_error("model kind is required", section)
    allowed = Set((:id, :kind, :version, :description))
    unknown = setdiff(Set(keys(values)), allowed)
    isempty(unknown) || _semantic_error("unknown model fields: $(join(string.(collect(unknown)), ", "))", values[first(unknown)])
    id = _identifier(values[:id].value, "model id")
    kind = _identifier(values[:kind].value, "model kind")
    kind in (:process, :storage, :network, :boundary, :recycle) ||
        _semantic_error("unknown model kind $kind", values[:kind])
    return id, kind
end

function _validate_names(parameters, variables, expressions)
    owners = Dict{Symbol,String}()
    for (kind, definitions) in (("parameter", parameters), ("variable", variables), ("expression", expressions))
        for definition in definitions
            if haskey(owners, definition.name)
                throw(SemanticError(
                    "$(definition.name) is declared as both $(owners[definition.name]) and $kind",
                    definition.span,
                ))
            end
            owners[definition.name] = kind
        end
    end
end

function lower_component(document::Document)
    allowed_sections = Set([:model, :parameters, :variables, :equations, :expressions])
    for candidate in document.sections
        length(candidate.path) == 1 || _semantic_error("nested sections are not valid in a component model", candidate)
        only(candidate.path) in allowed_sections || _semantic_error("unknown component section [$(only(candidate.path))]", candidate)
    end

    model_section = _only_section(document, :model; required=true)
    id, kind = _model_identity(model_section)
    parameter_section = _only_section(document, :parameters)
    variable_section = _only_section(document, :variables; required=true)
    equation_section = _only_section(document, :equations; required=true)
    expression_section = _only_section(document, :expressions)

    parameters = _lower_parameter.(_unique_declarations(parameter_section))
    variables = _lower_variable.(_unique_declarations(variable_section))
    equations = _lower_equation.(_unique_declarations(equation_section))
    expressions = _lower_expression.(_unique_declarations(expression_section))
    isempty(variables) && _semantic_error("component model must declare at least one variable", variable_section)
    isempty(equations) && _semantic_error("component model must declare at least one equation", equation_section)
    _validate_names(parameters, variables, expressions)

    component = ComponentDefinition(
        id,
        kind,
        parameters,
        variables,
        equations,
        expressions,
        nothing,
        document.source,
    )
    validate_references(component)
    return component
end

load_component(path::AbstractString) = lower_component(parse_file(path))

function lower_objective(document::Document)
    allowed_sections = Set([:parameters, :objective])
    for candidate in document.sections
        length(candidate.path) == 1 || _semantic_error("nested sections are not valid in an objective program", candidate)
        only(candidate.path) in allowed_sections ||
            _semantic_error("unknown objective section [$(only(candidate.path))]", candidate)
    end
    parameter_section = _only_section(document, :parameters)
    objective_section = _only_section(document, :objective; required=true)
    parameters = _lower_parameter.(_unique_declarations(parameter_section))
    objective = _lower_objective(objective_section)
    objective === nothing && _semantic_error("objective program must define minimize or maximize", objective_section)
    return ObjectiveProgram(parameters, objective, document.source)
end

load_objective(path::AbstractString) = lower_objective(parse_file(path))
