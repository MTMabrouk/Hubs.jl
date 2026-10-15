module Backends

using JuMP
using ..Domain
using ..Compiler

include("jump.jl")
include("nonlinear_jump.jl")

export HybridJuMPArtifact,
    JuMPArtifact,
    build_model,
    objective_value,
    rebuildStructure,
    refreshParameters,
    solve!,
    value

end
