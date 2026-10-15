@testset "Direct linear compiler" begin
    D = Hubs.Domain
    C = Hubs.Compiler

    system = D.HubSystem(steps=2)
    fuel = D.addCarrier(system, D.Carrier(:fuel))
    electricity = D.addCarrier(system, D.Carrier(:electricity))
    hub = D.addHub(system, D.Hub(:site))

    process_model = D.LinearComponentModel(
        [
            D.VariableSpec(:fuel, D.InputFlow; lower_bound=0.0, unit=:MW),
            D.VariableSpec(:electricity, D.OutputFlow; lower_bound=0.0, unit=:MW),
        ],
        [D.ParameterSpec(:efficiency)],
        [D.LinearEquation(
            :conversion,
            [
                D.LinearTerm(:electricity, 1.0),
                D.LinearTerm(:fuel, D.ParameterCoefficient(:efficiency, -1.0)),
            ],
        )],
    )
    process = D.Process(
        :generator,
        [
            D.Port(:fuel_in, fuel, D.Input; variable=:fuel),
            D.Port(:power_out, electricity, D.Output; variable=:electricity),
        ],
        process_model;
        parameters=(efficiency=0.5,),
    )
    process_id = D.addProcess(system, hub, process)

    boundary_model = D.LinearComponentModel(
        [D.VariableSpec(:fuel_import, D.InputFlow; lower_bound=0.0, upper_bound=100.0)],
        [D.ParameterSpec(:price)],
        D.LinearEquation[],
        [D.LinearObjectiveTerm(:fuel_import, D.ParameterCoefficient(:price))],
    )
    boundary = D.Boundary(
        :fuel_supply,
        D.Port(:fuel_import, fuel, D.Output; variable=:fuel_import),
        D.Import,
        boundary_model;
        parameters=(price=2.0,),
    )
    boundary_id = D.addBoundary(system, hub, boundary)
    D.addDemand(
        system,
        hub,
        D.Demand(:electricity_demand, D.Port(:load, electricity, D.Input), [10.0, 12.0]),
    )

    compiled = C.compile_linear(system)
    @test length(compiled.variables) == 6
    @test compiled.source_revision == system.revision
    @test length(compiled.objective.variable_ids) == 2
    @test compiled.objective.coefficients == [2.0, 2.0]

    process_block = only(block for block in compiled.blocks if block.owner == C.OwnerRef(process_id))
    @test length(process_block) == 2
    @test process_block.rowptr == [1, 3, 5]
    @test process_block.coefficients == [1.0, -0.5, 1.0, -0.5]

    hub_block = only(block for block in compiled.blocks if block.owner == C.OwnerRef(hub))
    @test length(hub_block) == 4
    @test hub_block.rhs == [0.0, 0.0, 10.0, 12.0]
    @test length(hub_block.variable_ids) == 6
    @test hub_block.rowptr == [1, 3, 5, 6, 7]

    @test C.variable_id(compiled, process_id, :fuel, 1) isa D.VariableId
    @test C.variable_id(compiled, boundary_id, :fuel_import, 2) isa D.VariableId
    @test compiled.variables[C.variable_id(compiled, process_id, :fuel, 1)].unit == :MW
end

@testset "Reusable linear component templates" begin
    D = Hubs.Domain
    C = Hubs.Compiler

    system = D.HubSystem(steps=3)
    material = D.addCarrier(system, D.Carrier(:material))
    hub = D.addHub(system, D.Hub(:plant))
    model = D.LinearComponentModel(
        [D.VariableSpec(:flow, D.OutputFlow; lower_bound=0.0)],
        [D.ParameterSpec(:yield)],
        [D.LinearEquation(
            :production,
            [D.LinearTerm(:flow, D.ParameterCoefficient(:yield))];
            rhs=1.0,
        )],
    )

    process_ids = [
        D.addProcess(system, hub, D.Process(
            Symbol(:source_, index),
            [D.Port(:output, material, D.Output; variable=:flow)],
            model;
            parameters=(yield=Float64(index),),
        ))
        for index in 1:3
    ]

    library = C.ComponentLibrary()
    C.prepareModel(library, model; steps=system.steps, numeric_type=Float64)
    prepared = C.templateStatistics(library)
    @test prepared.templates == 1
    @test prepared.misses == 1
    @test prepared.hits == 0

    compiled = C.compile_linear(system; library)
    after_first_compile = C.templateStatistics(library)
    @test after_first_compile.templates == 1
    @test after_first_compile.misses == 1
    @test after_first_compile.hits == 3
    @test compiled.component_library === library

    for (index, process_id) in enumerate(process_ids)
        block = only(block for block in compiled.blocks if block.owner == C.OwnerRef(process_id))
        @test block.coefficients == fill(Float64(index), system.steps)
    end

    compiled_again = C.compile_linear(system; library)
    after_second_compile = C.templateStatistics(library)
    @test after_second_compile.templates == 1
    @test after_second_compile.misses == 1
    @test after_second_compile.hits == 6
    @test compiled_again.objective.coefficients == compiled.objective.coefficients
end

@testset "Float32 compiler storage and native indices" begin
    D = Hubs.Domain
    C = Hubs.Compiler

    system = D.HubSystem{Float32}(steps=1)
    material = D.addCarrier(system, D.Carrier(:material; unit=:kg))
    hub = D.addHub(system, D.Hub(:plant))
    model = D.LinearComponentModel(
        [D.VariableSpec(:flow, D.OutputFlow; lower_bound=0.0f0, unit=:kg)],
        D.ParameterSpec[],
        [D.LinearEquation(:fixed, [D.LinearTerm(:flow, 1.0f0)]; rhs=2.0f0)],
    )
    process = D.addProcess(system, hub, D.Process(
        :source,
        [D.Port(:flow, material, D.Output; variable=:flow)],
        model,
    ))

    compiled = C.compile_linear(system)
    block = only(block for block in compiled.blocks if block.owner == C.OwnerRef(process))
    @test eltype(block.coefficients) === Float32
    @test eltype(block.rhs) === Float32
    @test C.variable_id(compiled, process, :flow, 1).slot isa Int
end
