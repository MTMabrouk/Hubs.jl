@testset "Domain architecture and stable IDs" begin
    D = Hubs.Domain
    registry = D.Registry{:process}()
    original = push!(registry, :first)
    @test registry[original] === :first
    @test D.isvalid(registry, original)

    delete!(registry, original)
    @test !D.isvalid(registry, original)
    @test_throws InvalidStateException registry[original]

    replacement = push!(registry, :second)
    @test replacement.slot == original.slot
    @test replacement.generation == original.generation + 1
    @test registry[replacement] === :second

    system = D.HubSystem{Float32}(steps=4, time_step=0.5)
    electricity = D.addCarrier(system, D.Carrier(:electricity; unit=:MW))
    gas = D.addCarrier(system, D.Carrier(:gas; unit=:MW))
    hub = D.addHub(system, D.Hub(:factory))

    model = D.NoModel()
    process = D.Process(
        :boiler,
        [
            D.Port(:gas_in, gas, D.Input; variable=:gas),
            D.Port(:heat_out, electricity, D.Output; variable=:heat),
        ],
        model;
        parameters=(efficiency=0.9f0,),
    )
    process_id = D.addProcess(system, hub, process)

    storage = D.Storage(
        :battery,
        [D.Port(:electricity, electricity, D.Bidirectional; variable=:flow)],
        model;
        parameters=(capacity=10.0f0,),
    )
    storage_id = D.addStorage(system, hub, storage)

    @test system.processes[process_id].model isa D.NoModel
    @test system.storages[storage_id].parameters.capacity == 10.0f0
    @test system.hubs[hub].processes == [process_id]
    @test system.hubs[hub].storages == [storage_id]
    @test system.revision == 5
    @test !occursin("Float32", sprint(show, system.storages[storage_id]))

    old_id = process_id
    D.removeProcess(system, hub, process_id)
    new_id = D.addProcess(system, hub, process)
    @test new_id.slot == old_id.slot
    @test new_id.generation == old_id.generation + 1
end
