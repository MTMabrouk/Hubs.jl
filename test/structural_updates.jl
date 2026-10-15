using HiGHS
using JuMP

@testset "Structural recompilation" begin
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
    D.addProcess(system, hub, D.Process(
        :generator,
        [
            D.Port(:fuel, fuel, D.Input; variable=:fuel),
            D.Port(:electricity, electricity, D.Output; variable=:electricity),
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
    original_boundary = D.addBoundary(system, hub, D.Boundary(
        :fuel_supply,
        D.Port(:fuel_import, fuel, D.Output; variable=:fuel_import),
        D.Import,
        boundary_model;
        parameters=(price=2.0,),
    ))
    D.addDemand(system, hub, D.Demand(:load, D.Port(:load, electricity, D.Input), 10.0))

    compiled = C.compile_linear(system)
    artifact = B.build_model(compiled, HiGHS.Optimizer)
    set_silent(artifact.model)
    B.solve!(artifact)
    @test B.objective_value(artifact) ≈ 40.0

    cheap_boundary = D.addBoundary(system, hub, D.Boundary(
        :cheap_fuel,
        D.Port(:fuel_import, fuel, D.Output; variable=:fuel_import),
        D.Import,
        boundary_model;
        parameters=(price=1.0,),
    ))
    @test D.isstructural(D.changesSince(system, compiled.source_revision))
    @test_throws ArgumentError B.refreshParameters(artifact, system)

    recompiled = C.recompileStructure(compiled, system)
    @test recompiled.source_revision == system.revision
    @test length(recompiled.variables) == length(compiled.variables) + 1

    artifact = B.rebuildStructure(artifact, system)
    set_silent(artifact.model)
    B.solve!(artifact)
    @test B.objective_value(artifact) ≈ 20.0

    D.removeBoundary(system, hub, cheap_boundary)
    artifact = B.rebuildStructure(artifact, system)
    set_silent(artifact.model)
    B.solve!(artifact)
    @test B.objective_value(artifact) ≈ 40.0

    replacement_model = D.LinearComponentModel(
        [D.VariableSpec(:fuel_import, D.OutputFlow; lower_bound=0.0)],
        D.ParameterSpec[],
        D.LinearEquation[],
        [D.LinearObjectiveTerm(:fuel_import, 4.0)],
    )
    D.setModel(system, original_boundary, replacement_model; parameters=NamedTuple())
    artifact = B.rebuildStructure(artifact, system)
    set_silent(artifact.model)
    B.solve!(artifact)
    @test B.objective_value(artifact) ≈ 80.0
end

@testset "Symbolics template reuse after structural edits" begin
    D = Hubs.Domain
    C = Hubs.Compiler

    Hubs.Domain.Symbolics.@variables input_symbol output_symbol efficiency_symbol
    model = D.SymbolicComponentModel(
        [
            D.VariableSpec(:input, D.InputFlow; lower_bound=0.0),
            D.VariableSpec(:output, D.OutputFlow; lower_bound=0.0),
        ],
        [D.ParameterSpec(:efficiency)],
        (; input=input_symbol, output=output_symbol),
        (; efficiency=efficiency_symbol),
        [output_symbol - efficiency_symbol * input_symbol^2],
    )

    system = D.HubSystem(steps=1)
    material = D.addCarrier(system, D.Carrier(:material))
    product = D.addCarrier(system, D.Carrier(:product))
    hub = D.addHub(system, D.Hub(:plant))
    make_process(name) = D.Process(
        name,
        [
            D.Port(:input, material, D.Input; variable=:input),
            D.Port(:output, product, D.Output; variable=:output),
        ],
        model;
        parameters=(efficiency=0.5,),
    )
    D.addProcess(system, hub, make_process(:first))
    compiled = C.compile_hybrid(system)
    template = only(values(compiled.nonlinear_templates))

    D.addProcess(system, hub, make_process(:second))
    recompiled = C.recompileStructure(compiled, system)
    @test only(values(recompiled.nonlinear_templates)) === template
    @test length(recompiled.nonlinear_instances) == 2
    @test recompiled.linear.source_revision == system.revision
end
