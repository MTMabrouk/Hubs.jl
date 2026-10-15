module Compiler

using ..Domain

include("linear.jl")

export CompiledSystem,
    CompiledVariable,
    ConstraintKey,
    LinearBlock,
    LinearObjective,
    OwnerRef,
    VariableKey,
    compile_linear,
    variable_id

end
