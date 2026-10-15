pushfirst!(LOAD_PATH, normpath(joinpath(@__DIR__, "..")))

using Hubs
using HiGHS
using JuMP

include("harness.jl")
using .HubsBenchmarkHarness

function benchmark_system(; hubs=8, steps=48)
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
        Hubs.addStorages(system, hub, "electricity", 20.0, 80.0; efficiency=0.95)
    end

    # Exercise network balance generation as well as local hub balances.
    for hub in 1:min(hubs, 4)
        Hubs.addPorts(system, hub, "electricity", :networkPorts, 0.0, 50.0)
    end

    Hubs.fillIndexunitIn(system)
    Hubs.updateCarriersNumbers(system)
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

samples = parse(Int, get(ENV, "HUBS_BENCHMARK_SAMPLES", "3"))
system = benchmark_system()
legacy = benchmark_pipeline(
    "legacy",
    system,
    compile_legacy,
    solve_legacy!,
    legacy_objective;
    samples,
)

print_comparison(legacy)
