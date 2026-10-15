mutable struct ExpressionParser
    tokens::Vector{Token}
    cursor::Int
end

_current(parser::ExpressionParser) = parser.tokens[parser.cursor]
_previous(parser::ExpressionParser) = parser.tokens[parser.cursor - 1]
_check(parser::ExpressionParser, kind::Symbol) = _current(parser).kind == kind

function _advance!(parser::ExpressionParser)
    !_check(parser, :eof) && (parser.cursor += 1)
    return _previous(parser)
end

function _match!(parser::ExpressionParser, kinds::Symbol...)
    _current(parser).kind in kinds || return false
    _advance!(parser)
    return true
end

function _consume!(parser::ExpressionParser, kind::Symbol, message)
    _check(parser, kind) && return _advance!(parser)
    throw(ParseError(String(message), _current(parser).span))
end

const _BINARY_PRECEDENCE = Dict(
    :tilde => 1,
    :less_equal => 1,
    :greater_equal => 1,
    :less => 1,
    :greater => 1,
    :equal_equal => 1,
    :not_equal => 1,
    :plus => 2,
    :minus => 2,
    :star => 3,
    :slash => 3,
    :caret => 4,
)

const _OPERATOR_SYMBOL = Dict(
    :tilde => :~,
    :less_equal => :<=,
    :greater_equal => :>=,
    :less => :<,
    :greater => :>,
    :equal_equal => :(==),
    :not_equal => :(!=),
    :plus => :+,
    :minus => :-,
    :star => :*,
    :slash => :/,
    :caret => :^,
)

function _parse_map!(parser::ExpressionParser, first::Token)
    entries = Pair{Symbol,ExprNode}[]
    if !_check(parser, :right_brace)
        while true
            key = _consume!(parser, :identifier, "expected a property name")
            _consume!(parser, :equal, "expected '=' after property name")
            value = _parse_precedence!(parser, 1)
            push!(entries, Symbol(key.text) => value)
            _match!(parser, :comma) || break
        end
    end
    last = _consume!(parser, :right_brace, "expected '}' after property map")
    return MapExpr(entries, _merge_span(first.span, last.span))
end

function _parse_array!(parser::ExpressionParser, first::Token)
    elements = ExprNode[]
    if !_check(parser, :right_bracket)
        while true
            push!(elements, _parse_precedence!(parser, 1))
            _match!(parser, :comma) || break
        end
    end
    last = _consume!(parser, :right_bracket, "expected ']' after array")
    return ArrayExpr(elements, _merge_span(first.span, last.span))
end

function _parse_primary!(parser::ExpressionParser)
    if _match!(parser, :number)
        token = _previous(parser)
        value = occursin(r"[.eE]", token.text) ? parse(Float64, token.text) : parse(Int, token.text)
        return NumberLiteral(value, token.span)
    elseif _match!(parser, :string)
        token = _previous(parser)
        return StringLiteral(token.text, token.span)
    elseif _match!(parser, :boolean)
        token = _previous(parser)
        return BooleanLiteral(token.text == "true", token.span)
    elseif _match!(parser, :identifier)
        first = _previous(parser)
        parts = Symbol[Symbol(first.text)]
        last = first
        while _match!(parser, :dot)
            last = _consume!(parser, :identifier, "expected identifier after '.'")
            push!(parts, Symbol(last.text))
        end
        return IdentifierExpr(parts, _merge_span(first.span, last.span))
    elseif _match!(parser, :left_paren)
        expression = _parse_precedence!(parser, 1)
        _consume!(parser, :right_paren, "expected ')' after expression")
        return expression
    elseif _match!(parser, :left_brace)
        return _parse_map!(parser, _previous(parser))
    elseif _match!(parser, :left_bracket)
        return _parse_array!(parser, _previous(parser))
    end
    throw(ParseError("expected an expression", _current(parser).span))
end

function _parse_postfix!(parser::ExpressionParser)
    expression = _parse_primary!(parser)
    while _match!(parser, :left_paren)
        arguments = ExprNode[]
        if !_check(parser, :right_paren)
            while true
                push!(arguments, _parse_precedence!(parser, 1))
                _match!(parser, :comma) || break
            end
        end
        last = _consume!(parser, :right_paren, "expected ')' after arguments")
        expression = CallExpr(expression, arguments, _merge_span(expression.span, last.span))
    end
    return expression
end

function _parse_unary!(parser::ExpressionParser)
    if _match!(parser, :plus, :minus)
        operator = _previous(parser)
        operand = _parse_unary!(parser)
        return UnaryExpr(_OPERATOR_SYMBOL[operator.kind], operand, _merge_span(operator.span, operand.span))
    end
    return _parse_postfix!(parser)
end

function _parse_precedence!(parser::ExpressionParser, minimum::Int)
    left = _parse_unary!(parser)
    while haskey(_BINARY_PRECEDENCE, _current(parser).kind)
        operator = _current(parser)
        precedence = _BINARY_PRECEDENCE[operator.kind]
        precedence < minimum && break
        _advance!(parser)
        next_minimum = operator.kind == :caret ? precedence : precedence + 1
        right = _parse_precedence!(parser, next_minimum)
        left = BinaryExpr(
            _OPERATOR_SYMBOL[operator.kind],
            left,
            right,
            _merge_span(left.span, right.span),
        )
    end
    return left
end

function parse_expression(
    text::AbstractString;
    source="",
    position=SourcePosition(1, 1, 1),
)
    parser = ExpressionParser(tokenize(text; source=source, position=position), 1)
    expression = _parse_precedence!(parser, 1)
    _check(parser, :eof) || throw(ParseError("unexpected token $(_current(parser).text)", _current(parser).span))
    return expression
end
