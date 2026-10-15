mutable struct JuMPArtifact{T}
    model::JuMP.Model
    compiled::CompiledSystem{T}
    variables::Dict{VariableId,JuMP.VariableRef}
    constraints::Vector{Any}
    source_revision::UInt64
end

function _add_variable(model::JuMP.Model, variable::CompiledVariable)
    reference = JuMP.@variable(model)
    JuMP.set_name(reference, string(variable.key.owner.kind, "_", variable.key.owner.slot, "_", variable.key.name, "_", variable.key.index))
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

function build_model(compiled::CompiledSystem{T}, optimizer) where {T}
    model = JuMP.Model(optimizer)
    variable_references = Dict{VariableId,JuMP.VariableRef}()
    sizehint!(variable_references, length(compiled.variables))
    for (id, variable) in compiled.variables
        variable_references[id] = _add_variable(model, variable)
    end

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
                    variable_references[block.variable_ids[position]],
                )
            end
            constraint_index += 1
            constraint = JuMP.ScalarConstraint(expression, _constraint_set(block.senses[row], block.rhs[row]))
            reference = JuMP.add_constraint(model, constraint)
            JuMP.set_name(reference, string(block.rows[row].owner.kind, "_", block.rows[row].owner.slot, "_", block.rows[row].name, "_", block.rows[row].index))
            constraints[constraint_index] = reference
        end
    end

    objective = JuMP.AffExpr(0.0)
    for position in eachindex(compiled.objective.variable_ids)
        JuMP.add_to_expression!(
            objective,
            compiled.objective.coefficients[position],
            variable_references[compiled.objective.variable_ids[position]],
        )
    end
    JuMP.set_objective_sense(model, JuMP.MOI.MIN_SENSE)
    JuMP.set_objective_function(model, objective)
    return JuMPArtifact{T}(
        model,
        compiled,
        variable_references,
        constraints,
        compiled.source_revision,
    )
end

function _sync_linear_constraints!(artifact::JuMPArtifact)
    constraint_index = 0
    for block in artifact.compiled.blocks
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
                JuMP.set_normalized_coefficient(reference, artifact.variables[id], coefficient)
            end
            JuMP.set_normalized_rhs(reference, block.rhs[row])
        end
    end
    return artifact
end

function _sync_linear_objective!(artifact::JuMPArtifact)
    coefficients = Dict{VariableId,eltype(artifact.compiled.objective.coefficients)}()
    for position in eachindex(artifact.compiled.objective.variable_ids)
        id = artifact.compiled.objective.variable_ids[position]
        coefficients[id] = get(coefficients, id, zero(eltype(artifact.compiled.objective.coefficients))) +
            artifact.compiled.objective.coefficients[position]
    end
    for (id, coefficient) in coefficients
        JuMP.set_objective_coefficient(artifact.model, artifact.variables[id], coefficient)
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

solve!(artifact::JuMPArtifact) = (JuMP.optimize!(artifact.model); artifact)
objective_value(artifact::JuMPArtifact) = JuMP.objective_value(artifact.model)
value(artifact::JuMPArtifact, id::VariableId) = JuMP.value(artifact.variables[id])
