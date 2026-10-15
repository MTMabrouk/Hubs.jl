struct VariableReferences
    values::Vector{JuMP.VariableRef}
end

Base.length(references::VariableReferences) = length(references.values)
Base.getindex(references::VariableReferences, slot::Int) = references.values[slot]
Base.getindex(references::VariableReferences, id::VariableId) = references.values[id.slot]
Base.iterate(references::VariableReferences, state...) = iterate(references.values, state...)

mutable struct JuMPArtifact{T,O}
    model::JuMP.Model
    compiled::CompiledSystem{T}
    variables::VariableReferences
    constraints::Vector{Any}
    source_revision::UInt64
    optimizer::O
    direct::Bool
    names::Bool
end

function _add_variable(model::JuMP.Model, variable::CompiledVariable, names::Bool)
    reference = JuMP.@variable(model)
    if names
        JuMP.set_name(reference, string(variable.key.owner.kind, "_", variable.key.owner.slot, "_", variable.key.name, "_", variable.key.index))
    end
    isfinite(variable.lower_bound) && JuMP.set_lower_bound(reference, variable.lower_bound)
    isfinite(variable.upper_bound) && JuMP.set_upper_bound(reference, variable.upper_bound)
    if variable.domain == IntegerDomain
        JuMP.set_integer(reference)
    elseif variable.domain == BinaryDomain
        JuMP.set_binary(reference)
    end
    return reference
end

function _constraint_set(sense::ConstraintSense, rhs)
    sense == EqualTo && return JuMP.MOI.EqualTo(rhs)
    sense == LessThan && return JuMP.MOI.LessThan(rhs)
    sense == GreaterThan && return JuMP.MOI.GreaterThan(rhs)
    throw(ArgumentError("unsupported constraint sense $sense"))
end

"""
    build_model(compiled, optimizer; direct=false, names=false)

Populate a JuMP/MOI model from compiled linear blocks. Scalar solver names are
disabled by default because generating them is unnecessary for solving and adds
substantial construction overhead; pass `names=true` for an inspectable model.
"""
function build_model(
    compiled::CompiledSystem{T},
    optimizer;
    direct::Bool=false,
    names::Bool=false,
) where {T}
    model = if isnothing(optimizer)
        JuMP.Model()
    elseif direct
        JuMP.direct_model(optimizer())
    else
        JuMP.Model(optimizer)
    end
    variable_values = Vector{JuMP.VariableRef}(undef, length(compiled.variables))
    for (id, variable) in compiled.variables
        variable_values[id.slot] = _add_variable(model, variable, names)
    end
    variable_references = VariableReferences(variable_values)

    number_of_constraints = sum(length, compiled.blocks; init=0)
    constraints = Vector{Any}(undef, number_of_constraints)
    constraint_index = 0
    for block in compiled.blocks
        for row in 1:length(block)
            expression = JuMP.AffExpr(0.0)
            for position in block.rowptr[row]:(block.rowptr[row + 1] - 1)
                JuMP.add_to_expression!(
                    expression,
                    block.coefficients[position],
                    variable_references[block.variable_ids[position].slot],
                )
            end
            constraint_index += 1
            constraint = JuMP.ScalarConstraint(expression, _constraint_set(block.senses[row], block.rhs[row]))
            reference = JuMP.add_constraint(model, constraint)
            if names
                JuMP.set_name(reference, string(block.rows[row].owner.kind, "_", block.rows[row].owner.slot, "_", block.rows[row].name, "_", block.rows[row].index))
            end
            constraints[constraint_index] = reference
        end
    end

    objective = JuMP.AffExpr(0.0)
    for position in eachindex(compiled.objective.variable_ids)
        JuMP.add_to_expression!(
            objective,
            compiled.objective.coefficients[position],
            variable_references[compiled.objective.variable_ids[position].slot],
        )
    end
    JuMP.set_objective_sense(model, JuMP.MOI.MIN_SENSE)
    JuMP.set_objective_function(model, objective)
    return JuMPArtifact(
        model,
        compiled,
        variable_references,
        constraints,
        compiled.source_revision,
        optimizer,
        direct,
        names,
    )
end

_linear_compiled(artifact::JuMPArtifact) = artifact.compiled

function _sync_linear_constraints!(artifact)
    compiled = _linear_compiled(artifact)
    constraint_index = 0
    for block in compiled.blocks
        for row in 1:length(block)
            constraint_index += 1
            reference = artifact.constraints[constraint_index]
            coefficients = Dict{VariableId,eltype(block.coefficients)}()
            for position in block.rowptr[row]:(block.rowptr[row + 1] - 1)
                id = block.variable_ids[position]
                coefficients[id] = get(coefficients, id, zero(eltype(block.coefficients))) +
                    block.coefficients[position]
            end
            for (id, coefficient) in coefficients
                JuMP.set_normalized_coefficient(reference, artifact.variables[id.slot], coefficient)
            end
            JuMP.set_normalized_rhs(reference, block.rhs[row])
        end
    end
    return artifact
end

function _sync_linear_objective!(artifact)
    compiled = _linear_compiled(artifact)
    coefficients = Dict{VariableId,eltype(compiled.objective.coefficients)}()
    for position in eachindex(compiled.objective.variable_ids)
        id = compiled.objective.variable_ids[position]
        coefficients[id] = get(coefficients, id, zero(eltype(compiled.objective.coefficients))) +
            compiled.objective.coefficients[position]
    end
    for (id, coefficient) in coefficients
        JuMP.set_objective_coefficient(artifact.model, artifact.variables[id.slot], coefficient)
    end
    return artifact
end

function refreshParameters(artifact::JuMPArtifact, system::HubSystem)
    Compiler.refreshParameters(artifact.compiled, system)
    _sync_linear_constraints!(artifact)
    _sync_linear_objective!(artifact)
    artifact.source_revision = artifact.compiled.source_revision
    return artifact
end

function rebuildStructure(artifact::JuMPArtifact, system::HubSystem)
    compiled = Compiler.recompileStructure(artifact.compiled, system)
    return build_model(
        compiled,
        artifact.optimizer;
        direct=artifact.direct,
        names=artifact.names,
    )
end

solve!(artifact::JuMPArtifact) = (JuMP.optimize!(artifact.model); artifact)
objective_value(artifact::JuMPArtifact) = JuMP.objective_value(artifact.model)
value(artifact::JuMPArtifact, id::VariableId) = JuMP.value(artifact.variables[id.slot])
