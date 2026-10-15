mutable struct HybridJuMPArtifact{T,O}
    model::JuMP.Model
    compiled::HybridCompiledSystem{T}
    variables::Dict{VariableId,JuMP.VariableRef}
    constraints::Vector{Any}
    nonlinear_constraints::Vector{Any}
    source_revision::UInt64
    optimizer::O
end

_linear_compiled(artifact::HybridJuMPArtifact) = artifact.compiled.linear

function _residual_value_function(template, instance, residual_index)
    return function (x...)
        values = evaluate_residuals(template, collect(x), instance.parameters)
        return values isa Number ? values : values[residual_index]
    end
end

function _residual_gradient_function(template, instance, residual_index, dimension)
    if dimension == 1
        return function (x)
            jacobian = evaluate_jacobian(template, [x], instance.parameters)
            return jacobian isa Number ? jacobian : jacobian[residual_index, 1]
        end
    end
    return function (gradient, x...)
        jacobian = evaluate_jacobian(template, collect(x), instance.parameters)
        for column in 1:dimension
            gradient[column] = jacobian[residual_index, column]
        end
        return nothing
    end
end

function _operator_name(instance::NonlinearInstance, residual_index::Int)
    return Symbol(
        :hubs_residual_,
        instance.template_key,
        :_,
        instance.owner.kind,
        :_,
        instance.owner.slot,
        :_,
        instance.owner.generation,
        :_,
        instance.index,
        :_,
        residual_index,
    )
end

function _add_nonlinear_constraints!(artifact::HybridJuMPArtifact{T}) where {T}
    for instance in artifact.compiled.nonlinear_instances
        template = artifact.compiled.nonlinear_templates[instance.template_key]
        dimension = length(instance.variable_ids)
        variables = [artifact.variables[id] for id in instance.variable_ids]
        for residual_index in eachindex(template.residuals)
            value_function = _residual_value_function(template, instance, residual_index)
            gradient_function = _residual_gradient_function(
                template,
                instance,
                residual_index,
                dimension,
            )
            operator = JuMP.add_nonlinear_operator(
                artifact.model,
                dimension,
                value_function,
                gradient_function;
                name=_operator_name(instance, residual_index),
            )
            expression = operator(variables...)
            reference = JuMP.add_constraint(
                artifact.model,
                JuMP.ScalarConstraint(expression, JuMP.MOI.EqualTo(zero(T))),
            )
            push!(artifact.nonlinear_constraints, reference)
        end
    end
    return artifact
end

function build_model(compiled::HybridCompiledSystem{T}, optimizer) where {T}
    linear = build_model(compiled.linear, optimizer)
    artifact = HybridJuMPArtifact(
        linear.model,
        compiled,
        linear.variables,
        linear.constraints,
        Any[],
        compiled.linear.source_revision,
        optimizer,
    )
    return _add_nonlinear_constraints!(artifact)
end

function refreshParameters(artifact::HybridJuMPArtifact, system::HubSystem)
    Compiler.refreshParameters(artifact.compiled, system)
    _sync_linear_constraints!(artifact)
    _sync_linear_objective!(artifact)
    artifact.source_revision = artifact.compiled.linear.source_revision
    return artifact
end

function rebuildStructure(artifact::HybridJuMPArtifact, system::HubSystem)
    compiled = Compiler.recompileStructure(artifact.compiled, system)
    return build_model(compiled, artifact.optimizer)
end

solve!(artifact::HybridJuMPArtifact) = (JuMP.optimize!(artifact.model); artifact)
objective_value(artifact::HybridJuMPArtifact) = JuMP.objective_value(artifact.model)
value(artifact::HybridJuMPArtifact, id::VariableId) = JuMP.value(artifact.variables[id])
