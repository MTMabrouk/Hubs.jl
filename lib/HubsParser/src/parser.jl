const _SYMBOLIC_SECTIONS = Set([:equations, :expressions, :objective])

mutable struct SectionBuilder
    path::Vector{Symbol}
    declarations::Vector{Declaration}
    first::SourcePosition
    last::SourcePosition
end

function _remove_comment(line::AbstractString)
    quoted = false
    escaped = false
    characters = collect(line)
    for index in eachindex(characters)
        character = characters[index]
        if escaped
            escaped = false
        elseif character == '\\' && quoted
            escaped = true
        elseif character == '"'
            quoted = !quoted
        elseif character == '#' && !quoted
            return String(characters[1:index-1])
        end
    end
    return String(line)
end

function _section_path(line, source, position)
    matched = match(r"^\[([A-Za-z_][A-Za-z0-9_.]*)\]$", strip(line))
    matched === nothing && throw(ParseError("invalid section header", _span(source, position, position)))
    return Symbol.(split(matched.captures[1], '.'))
end

function _find_assignment(text::AbstractString)
    characters = collect(text)
    depth = 0
    quoted = false
    escaped = false
    for index in eachindex(characters)
        character = characters[index]
        if escaped
            escaped = false
        elseif character == '\\' && quoted
            escaped = true
        elseif character == '"'
            quoted = !quoted
        elseif !quoted
            character in ('(', '[', '{') && (depth += 1)
            character in (')', ']', '}') && (depth -= 1)
            if character == '=' && depth == 0
                previous = index > firstindex(characters) ? characters[index - 1] : '\0'
                following = index < lastindex(characters) ? characters[index + 1] : '\0'
                previous in ('<', '>', '!', '=') && continue
                following == '=' && continue
                return index
            end
        end
    end
    return nothing
end

function _parse_lhs(text, source, position)
    matched = match(r"^([A-Za-z_][A-Za-z0-9_]*)(?:\(([^)]*)\))?$", strip(text))
    matched === nothing && throw(ParseError("expected a name or indexed name on the left of '='", _span(source, position, position)))
    indices = if matched.captures[2] === nothing || isempty(strip(matched.captures[2]))
        Symbol[]
    else
        values = strip.(split(matched.captures[2], ','))
        all(value -> occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", value), values) ||
            throw(ParseError("expression indices must be identifiers", _span(source, position, position)))
        Symbol.(values)
    end
    return Symbol(matched.captures[1]), indices
end

function _parse_annotation(text::AbstractString, source, position)
    characters = collect(strip(text))
    isempty(characters) || first(characters) == '@' ||
        throw(ParseError("expected annotation", _span(source, position, position)))
    index = 2
    while index <= length(characters) && _identifier_part(characters[index])
        index += 1
    end
    index == 2 && throw(ParseError("expected annotation name", _span(source, position, position)))
    name = Symbol(String(characters[2:index-1]))
    arguments = ExprNode[]
    if index <= length(characters) && characters[index] == '('
        depth = 1
        stop = index + 1
        while stop <= length(characters) && depth > 0
            characters[stop] == '(' && (depth += 1)
            characters[stop] == ')' && (depth -= 1)
            stop += 1
        end
        depth == 0 || throw(ParseError("unterminated annotation arguments", _span(source, position, position)))
        argument_text = strip(String(characters[index+1:stop-2]))
        if !isempty(argument_text)
            argument_tokens = tokenize(argument_text; source=source, position=position)
            argument_parser = ExpressionParser(argument_tokens, 1)
            while !_check(argument_parser, :eof)
                push!(arguments, _parse_precedence!(argument_parser, 1))
                _match!(argument_parser, :comma) || break
            end
            _check(argument_parser, :eof) ||
                throw(ParseError("expected ',' between annotation arguments", _current(argument_parser).span))
        end
        index = stop
    end
    remainder = index <= length(characters) ? strip(String(characters[index:end])) : ""
    span = _span(source, position, SourcePosition(position.offset + length(characters), position.line, position.column + length(characters)))
    return Annotation(name, arguments, span), remainder
end

function _parse_declaration(text, source, first, last, annotations)
    assignment = _find_assignment(text)
    assignment === nothing && throw(ParseError("expected '=' in declaration", _span(source, first, last)))
    characters = collect(text)
    left = String(characters[1:assignment-1])
    right = String(characters[assignment+1:end])
    name, indices = _parse_lhs(left, source, first)
    isempty(strip(right)) && throw(ParseError("expected a value after '='", _span(source, first, last)))
    value = parse_expression(right; source=source, position=first)
    return Declaration(name, indices, value, copy(annotations), _span(source, first, last))
end

function _finish_section!(sections, builder, source)
    builder === nothing && return
    push!(sections, Section(builder.path, builder.declarations, _span(source, builder.first, builder.last)))
end

function _top_level_semicolon(text::AbstractString)
    depth = 0
    quoted = false
    escaped = false
    characters = collect(text)
    for index in eachindex(characters)
        character = characters[index]
        if escaped
            escaped = false
        elseif character == '\\' && quoted
            escaped = true
        elseif character == '"'
            quoted = !quoted
        elseif !quoted
            character in ('(', '[', '{') && (depth += 1)
            character in (')', ']', '}') && (depth -= 1)
            character == ';' && depth == 0 && return index
        end
    end
    return nothing
end

function parse_document(text::AbstractString; source="")
    normalized = replace(String(text), "\r\n" => "\n", '\r' => '\n')
    lines = split(normalized, '\n'; keepempty=true)
    sections = Section[]
    builder = nothing
    pending_annotations = Annotation[]
    statement_parts = String[]
    statement_first = nothing
    absolute_offset = 1

    for (line_number, raw_line) in enumerate(lines)
        line = _remove_comment(raw_line)
        stripped = strip(line)
        first_nonspace = findfirst(character -> !isspace(character), collect(line))
        column = first_nonspace === nothing ? 1 : first_nonspace
        position = SourcePosition(absolute_offset + column - 1, line_number, column)
        line_last = SourcePosition(absolute_offset + length(collect(raw_line)), line_number, length(collect(raw_line)) + 1)

        if isempty(stripped)
            absolute_offset += length(collect(raw_line)) + 1
            continue
        end

        if startswith(stripped, '[')
            position_statement = statement_first
            position_statement === nothing ||
                throw(ParseError("unterminated statement; expected ';'", _span(source, position_statement, position)))
            isempty(pending_annotations) ||
                throw(ParseError("annotation is not followed by a declaration", pending_annotations[1].span))
            _finish_section!(sections, builder, source)
            path = _section_path(stripped, source, position)
            builder = SectionBuilder(path, Declaration[], position, line_last)
            absolute_offset += length(collect(raw_line)) + 1
            continue
        end

        builder === nothing && throw(ParseError("declaration appears before the first section", _span(source, position, line_last)))
        builder.last = line_last

        remainder = stripped
        while startswith(remainder, '@')
            annotation, remainder = _parse_annotation(remainder, source, position)
            push!(pending_annotations, annotation)
            isempty(remainder) && break
        end
        if isempty(remainder)
            absolute_offset += length(collect(raw_line)) + 1
            continue
        end

        symbolic = first(builder.path) in _SYMBOLIC_SECTIONS
        if symbolic
            statement_first === nothing && (statement_first = position)
            push!(statement_parts, remainder)
            contents = join(statement_parts, '\n')
            terminator = _top_level_semicolon(contents)
            if terminator !== nothing
                characters = collect(contents)
                trailing = strip(String(characters[terminator+1:end]))
                isempty(trailing) || throw(ParseError("only one symbolic declaration is allowed before ';'", _span(source, position, line_last)))
                declaration_text = String(characters[1:terminator-1])
                push!(builder.declarations, _parse_declaration(
                    declaration_text,
                    source,
                    statement_first,
                    line_last,
                    pending_annotations,
                ))
                empty!(statement_parts)
                statement_first = nothing
                empty!(pending_annotations)
            end
        else
            push!(builder.declarations, _parse_declaration(
                remainder,
                source,
                position,
                line_last,
                pending_annotations,
            ))
            empty!(pending_annotations)
        end

        absolute_offset += length(collect(raw_line)) + 1
    end

    statement_first === nothing ||
        throw(ParseError("unterminated statement; expected ';'", _span(source, statement_first, statement_first)))
    isempty(pending_annotations) ||
        throw(ParseError("annotation is not followed by a declaration", pending_annotations[1].span))
    _finish_section!(sections, builder, source)
    return Document(String(source), sections)
end

parse_file(path::AbstractString) = parse_document(read(path, String); source=String(path))
