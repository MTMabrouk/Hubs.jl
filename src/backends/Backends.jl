module Backends

using JuMP
using ..Domain
using ..Compiler

include("jump.jl")

export JuMPArtifact,
    build_model,
    objective_value,
    rebuildStructure,
    refreshParameters,
    solve!,
    value

end
