using JuMP

@testset "Symbolics JuMP backend" begin
    D = Hubs.Domain
    C = Hubs.Compiler
    B = Hubs.Backends

    Hubs.Domain.Symbolics.@variables fuel_symbol power_symbol heat_symbol efficiency_symbol heat_ratio_symbol
    model = D.SymbolicComponentModel(
        [
            D.VariableSpec(:fuel, D.InputFlow; lower_bound=0.0),
            D.VariableSpec(:power, D.OutputFlow; lower_bound=0.0),
            D.VariableSpec(:heat, D.OutputFlow; lower_bound=0.0),
        ],
        [D.ParameterSpec(:efficiency), D.ParameterSpec(:heat_ratio)],
        (; fuel=fuel_symbol, power=power_symbol, heat=heat_symbol),
        (; efficiency=efficiency_symbol, heat_ratio=heat_ratio_symbol),
        [
            power_symbol - efficiency_symbol * fuel_symbol^2,
            heat_symbol - heat_ratio_symbol * fuel_symbol,
        ],
    )

    system = D.HubSystem(steps=1)
    fuel = D.addCarrier(system, D.Carrier(:fuel))
    power = D.addCarrier(system, D.Carrier(:power))
    heat = D.addCarrier(system, D.Carrier(:heat))
    hub = D.addHub(system, D.Hub(:site))
    make_process(name) = D.Process(
        name,
        [
            D.Port(:fuel, fuel, D.Input; variable=:fuel),
            D.Port(:power, power, D.Output; variable=:power),
            D.Port(:heat, heat, D.Output; variable=:heat),
        ],
        model;
        parameters=(efficiency=0.25, heat_ratio=0.4),
    )
    process_id = D.addProcess(system, hub, make_process(:cogenerator))

    compiled = C.compile_hybrid(system)
    template = only(values(compiled.nonlinear_templates))
    artifact = B.build_model(compiled, nothing)
    @test artifact isa B.HybridJuMPArtifact
    @test length(artifact.nonlinear_constraints) == 1

    fuel_id = C.variable_id(compiled.linear, process_id, :fuel, 1)
    power_id = C.variable_id(compiled.linear, process_id, :power, 1)
    heat_id = C.variable_id(compiled.linear, process_id, :heat, 1)
    point_values = Dict(
        artifact.variables[fuel_id] => 2.0,
        artifact.variables[power_id] => 2.0,
        artifact.variables[heat_id] => 0.8,
    )
    nonlinear_expression = JuMP.constraint_object(only(artifact.nonlinear_constraints)).func
    @test JuMP.value(variable -> point_values[variable], nonlinear_expression) ≈ 1.0

    D.setParameters(system, process_id; efficiency=0.5, heat_ratio=0.6)
    B.refreshParameters(artifact, system)
    @test JuMP.value(variable -> point_values[variable], nonlinear_expression) ≈ 0.0
    affine_block = only(block for block in compiled.linear.blocks if
        block.owner == C.OwnerRef(process_id) && startswith(String(first(block.rows).name), "symbolic_affine"))
    @test affine_block.coefficients == [-0.6, 1.0]

    D.addProcess(system, hub, make_process(:second))
    rebuilt = B.rebuildStructure(artifact, system)
    @test length(rebuilt.nonlinear_constraints) == 2
    @test only(values(rebuilt.compiled.nonlinear_templates)) === template
end
