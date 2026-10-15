@testset "Component model specifications" begin
    D = Hubs.Domain

    model = D.LinearComponentModel(
        [
            D.VariableSpec(:fuel, D.InputFlow; lower_bound=0.0, unit=:MW),
            D.VariableSpec(:electricity, D.OutputFlow; lower_bound=0.0, unit=:MW),
            D.VariableSpec(:capacity, D.Capacity; lower_bound=0.0, axes=()),
        ],
        [D.ParameterSpec(:efficiency), D.ParameterSpec(:variable_cost; default=0.0)],
        [
            D.LinearEquation(
                :conversion,
                [
                    D.LinearTerm(:electricity, 1.0),
                    D.LinearTerm(:fuel, D.ParameterCoefficient(:efficiency, -1.0)),
                ],
            ),
            D.LinearEquation(
                :capacity_limit,
                [D.LinearTerm(:electricity, 1.0), D.LinearTerm(:capacity, -1.0)];
                sense=D.LessThan,
            ),
        ],
        [D.LinearObjectiveTerm(:fuel, D.ParameterCoefficient(:variable_cost))],
    )

    system = D.HubSystem(steps=2)
    fuel = D.addCarrier(system, D.Carrier(:fuel))
    electricity = D.addCarrier(system, D.Carrier(:electricity))
    hub = D.addHub(system, D.Hub(:site))
    process = D.Process(
        :generator,
        [
            D.Port(:fuel_in, fuel, D.Input; variable=:fuel),
            D.Port(:electricity_out, electricity, D.Output; variable=:electricity),
        ],
        model;
        parameters=(efficiency=0.4, variable_cost=3.0),
    )

    process_id = D.addProcess(system, hub, process)
    @test system.processes[process_id].model === model
    @test length(D.variables(model)) == 3
    @test length(D.equations(model)) == 2
    @test D.coefficient_value(model.equations[1].terms[2].coefficient, process.parameters) == -0.4

    missing_parameter = D.Process(
        :invalid,
        process.ports,
        model;
        parameters=(variable_cost=3.0,),
    )
    @test_throws ArgumentError D.addProcess(system, hub, missing_parameter)

    bad_port = D.Process(
        :invalid_port,
        [D.Port(:bad, fuel, D.Input; variable=:not_declared)],
        model;
        parameters=(efficiency=0.4, variable_cost=3.0),
    )
    @test_throws ArgumentError D.addProcess(system, hub, bad_port)

    @test_throws ArgumentError D.LinearComponentModel(
        [D.VariableSpec(:x, D.Auxiliary)],
        D.ParameterSpec[],
        [D.LinearEquation(:bad, [D.LinearTerm(:y, 1.0)])],
    )

    unit_system = D.HubSystem()
    mass = D.addCarrier(unit_system, D.Carrier(:mass; unit=:kg))
    unit_hub = D.addHub(unit_system, D.Hub(:unit_test))
    mismatched = D.Process(
        :mismatched,
        [D.Port(:fuel, mass, D.Input; variable=:fuel)],
        model;
        parameters=(efficiency=0.4, variable_cost=3.0),
    )
    @test_throws ArgumentError D.addProcess(unit_system, unit_hub, mismatched)
end
