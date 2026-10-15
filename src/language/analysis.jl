const _COMPONENT_BUILTINS = Dict(
    :duration => 1,
    :first => 1,
)

const _OBJECTIVE_BUILTINS = Dict(
    :annualize => 3,
    :sum_t => 1,
    :sum_components => 1,
    :duration => 1,
    :weight => 1,
)

_arity_error(name, expected, actual, node) =
    _semantic_error("$name expects $expected argument$(expected == 1 ? "" : "s"), got $actual", node)

function _single_name(expression::IdentifierExpr)
    length(expression.parts) == 1 || _semantic_error("qualified names are not valid here", expression)
    return only(expression.parts)
end

function _symbol_tables(component::ComponentDefinition)
    variables = Dict(definition.name => definition.axes for definition in component.variables)
    parameters = Dict(definition.name => definition.axes for definition in component.parameters)
    expressions = Dict(definition.name => definition.axes for definition in component.expressions)
    return variables, parameters, expressions
end

function _validate_reference!(
    expression::ExprNode,
    variables,
    parameters,
    expressions,
    locals::Set{Symbol};
    allow_relation=false,
)
    if expression isa NumberLiteral || expression isa StringLiteral || expression isa BooleanLiteral
        return nothing
    elseif expression isa IdentifierExpr
        name = _single_name(expression)
        name in locals && return nothing
        name in (:time, :Inf) && return nothing
        axes = if haskey(variables, name)
            variables[name]
        elseif haskey(parameters, name)
            parameters[name]
        elseif haskey(expressions, name)
            expressions[name]
        else
            _semantic_error("unknown name $name", expression)
        end
        isempty(axes) || _semantic_error("indexed name $name must be called with $(length(axes)) argument(s)", expression)
        return nothing
    elseif expression isa UnaryExpr
        expression.operator in (:+, :-) || _semantic_error("unsupported unary operator $(expression.operator)", expression)
        return _validate_reference!(expression.operand, variables, parameters, expressions, locals; allow_relation=false)
    elseif expression isa BinaryExpr
        is_relation = expression.operator in (:~, :<=, :>=, :<, :>, :(==), :(!=))
        is_relation && !allow_relation && _semantic_error("relations are only valid at the top of an equation", expression)
        _validate_reference!(expression.left, variables, parameters, expressions, locals; allow_relation=false)
        _validate_reference!(expression.right, variables, parameters, expressions, locals; allow_relation=false)
        return nothing
    elseif expression isa CallExpr
        expression.callee isa IdentifierExpr || _semantic_error("call target must be a name", expression.callee)
        name = _single_name(expression.callee)
        expected = if haskey(variables, name)
            length(variables[name])
        elseif haskey(parameters, name)
            length(parameters[name])
        elseif haskey(expressions, name)
            length(expressions[name])
        elseif haskey(_COMPONENT_BUILTINS, name)
            _COMPONENT_BUILTINS[name]
        else
            _semantic_error("unknown function or indexed name $name", expression.callee)
        end
        length(expression.arguments) == expected || _arity_error(name, expected, length(expression.arguments), expression)
        for argument in expression.arguments
            _validate_reference!(argument, variables, parameters, expressions, locals; allow_relation=false)
        end
        return nothing
    end
    _semantic_error("property maps and arrays are not valid in symbolic expressions", expression)
end

function _expression_dependencies(expression::ExprNode, known::Set{Symbol}, found=Set{Symbol}())
    if expression isa IdentifierExpr && length(expression.parts) == 1
        name = only(expression.parts)
        name in known && push!(found, name)
    elseif expression isa CallExpr
        _expression_dependencies(expression.callee, known, found)
        foreach(argument -> _expression_dependencies(argument, known, found), expression.arguments)
    elseif expression isa UnaryExpr
        _expression_dependencies(expression.operand, known, found)
    elseif expression isa BinaryExpr
        _expression_dependencies(expression.left, known, found)
        _expression_dependencies(expression.right, known, found)
    end
    return found
end

function _validate_expression_cycles(component::ComponentDefinition)
    definitions = Dict(definition.name => definition for definition in component.expressions)
    known = Set(keys(definitions))
    state = Dict{Symbol,UInt8}()
    function visit(name)
        get(state, name, 0x00) == 0x02 && return
        get(state, name, 0x00) == 0x01 && _semantic_error("cyclic expression definition involving $name", definitions[name])
        state[name] = 0x01
        for dependency in _expression_dependencies(definitions[name].expression, known)
            visit(dependency)
        end
        state[name] = 0x02
    end
    foreach(visit, keys(definitions))
    return component
end

function validate_references(component::ComponentDefinition)
    variables, parameters, expressions = _symbol_tables(component)
    for definition in component.expressions
        _validate_reference!(
            definition.expression,
            variables,
            parameters,
            expressions,
            Set(definition.axes),
        )
    end
    equation_locals = Set([:t])
    for equation in component.equations
        _validate_reference!(
            equation.expression,
            variables,
            parameters,
            expressions,
            equation_locals;
            allow_relation=true,
        )
    end
    if component.objective !== nothing
        _validate_reference!(
            component.objective.expression,
            variables,
            parameters,
            expressions,
            Set([:t]),
        )
    end
    return _validate_expression_cycles(component)
end

function expression_contributors(components, name::Union{Symbol,AbstractString})
    wanted = Symbol(name)
    return ComponentDefinition[
        component for component in components
        if any(definition -> definition.name == wanted, component.expressions)
    ]
end

function _objective_expression_names(expression::ExprNode, catalog::Set{Symbol}, found=Set{Symbol}())
    if expression isa IdentifierExpr && length(expression.parts) == 1
        name = only(expression.parts)
        name in catalog && push!(found, name)
    elseif expression isa CallExpr
        if expression.callee isa IdentifierExpr && length(expression.callee.parts) == 1
            name = only(expression.callee.parts)
            name in catalog && push!(found, name)
        end
        foreach(argument -> _objective_expression_names(argument, catalog, found), expression.arguments)
    elseif expression isa UnaryExpr
        _objective_expression_names(expression.operand, catalog, found)
    elseif expression isa BinaryExpr
        _objective_expression_names(expression.left, catalog, found)
        _objective_expression_names(expression.right, catalog, found)
    end
    return found
end

function _validate_objective_node!(expression, program, components, catalog, locals; component=nothing)
    if expression isa NumberLiteral
        return nothing
    elseif expression isa IdentifierExpr
        name = _single_name(expression)
        name in locals && return nothing
        name in (:time, :Inf) && return nothing
        any(parameter -> parameter.name == name && isempty(parameter.axes), program.parameters) && return nothing
        if component !== nothing
            component_expression = findfirst(definition -> definition.name == name, component.expressions)
            component_parameter = findfirst(parameter -> parameter.name == name, component.parameters)
            component_expression !== nothing && isempty(component.expressions[component_expression].axes) && return nothing
            component_parameter !== nothing && isempty(component.parameters[component_parameter].axes) && return nothing
        end
        name in catalog && _semantic_error("component expression $name must be inside sum_components(...) or use its declared indices", expression)
        _semantic_error("unknown objective name $name", expression)
    elseif expression isa UnaryExpr
        return _validate_objective_node!(expression.operand, program, components, catalog, locals; component=component)
    elseif expression isa BinaryExpr
        _validate_objective_node!(expression.left, program, components, catalog, locals; component=component)
        _validate_objective_node!(expression.right, program, components, catalog, locals; component=component)
        return nothing
    elseif expression isa CallExpr
        expression.callee isa IdentifierExpr || _semantic_error("objective call target must be a name", expression.callee)
        name = _single_name(expression.callee)
        if name == :sum_t
            length(expression.arguments) == 1 || _arity_error(name, 1, length(expression.arguments), expression)
            nested_locals = copy(locals)
            push!(nested_locals, :t)
            return _validate_objective_node!(only(expression.arguments), program, components, catalog, nested_locals; component=component)
        elseif name == :sum_components
            length(expression.arguments) == 1 || _arity_error(name, 1, length(expression.arguments), expression)
            body = only(expression.arguments)
            referenced = _objective_expression_names(body, catalog)
            isempty(referenced) && _semantic_error("sum_components must reference at least one named component expression", body)
            for expression_name in referenced
                isempty(expression_contributors(components, expression_name)) &&
                    _semantic_error("no component defines expression $expression_name", body)
            end
            # Missing named expressions make that component's contribution zero.
            # Only components defining every referenced expression need the body validated.
            for candidate in components
                all(name -> any(definition -> definition.name == name, candidate.expressions), referenced) || continue
                _validate_objective_node!(body, program, components, catalog, locals; component=candidate)
            end
            return nothing
        elseif haskey(_OBJECTIVE_BUILTINS, name)
            expected = _OBJECTIVE_BUILTINS[name]
            length(expression.arguments) == expected || _arity_error(name, expected, length(expression.arguments), expression)
            foreach(argument -> _validate_objective_node!(argument, program, components, catalog, locals; component=component), expression.arguments)
            return nothing
        end

        axes = nothing
        if component !== nothing
            definition = findfirst(candidate -> candidate.name == name, component.expressions)
            definition !== nothing && (axes = component.expressions[definition].axes)
            if axes === nothing
                parameter = findfirst(candidate -> candidate.name == name, component.parameters)
                parameter !== nothing && (axes = component.parameters[parameter].axes)
            end
        end
        if axes === nothing
            parameter = findfirst(candidate -> candidate.name == name, program.parameters)
            parameter !== nothing && (axes = program.parameters[parameter].axes)
        end
        axes === nothing && _semantic_error("unknown objective function or indexed name $name", expression.callee)
        length(expression.arguments) == length(axes) || _arity_error(name, length(axes), length(expression.arguments), expression)
        foreach(argument -> _validate_objective_node!(argument, program, components, catalog, locals; component=component), expression.arguments)
        return nothing
    end
    _semantic_error("unsupported syntax in objective", expression)
end

function validate_objective(program::ObjectiveProgram, components)
    component_list = collect(ComponentDefinition, components)
    catalog = Set(
        expression.name
        for component in component_list
        for expression in component.expressions
    )
    _validate_objective_node!(
        program.objective.expression,
        program,
        component_list,
        catalog,
        Set{Symbol}(),
    )
    return program
end
