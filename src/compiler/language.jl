struct _DroppedLanguageRow <: Exception end

struct _LanguageAffine{T}
    constant::T
    terms::Dict{Tuple{Symbol,Int},T}
end

_language_constant(::Type{T}, value) where {T} = _LanguageAffine{T}(T(value), Dict{Tuple{Symbol,Int},T}())
_language_variable(::Type{T}, name, index) where {T} =
    _LanguageAffine{T}(zero(T), Dict{Tuple{Symbol,Int},T}((name, index) => one(T)))

function _language_add(left::_LanguageAffine{T}, right::_LanguageAffine{T}, scale=one(T)) where {T}
    terms = copy(left.terms)
    for (key, coefficient) in right.terms
        terms[key] = get(terms, key, zero(T)) + scale * coefficient
    end
    return _LanguageAffine{T}(left.constant + scale * right.constant, terms)
end

function _language_scale(form::_LanguageAffine{T}, scale) where {T}
    factor = T(scale)
    return _LanguageAffine{T}(
        factor * form.constant,
        Dict(key => factor * coefficient for (key, coefficient) in form.terms),
    )
end

function _language_multiply(left::_LanguageAffine{T}, right::_LanguageAffine{T}, node) where {T}
    !isempty(left.terms) && !isempty(right.terms) && throw(ModelLanguage.SemanticError(
        "nonlinear products are parsed but require the nonlinear language compiler",
        node.span,
    ))
    if isempty(left.terms)
        return _language_scale(right, left.constant)
    end
    return _language_scale(left, right.constant)
end

function _language_divide(numerator::_LanguageAffine{T}, denominator::_LanguageAffine{T}, node) where {T}
    isempty(denominator.terms) || throw(ModelLanguage.SemanticError(
        "division by a variable expression requires the nonlinear language compiler",
        node.span,
    ))
    iszero(denominator.constant) && throw(DomainError(denominator.constant, "division by zero in model expression"))
    return _language_scale(numerator, inv(denominator.constant))
end

function _language_power(base::_LanguageAffine{T}, exponent::_LanguageAffine{T}, node) where {T}
    isempty(exponent.terms) || throw(ModelLanguage.SemanticError(
        "variable exponents require the nonlinear language compiler",
        node.span,
    ))
    if isempty(base.terms)
        return _language_constant(T, base.constant ^ exponent.constant)
    elseif exponent.constant == one(T)
        return base
    elseif exponent.constant == zero(T)
        return _language_constant(T, one(T))
    end
    throw(ModelLanguage.SemanticError(
        "nonlinear powers are parsed but require the nonlinear language compiler",
        node.span,
    ))
end

function _language_spec(model::LanguageComponentModel, name::Symbol)
    index = findfirst(specification -> specification.name == name, variables(model))
    index !== nothing && return (:variable, variables(model)[index])
    index = findfirst(specification -> specification.name == name, parameters(model))
    index !== nothing && return (:parameter, parameters(model)[index])
    index = findfirst(definition -> definition.name == name, model.definition.expressions)
    index !== nothing && return (:expression, model.definition.expressions[index])
    return nothing
end

function _language_index(value, steps, boundary, node)
    isfinite(value) || throw(ModelLanguage.SemanticError("time index must be finite", node.span))
    index = round(Int, value)
    index == value || throw(ModelLanguage.SemanticError("time index must be an integer", node.span))
    1 <= index <= steps && return index
    boundary == :drop && throw(_DroppedLanguageRow())
    boundary == :cyclic && return mod1(index, steps)
    throw(ModelLanguage.SemanticError(
        "time index $index is outside 1:$steps; annotate the equation with @boundary(drop) or @boundary(cyclic)",
        node.span,
    ))
end

function _language_parameter_value(specification, values, index, steps)
    value = parameter_value(specification, values)
    if isempty(specification.axes)
        return value
    end
    specification.axes == (:time,) || throw(ArgumentError(
        "unsupported parameter axes $(specification.axes); currently supported axes are () and (:time,)",
    ))
    value isa Number && return value
    length(value) == steps || throw(DimensionMismatch(
        "parameter $(specification.name) has $(length(value)) values, expected $steps",
    ))
    return value[index]
end

function _language_expression(
    expression::HubsParser.ExprNode,
    model::LanguageComponentModel,
    values,
    system,
    time::Int,
    boundary,
    locals::AbstractDict{Symbol},
    ::Type{T},
) where {T}
    if expression isa HubsParser.NumberLiteral
        return _language_constant(T, expression.value)
    elseif expression isa HubsParser.IdentifierExpr
        name = only(expression.parts)
        haskey(locals, name) && return _language_constant(T, locals[name])
        name == :Inf && return _language_constant(T, Inf)
        specification = _language_spec(model, name)
        specification === nothing && throw(ModelLanguage.SemanticError("unknown model name $name", expression.span))
        kind, definition = specification
        if kind == :variable
            isempty(definition.axes) || throw(ModelLanguage.SemanticError("indexed variable $name must be called", expression.span))
            return _language_variable(T, name, 0)
        elseif kind == :parameter
            isempty(definition.axes) || throw(ModelLanguage.SemanticError("indexed parameter $name must be called", expression.span))
            return _language_constant(T, _language_parameter_value(definition, values, 0, system.steps))
        end
        isempty(definition.axes) || throw(ModelLanguage.SemanticError("indexed expression $name must be called", expression.span))
        return _language_expression(definition.expression, model, values, system, time, boundary, locals, T)
    elseif expression isa HubsParser.UnaryExpr
        value = _language_expression(expression.operand, model, values, system, time, boundary, locals, T)
        return expression.operator == :- ? _language_scale(value, -one(T)) : value
    elseif expression isa HubsParser.BinaryExpr
        left = _language_expression(expression.left, model, values, system, time, boundary, locals, T)
        right = _language_expression(expression.right, model, values, system, time, boundary, locals, T)
        expression.operator == :+ && return _language_add(left, right)
        expression.operator == :- && return _language_add(left, right, -one(T))
        expression.operator == :* && return _language_multiply(left, right, expression)
        expression.operator == :/ && return _language_divide(left, right, expression)
        expression.operator == :^ && return _language_power(left, right, expression)
        throw(ModelLanguage.SemanticError("relations may only appear at the top of an equation", expression.span))
    elseif expression isa HubsParser.CallExpr
        name = only(expression.callee.parts)
        if name == :first
            return _language_constant(T, 1)
        end
        argument_values = T[]
        for argument in expression.arguments
            result = _language_expression(argument, model, values, system, time, boundary, locals, T)
            isempty(result.terms) || throw(ModelLanguage.SemanticError("indices must not depend on variables", argument.span))
            push!(argument_values, result.constant)
        end
        if name == :duration
            return _language_constant(T, system.time_step)
        end
        specification = _language_spec(model, name)
        specification === nothing && throw(ModelLanguage.SemanticError("unknown function or indexed name $name", expression.span))
        kind, definition = specification
        length(argument_values) == 1 || throw(ArgumentError("the compiler currently supports one-dimensional time axes"))
        index = _language_index(only(argument_values), system.steps, boundary, expression)
        if kind == :variable
            definition.axes == (:time,) || throw(ArgumentError("unsupported variable axes $(definition.axes)"))
            return _language_variable(T, name, index)
        elseif kind == :parameter
            definition.axes == (:time,) || throw(ArgumentError("unsupported parameter axes $(definition.axes)"))
            return _language_constant(T, _language_parameter_value(definition, values, index, system.steps))
        end
        length(definition.axes) == 1 || throw(ArgumentError("the compiler currently supports one-dimensional expression axes"))
        nested_locals = copy(locals)
        nested_locals[only(definition.axes)] = only(argument_values)
        return _language_expression(definition.expression, model, values, system, time, boundary, nested_locals, T)
    end
    throw(ModelLanguage.SemanticError("unsupported expression in compiled equation", expression.span))
end

function _language_residual(equation, model, values, system, time, ::Type{T}) where {T}
    relation = equation.expression
    left = _language_expression(relation.left, model, values, system, time, equation.boundary, Dict(:t => time), T)
    right = _language_expression(relation.right, model, values, system, time, equation.boundary, Dict(:t => time), T)
    form = _language_add(left, right, -one(T))
    sense = relation.operator in (:~, :(==)) ? EqualTo : relation.operator in (:<=, :<) ? LessThan : GreaterThan
    return form, sense
end

function _uses_time_index(expression)
    if expression isa HubsParser.IdentifierExpr
        return expression.parts == [:t]
    elseif expression isa HubsParser.CallExpr
        return any(_uses_time_index, expression.arguments)
    elseif expression isa HubsParser.UnaryExpr
        return _uses_time_index(expression.operand)
    elseif expression isa HubsParser.BinaryExpr
        return _uses_time_index(expression.left) || _uses_time_index(expression.right)
    end
    return false
end

_language_times(equation, system) = _uses_time_index(equation.expression) ? (1:system.steps) : (1:1)

struct CompiledLanguageTemplate
    equation_indices::Vector{Int}
    times::Vector{Int}
    rowptr::Vector{Int}
    term_keys::Vector{Tuple{Symbol,Int}}
    senses::Vector{ConstraintSense}
    row_names::Vector{Symbol}
    row_indices::Vector{Int}
end

function _build_language_template(model, values, system, ::Type{T}) where {T}
    equation_indices = Int[]
    times = Int[]
    rowptr = Int[1]
    term_keys = Tuple{Symbol,Int}[]
    senses = ConstraintSense[]
    row_names = Symbol[]
    row_indices = Int[]
    for (equation_index, equation) in enumerate(model.definition.equations)
        for time in _language_times(equation, system)
            form_and_sense = try
                _language_residual(equation, model, values, system, time, T)
            catch error
                error isa _DroppedLanguageRow || rethrow()
                continue
            end
            form, sense = form_and_sense
            push!(equation_indices, equation_index)
            push!(times, time)
            append!(term_keys, first.(_ordered_language_terms(form)))
            push!(rowptr, length(term_keys) + 1)
            push!(senses, sense)
            push!(row_names, equation.name)
            push!(row_indices, _uses_time_index(equation.expression) ? time : 0)
        end
    end
    return CompiledLanguageTemplate(
        equation_indices, times, rowptr, term_keys, senses, row_names, row_indices,
    )
end

function _prepare_language_template(library, model, values, system, ::Type{T}) where {T}
    variants = get!(library.language_model_variants, model) do
        Dict{Tuple{DataType,Int},Any}()
    end
    key = (T, system.steps)
    if haskey(variants, key)
        library.hits += 1
        return variants[key]::CompiledLanguageTemplate
    end
    template = _build_language_template(model, values, system, T)
    variants[key] = template
    library.misses += 1
    return template
end

function _ordered_language_terms(form)
    return sort!(collect(form.terms); by=pair -> (string(pair.first[1]), pair.first[2]))
end

_language_owner_ref(owner::OwnerRef) = owner
_language_owner_ref(owner) = OwnerRef(owner)

function _fill_language_template_block!(block, template, variable_lookup, owner, model, values, system)
    T = eltype(block.coefficients)
    owner_ref = _language_owner_ref(owner)
    for row in eachindex(template.equation_indices)
        equation = model.definition.equations[template.equation_indices[row]]
        form, sense = _language_residual(equation, model, values, system, template.times[row], T)
        sense == template.senses[row] || throw(ArgumentError("language equation sense changed"))
        block.rhs[row] = -form.constant
        ordered = _ordered_language_terms(form)
        range = template.rowptr[row]:(template.rowptr[row + 1] - 1)
        length(ordered) == length(range) || throw(ArgumentError("language block sparsity changed during parameter refresh"))
        for (position, pair) in zip(range, ordered)
            key, coefficient = pair
            key == template.term_keys[position] || throw(ArgumentError("language block sparsity changed during parameter refresh"))
            block.coefficients[position] = coefficient
            if variable_lookup !== nothing
                block.variable_ids[position] = variable_lookup[VariableKey(owner_ref, key[1], key[2])]
            end
        end
    end
    return block
end

struct LanguageBlockUpdate{M,S,L} <: AbstractParameterUpdate
    block_index::Int
    model::M
    system::S
    template::L
    owner::OwnerRef
end

function _compile_language_component!(context::CompilationContext{T}, system, owner, component, library) where {T}
    model = component.model
    template = _prepare_language_template(library, model, component.parameters, system, T)
    row_count = length(template.equation_indices)
    term_count = length(template.term_keys)
    block = LinearBlock{T}(
        OwnerRef(owner),
        copy(template.rowptr),
        Vector{VariableId}(undef, term_count),
        Vector{T}(undef, term_count),
        Vector{T}(undef, row_count),
        copy(template.senses),
        ConstraintKey[
            ConstraintKey(OwnerRef(owner), template.row_names[row], template.row_indices[row])
            for row in eachindex(template.row_names)
        ],
    )
    _fill_language_template_block!(
        block, template, context.variable_lookup, owner, model, component.parameters, system,
    )
    push!(context.blocks, block)
    if !isempty(parameters(model))
        update_system = (steps=system.steps, time_step=system.time_step)
        _record_parameter_update!(context, owner, LanguageBlockUpdate(
            length(context.blocks), model, update_system, template, OwnerRef(owner),
        ))
    end
    return context
end

function _apply_parameter_update!(compiled::CompiledSystem, update::LanguageBlockUpdate, values)
    block = compiled.blocks[update.block_index]
    _fill_language_template_block!(
        block, update.template, nothing, update.owner, update.model, values, update.system,
    )
    return nothing
end
