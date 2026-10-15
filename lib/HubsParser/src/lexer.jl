struct Token
    kind::Symbol
    text::String
    span::SourceSpan
end

mutable struct Lexer
    characters::Vector{Char}
    source::String
    cursor::Int
    offset::Int
    line::Int
    column::Int
end

Lexer(text::AbstractString, source::AbstractString, position::SourcePosition) =
    Lexer(collect(text), String(source), 1, position.offset, position.line, position.column)

_at_end(lexer::Lexer) = lexer.cursor > length(lexer.characters)
_peek(lexer::Lexer, distance=0) = lexer.cursor + distance <= length(lexer.characters) ? lexer.characters[lexer.cursor + distance] : '\0'
_position(lexer::Lexer) = SourcePosition(lexer.offset, lexer.line, lexer.column)

function _advance!(lexer::Lexer)
    character = _peek(lexer)
    _at_end(lexer) && return character
    lexer.cursor += 1
    lexer.offset += 1
    if character == '\n'
        lexer.line += 1
        lexer.column = 1
    else
        lexer.column += 1
    end
    return character
end

function _token(lexer::Lexer, kind::Symbol, text::AbstractString, first::SourcePosition)
    last = _position(lexer)
    return Token(kind, String(text), _span(lexer.source, first, last))
end

function _skip_space!(lexer::Lexer)
    while isspace(_peek(lexer))
        _advance!(lexer)
    end
end

_identifier_start(character::Char) = isletter(character) || character == '_'
_identifier_part(character::Char) = isletter(character) || isnumeric(character) || character == '_'

function _lex_identifier!(lexer::Lexer)
    first = _position(lexer)
    buffer = IOBuffer()
    while _identifier_part(_peek(lexer))
        print(buffer, _advance!(lexer))
    end
    text = String(take!(buffer))
    kind = text == "true" || text == "false" ? :boolean : :identifier
    return _token(lexer, kind, text, first)
end

function _lex_number!(lexer::Lexer)
    first = _position(lexer)
    buffer = IOBuffer()
    while isnumeric(_peek(lexer))
        print(buffer, _advance!(lexer))
    end
    if _peek(lexer) == '.' && isnumeric(_peek(lexer, 1))
        print(buffer, _advance!(lexer))
        while isnumeric(_peek(lexer))
            print(buffer, _advance!(lexer))
        end
    end
    if lowercase(string(_peek(lexer))) == "e"
        print(buffer, _advance!(lexer))
        if _peek(lexer) == '+' || _peek(lexer) == '-'
            print(buffer, _advance!(lexer))
        end
        isnumeric(_peek(lexer)) || throw(ParseError("expected exponent digits", _span(lexer.source, first, _position(lexer))))
        while isnumeric(_peek(lexer))
            print(buffer, _advance!(lexer))
        end
    end
    return _token(lexer, :number, String(take!(buffer)), first)
end

function _lex_string!(lexer::Lexer)
    first = _position(lexer)
    _advance!(lexer)
    buffer = IOBuffer()
    while !_at_end(lexer) && _peek(lexer) != '"'
        character = _advance!(lexer)
        if character == '\\'
            _at_end(lexer) && throw(ParseError("unterminated string escape", _span(lexer.source, first, _position(lexer))))
            escaped = _advance!(lexer)
            escaped == 'n' ? print(buffer, '\n') :
            escaped == 't' ? print(buffer, '\t') :
            escaped == 'r' ? print(buffer, '\r') : print(buffer, escaped)
        else
            print(buffer, character)
        end
    end
    _at_end(lexer) && throw(ParseError("unterminated string", _span(lexer.source, first, _position(lexer))))
    _advance!(lexer)
    return _token(lexer, :string, String(take!(buffer)), first)
end

function tokenize(text::AbstractString; source="", position=SourcePosition(1, 1, 1))
    lexer = Lexer(text, source, position)
    tokens = Token[]
    pairs = Dict(
        ('<', '=') => :less_equal,
        ('>', '=') => :greater_equal,
        ('=', '=') => :equal_equal,
        ('!', '=') => :not_equal,
    )
    singles = Dict(
        '+' => :plus,
        '-' => :minus,
        '*' => :star,
        '/' => :slash,
        '^' => :caret,
        '~' => :tilde,
        '<' => :less,
        '>' => :greater,
        '=' => :equal,
        '(' => :left_paren,
        ')' => :right_paren,
        '[' => :left_bracket,
        ']' => :right_bracket,
        '{' => :left_brace,
        '}' => :right_brace,
        ',' => :comma,
        '.' => :dot,
    )

    while !_at_end(lexer)
        _skip_space!(lexer)
        _at_end(lexer) && break
        character = _peek(lexer)
        if _identifier_start(character)
            push!(tokens, _lex_identifier!(lexer))
        elseif isnumeric(character)
            push!(tokens, _lex_number!(lexer))
        elseif character == '"'
            push!(tokens, _lex_string!(lexer))
        else
            first = _position(lexer)
            if haskey(pairs, (character, _peek(lexer, 1)))
                text = string(_advance!(lexer), _advance!(lexer))
                push!(tokens, _token(lexer, pairs[(character, text[2])], text, first))
            elseif haskey(singles, character)
                text = string(_advance!(lexer))
                push!(tokens, _token(lexer, singles[character], text, first))
            else
                _advance!(lexer)
                throw(ParseError("unexpected character $(repr(character))", _span(lexer.source, first, _position(lexer))))
            end
        end
    end
    position = _position(lexer)
    push!(tokens, Token(:eof, "", _span(lexer.source, position, position)))
    return tokens
end
