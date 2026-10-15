pushfirst!(LOAD_PATH, normpath(joinpath(@__DIR__, "..")))

using Hubs
using HiGHS
using JuMP

include("harness.jl")
using .HubsBenchmarkHarness

function benchmark_system_legacy(; hubs=8, steps=48)
    system = Hubs.MultiCarrierNetwork()
    system.Nsteps = steps
    Hubs.addEnergyHubs(system, hubs)

    process = Hubs.ConversionUnitTemplate(
        "gas_to_electricity",
        ["gas"],
        ["electricity"],
        0.5,
        [1.0],
        [1.0];
        Pmax_in=[200.0],
        Pmax_out=[100.0],
        MOCost=0.1,
    )

    for hub in 1:hubs
        Hubs.addUnitFromTemplate(system, process, hub)
        Hubs.addPorts(system, hub, "gas", :purchasePorts, 0.0, 200.0, 2.0)
        demand = [20.0 + 5.0 * sin(2pi * (time - 1) / 24) for time in 1:steps]
        Hubs.addLoads(system, hub, "electricity", demand)
    end

    Hubs.fillIndexunitIn(system)
    Hubs.updateCarriersNumbers(system)
    return system
end

function benchmark_system_candidate(; hubs=8, steps=48)
    D = Hubs.Domain
    system = D.HubSystem(steps=steps)
    gas = D.addCarrier(system, D.Carrier(:gas))
    electricity = D.addCarrier(system, D.Carrier(:electricity))

    process_model = D.LinearComponentModel(
        [
            D.VariableSpec(:gas, D.InputFlow; lower_bound=0.0),
            D.VariableSpec(:electricity, D.OutputFlow; lower_bound=0.0),
            D.VariableSpec(:input_capacity, D.Capacity; lower_bound=0.0, axes=()),
            D.VariableSpec(:output_capacity, D.Capacity; lower_bound=0.0, axes=()),
        ],
        [D.ParameterSpec(:efficiency), D.ParameterSpec(:capacity_cost)],
        [
            D.LinearEquation(:conversion, [
                D.LinearTerm(:electricity, 1.0),
                D.LinearTerm(:gas, D.ParameterCoefficient(:efficiency, -1.0)),
            ]),
            D.LinearEquation(
                :input_capacity,
                [D.LinearTerm(:gas, 1.0), D.LinearTerm(:input_capacity, -1.0)];
                sense=D.LessThan,
            ),
            D.LinearEquation(
                :output_capacity,
                [D.LinearTerm(:electricity, 1.0), D.LinearTerm(:output_capacity, -1.0)];
                sense=D.LessThan,
            ),
        ],
        [
            D.LinearObjectiveTerm(:input_capacity, D.ParameterCoefficient(:capacity_cost)),
            D.LinearObjectiveTerm(:output_capacity, D.ParameterCoefficient(:capacity_cost)),
        ],
    )
    boundary_model = D.LinearComponentModel(
        [D.VariableSpec(:gas_import, D.InputFlow; lower_bound=0.0, upper_bound=200.0)],
        [D.ParameterSpec(:price)],
        D.LinearEquation[],
        [D.LinearObjectiveTerm(:gas_import, D.ParameterCoefficient(:price))],
    )

    for index in 1:hubs
        hub = D.addHub(system, D.Hub(Symbol(:hub_, index)))
        D.addProcess(
            system,
            hub,
            D.Process(
                :gas_to_electricity,
                [
                    D.Port(:gas_in, gas, D.Input; variable=:gas),
                    D.Port(:electricity_out, electricity, D.Output; variable=:electricity),
                ],
                process_model;
                parameters=(efficiency=0.5, capacity_cost=0.1),
            ),
        )
        D.addBoundary(
            system,
            hub,
            D.Boundary(
                :gas_supply,
                D.Port(:gas_import, gas, D.Output; variable=:gas_import),
                D.Import,
                boundary_model;
                parameters=(price=2.0,),
            ),
        )
        demand = [20.0 + 5.0 * sin(2pi * (time - 1) / 24) for time in 1:steps]
        D.addDemand(system, hub, D.Demand(:electricity_demand, D.Port(:load, electricity, D.Input), demand))
    end
    return system
end

function compile_legacy(system)
    matrices = Hubs.Matrices(system)
    model = Hubs.constructModel(matrices, HiGHS.Optimizer)
    set_silent(model)
    return (; matrices, model)
end

solve_legacy!(artifact) = optimize!(artifact.model)
legacy_objective(artifact) = objective_value(artifact.model)

function compile_candidate(system)
    compiled = Hubs.Compiler.compile_linear(system)
    artifact = Hubs.Backends.build_model(compiled, HiGHS.Optimizer)
    set_silent(artifact.model)
    return artifact
end

solve_candidate!(artifact) = Hubs.Backends.solve!(artifact)
candidate_objective(artifact) = Hubs.Backends.objective_value(artifact)

samples = parse(Int, get(ENV, "HUBS_BENCHMARK_SAMPLES", "3"))
legacy_system = benchmark_system_legacy()
candidate_system = benchmark_system_candidate()
legacy = benchmark_pipeline(
    "legacy",
    legacy_system,
    compile_legacy,
    solve_legacy!,
    legacy_objective;
    samples,
)
candidate = benchmark_pipeline(
    "candidate",
    candidate_system,
    compile_candidate,
    solve_candidate!,
    candidate_objective;
    samples,
)

isapprox(candidate.objective, legacy.objective; rtol=1.0e-9, atol=1.0e-7) ||
    error("candidate objective $(candidate.objective) differs from legacy objective $(legacy.objective)")
print_comparison(legacy, candidate)
