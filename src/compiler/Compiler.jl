module Compiler

using ..Domain
using SparseArrays
using Symbolics

include("linear.jl")
include("nonlinear.jl")

export CompiledSystem,
    CompiledVariable,
    ConstraintKey,
    HybridCompiledSystem,
    LinearBlock,
    LinearObjective,
    NonlinearInstance,
    NonlinearTemplate,
    OwnerRef,
    VariableKey,
    compile_hybrid,
    compile_linear,
    evaluate_jacobian,
    evaluate_residuals,
    refreshParameters,
    variable_id

end
