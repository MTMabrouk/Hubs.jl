using HiGHS
using JuMP

@testset "Incremental parameter updates" begin
    D = Hubs.Domain
    C = Hubs.Compiler
    B = Hubs.Backends

    system = D.HubSystem(steps=1)
    fuel = D.addCarrier(system, D.Carrier(:fuel))
    electricity = D.addCarrier(system, D.Carrier(:electricity))
    hub = D.addHub(system, D.Hub(:site))

    process_model = D.LinearComponentModel(
        [
            D.VariableSpec(:fuel, D.InputFlow; lower_bound=0.0),
            D.VariableSpec(:electricity, D.OutputFlow; lower_bound=0.0),
        ],
        [D.ParameterSpec(:efficiency)],
        [D.LinearEquation(:conversion, [
            D.LinearTerm(:electricity, 1.0),
            D.LinearTerm(:fuel, D.ParameterCoefficient(:efficiency, -1.0)),
        ])],
    )
    process_id = D.addProcess(system, hub, D.Process(
        :generator,
        [
            D.Port(:fuel_in, fuel, D.Input; variable=:fuel),
            D.Port(:power_out, electricity, D.Output; variable=:electricity),
        ],
        process_model;
        parameters=(efficiency=0.5,),
    ))

    boundary_model = D.LinearComponentModel(
        [D.VariableSpec(:fuel_import, D.OutputFlow; lower_bound=0.0)],
        [D.ParameterSpec(:price)],
        D.LinearEquation[],
        [D.LinearObjectiveTerm(:fuel_import, D.ParameterCoefficient(:price))],
    )
    boundary_id = D.addBoundary(system, hub, D.Boundary(
        :fuel_supply,
        D.Port(:fuel_import, fuel, D.Output; variable=:fuel_import),
        D.Import,
        boundary_model;
        parameters=(price=2.0,),
    ))
    D.addDemand(system, hub, D.Demand(:load, D.Port(:load, electricity, D.Input), 10.0))

    compiled = C.compile_linear(system)
    variables_before = compiled.variables
    rowptr_before = first(compiled.blocks).rowptr
    revision_before = compiled.source_revision

    D.setParameters(system, process_id; efficiency=0.8)
    D.setParameters(system, boundary_id; price=3.0)
    @test_throws ArgumentError D.setParameters(system, process_id; efficency=0.9)
    changes = D.changesSince(system, revision_before)
    @test !D.isstructural(changes)
    @test length(changes.changes) == 2
    @test all(change.kind == D.ParameterUpdate for change in changes.changes)

    C.refreshParameters(compiled, system)
    @test compiled.variables === variables_before
    @test first(compiled.blocks).rowptr === rowptr_before
    @test compiled.source_revision == system.revision
    process_block = only(block for block in compiled.blocks if block.owner == C.OwnerRef(process_id))
    @test process_block.coefficients == [1.0, -0.8]
    @test compiled.objective.coefficients == [3.0]

    artifact = B.build_model(compiled, HiGHS.Optimizer)
    set_silent(artifact.model)
    B.solve!(artifact)
    @test termination_status(artifact.model) == JuMP.MOI.OPTIMAL
    @test B.objective_value(artifact) ≈ 37.5

    D.addCarrier(system, D.Carrier(:heat))
    @test D.isstructural(D.changesSince(system, compiled.source_revision))
    @test_throws ArgumentError C.refreshParameters(compiled, system)
end

@testset "Incremental Symbolics parameters" begin
    D = Hubs.Domain
    C = Hubs.Compiler

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
    process_id = D.addProcess(system, hub, D.Process(
        :cogenerator,
        [
            D.Port(:fuel, fuel, D.Input; variable=:fuel),
            D.Port(:power, power, D.Output; variable=:power),
            D.Port(:heat, heat, D.Output; variable=:heat),
        ],
        model;
        parameters=(efficiency=0.25, heat_ratio=0.4),
    ))

    compiled = C.compile_hybrid(system)
    template = only(values(compiled.nonlinear_templates))
    affine_block = only(block for block in compiled.linear.blocks if
        block.owner == C.OwnerRef(process_id) && startswith(String(first(block.rows).name), "symbolic_affine"))

    D.setParameters(system, process_id; efficiency=0.5, heat_ratio=0.7)
    C.refreshParameters(compiled, system)

    @test only(values(compiled.nonlinear_templates)) === template
    @test only(compiled.nonlinear_instances).parameters == [0.5, 0.7]
    @test affine_block.coefficients == [-0.7, 1.0]
end
