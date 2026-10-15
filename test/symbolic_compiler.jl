@testset "Symbolic nonlinear compiler" begin
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

    system = D.HubSystem(steps=2)
    fuel = D.addCarrier(system, D.Carrier(:fuel))
    power = D.addCarrier(system, D.Carrier(:power))
    heat = D.addCarrier(system, D.Carrier(:heat))
    hub = D.addHub(system, D.Hub(:site))
    ports = [
        D.Port(:fuel_in, fuel, D.Input; variable=:fuel),
        D.Port(:power_out, power, D.Output; variable=:power),
        D.Port(:heat_out, heat, D.Output; variable=:heat),
    ]
    first_process = D.addProcess(
        system,
        hub,
        D.Process(:first, ports, model; parameters=(efficiency=0.5, heat_ratio=0.25)),
    )
    D.addProcess(
        system,
        hub,
        D.Process(:second, ports, model; parameters=(efficiency=0.5, heat_ratio=0.25)),
    )

    compiled = C.compile_hybrid(system)
    @test length(compiled.nonlinear_templates) == 1
    @test length(compiled.nonlinear_instances) == 4
    @test length(compiled.linear.blocks) == 3

    template = only(values(compiled.nonlinear_templates))
    @test C.evaluate_residuals(template, [2.0, 3.0, 1.0], [0.5, 0.25]) == [1.0]
    @test C.evaluate_jacobian(template, [2.0, 3.0, 1.0], [0.5, 0.25]) == [-2.0 1.0 0.0]
    @test Hubs.Compiler.nnz(template.jacobian_sparsity) == 2

    affine_block = only(
        block for block in compiled.linear.blocks
        if block.owner == C.OwnerRef(first_process) && length(block) > 0
    )
    @test affine_block.coefficients == [-0.25, 1.0, -0.25, 1.0]
    @test affine_block.rhs == [0.0, 0.0]
end
