using HiGHS
using JuMP

@testset "JuMP backend" begin
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
    process_id = D.addProcess(
        system,
        hub,
        D.Process(
            :generator,
            [
                D.Port(:fuel_in, fuel, D.Input; variable=:fuel),
                D.Port(:power_out, electricity, D.Output; variable=:electricity),
            ],
            process_model;
            parameters=(efficiency=0.5,),
        ),
    )

    boundary_model = D.LinearComponentModel(
        [D.VariableSpec(:fuel_import, D.InputFlow; lower_bound=0.0)],
        [D.ParameterSpec(:price)],
        D.LinearEquation[],
        [D.LinearObjectiveTerm(:fuel_import, D.ParameterCoefficient(:price))],
    )
    D.addBoundary(
        system,
        hub,
        D.Boundary(
            :fuel_supply,
            D.Port(:fuel_import, fuel, D.Output; variable=:fuel_import),
            D.Import,
            boundary_model;
            parameters=(price=2.0,),
        ),
    )
    D.addDemand(system, hub, D.Demand(:load, D.Port(:load, electricity, D.Input), 10.0))

    compiled = C.compile_linear(system)
    artifact = B.build_model(compiled, HiGHS.Optimizer)
    set_silent(artifact.model)
    B.solve!(artifact)

    @test termination_status(artifact.model) == JuMP.MOI.OPTIMAL
    @test B.objective_value(artifact) ≈ 40.0
    @test B.value(artifact, C.variable_id(compiled, process_id, :fuel, 1)) ≈ 20.0
    @test B.value(artifact, C.variable_id(compiled, process_id, :electricity, 1)) ≈ 10.0
end
