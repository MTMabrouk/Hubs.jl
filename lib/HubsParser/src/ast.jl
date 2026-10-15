struct SourcePosition
    offset::Int
    line::Int
    column::Int
end

struct SourceSpan
    source::String
    first::SourcePosition
    last::SourcePosition
end

abstract type SyntaxNode end
abstract type ExprNode <: SyntaxNode end

struct IdentifierExpr <: ExprNode
    parts::Vector{Symbol}
    span::SourceSpan
end

IdentifierExpr(name::Symbol, span::SourceSpan) = IdentifierExpr(Symbol[name], span)

struct NumberLiteral{T<:Real} <: ExprNode
    value::T
    span::SourceSpan
end

struct StringLiteral <: ExprNode
    value::String
    span::SourceSpan
end

struct BooleanLiteral <: ExprNode
    value::Bool
    span::SourceSpan
end

struct ArrayExpr <: ExprNode
    elements::Vector{ExprNode}
    span::SourceSpan
end

struct MapExpr <: ExprNode
    entries::Vector{Pair{Symbol,ExprNode}}
    span::SourceSpan
end

struct CallExpr <: ExprNode
    callee::ExprNode
    arguments::Vector{ExprNode}
    span::SourceSpan
end

struct UnaryExpr <: ExprNode
    operator::Symbol
    operand::ExprNode
    span::SourceSpan
end

struct BinaryExpr <: ExprNode
    operator::Symbol
    left::ExprNode
    right::ExprNode
    span::SourceSpan
end

struct Annotation <: SyntaxNode
    name::Symbol
    arguments::Vector{ExprNode}
    span::SourceSpan
end

struct Declaration <: SyntaxNode
    name::Symbol
    indices::Vector{Symbol}
    value::ExprNode
    annotations::Vector{Annotation}
    span::SourceSpan
end

struct Section <: SyntaxNode
    path::Vector{Symbol}
    declarations::Vector{Declaration}
    span::SourceSpan
end

struct Document <: SyntaxNode
    source::String
    sections::Vector{Section}
end

function section(document::Document, path::Symbol...)
    wanted = collect(path)
    matches = filter(candidate -> candidate.path == wanted, document.sections)
    isempty(matches) && throw(KeyError(join(string.(wanted), '.')))
    length(matches) == 1 || throw(ArgumentError("section $(join(string.(wanted), '.')) is declared more than once"))
    return only(matches)
end

function declaration(section::Section, name::Symbol)
    matches = filter(candidate -> candidate.name == name, section.declarations)
    isempty(matches) && throw(KeyError(name))
    length(matches) == 1 || throw(ArgumentError("declaration $name occurs more than once"))
    return only(matches)
end

struct ParseError <: Exception
    message::String
    span::SourceSpan
end

function Base.showerror(io::IO, error::ParseError)
    location = isempty(error.span.source) ? "<input>" : error.span.source
    print(io, location, ':', error.span.first.line, ':', error.span.first.column, ": ", error.message)
end

_span(source, first::SourcePosition, last::SourcePosition) = SourceSpan(String(source), first, last)

function _merge_span(left::SourceSpan, right::SourceSpan)
    source = isempty(left.source) ? right.source : left.source
    return SourceSpan(source, left.first, right.last)
end
