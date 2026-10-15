module ModelLanguage

using HubsParser
using ..Domain

include("semantic.jl")
include("analysis.jl")
include("domain.jl")

export ComponentDefinition,
    EquationDefinition,
    ExpressionDefinition,
    LanguageComponentModel,
    ObjectiveDefinition,
    ObjectiveProgram,
    ParameterDefinition,
    PortDefinition,
    SemanticError,
    VariableDefinition,
    expression_contributors,
    component_ports,
    component_model,
    load_component,
    load_objective,
    lower_component,
    lower_objective,
    validate_objective,
    validate_references

end
