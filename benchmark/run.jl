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

function compile_candidate(system, library=Hubs.Compiler.ComponentLibrary())
    compiled = Hubs.Compiler.compile_linear(system; library)
    artifact = Hubs.Backends.build_model(compiled, HiGHS.Optimizer)
    set_silent(artifact.model)
    return artifact
end

solve_candidate!(artifact) = Hubs.Backends.solve!(artifact)
candidate_objective(artifact) = Hubs.Backends.objective_value(artifact)

samples = parse(Int, get(ENV, "HUBS_BENCHMARK_SAMPLES", "3"))
hubs = parse(Int, get(ENV, "HUBS_BENCHMARK_HUBS", "8"))
steps = parse(Int, get(ENV, "HUBS_BENCHMARK_STEPS", "48"))
println("benchmark size: hubs=$hubs, steps=$steps, samples=$samples")
legacy_system = benchmark_system_legacy(; hubs, steps)
candidate_system = benchmark_system_candidate(; hubs, steps)
candidate_library = Hubs.Compiler.ComponentLibrary()
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
    system -> compile_candidate(system, candidate_library),
    solve_candidate!,
    candidate_objective;
    samples,
)

isapprox(candidate.objective, legacy.objective; rtol=1.0e-9, atol=1.0e-7) ||
    error("candidate objective $(candidate.objective) differs from legacy objective $(legacy.objective)")
print_comparison(legacy, candidate)

legacy_matrices_stage = benchmark_stage(
    "legacy domain -> matrices",
    () -> Hubs.Matrices(legacy_system);
    samples,
)
legacy_matrices = Hubs.Matrices(legacy_system)
legacy_backend_stage = benchmark_stage(
    "legacy matrices -> JuMP",
    () -> begin
        model = Hubs.constructModel(legacy_matrices, HiGHS.Optimizer)
        set_silent(model)
        model
    end;
    samples,
)
candidate_ir_stage = benchmark_stage(
    "candidate domain -> cached IR",
    () -> Hubs.Compiler.compile_linear(candidate_system; library=candidate_library);
    samples,
)
candidate_ir = Hubs.Compiler.compile_linear(candidate_system; library=candidate_library)
candidate_backend_stage = benchmark_stage(
    "candidate IR -> JuMP",
    () -> begin
        artifact = Hubs.Backends.build_model(candidate_ir, HiGHS.Optimizer)
        set_silent(artifact.model)
        artifact
    end;
    samples,
)
print_stages(
    legacy_matrices_stage,
    legacy_backend_stage,
    candidate_ir_stage,
    candidate_backend_stage,
)

legacy_update = benchmark_operation(
    "legacy rebuild",
    () -> begin
        for hub in legacy_system.hubs
            hub.units[1].globalEfficiency = 0.55
            fill!(hub.purchasePorts[1].cost, 2.1)
        end
        artifact = compile_legacy(legacy_system)
        solve_legacy!(artifact)
        artifact
    end,
    legacy_objective;
    samples,
)

candidate_processes = first.(collect(candidate_system.processes))
candidate_boundaries = first.(collect(candidate_system.boundaries))
candidate_compiled = Hubs.Compiler.compile_linear(candidate_system; library=candidate_library)
candidate_artifact = Hubs.Backends.build_model(candidate_compiled, HiGHS.Optimizer)
set_silent(candidate_artifact.model)
candidate_update = benchmark_operation(
    "candidate in-place",
    () -> begin
        for id in candidate_processes
            Hubs.Domain.setParameters(candidate_system, id; efficiency=0.55)
        end
        for id in candidate_boundaries
            Hubs.Domain.setParameters(candidate_system, id; price=2.1)
        end
        Hubs.Backends.refreshParameters(candidate_artifact, candidate_system)
        solve_candidate!(candidate_artifact)
        candidate_artifact
    end,
    candidate_objective;
    samples,
)

isapprox(candidate_update.objective, legacy_update.objective; rtol=1.0e-9, atol=1.0e-7) ||
    error("updated candidate objective $(candidate_update.objective) differs from legacy objective $(legacy_update.objective)")
print_operation_comparison(legacy_update, candidate_update)
