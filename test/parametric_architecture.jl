@testset "Parametric numeric architecture" begin
    default_network = Hubs.MultiCarrierNetwork()
    @test default_network isa Hubs.MultiCarrierNetwork{Float64}

    network = Hubs.MultiCarrierNetwork{Float32}()
    network.Nsteps = 3
    Hubs.addEnergyHubs(network, Int32(2))

    template = Hubs.ConversionUnitTemplate{Float32}(
        "Source",
        ["Input"],
        ["Electricity"],
        1,
        [1],
        [1];
        Pmax_in=[10.0],
        Pmax_out=Float32[10],
    )
    Hubs.addUnitFromTemplate(network, template, Int32[1, 2])

    Hubs.addLoads(network, 1, "Electricity", 2)
    Hubs.addLoads(network, Int32[1, 2], "Electricity", Float64[1, 2, 3])
    Hubs.addPorts(network, 1, "Electricity", :purchasePorts, 0, 10, 0.25)
    Hubs.addStorages(network, 1, "Electricity", 4, 8; efficiency=0.9)

    @test network.Nsteps isa Int
    @test network.energy_carriers[1].index isa Int
    @test eltype(network.hubs[1].loads[1].P) === Float32
    @test network.hubs[1].loads[1].P == Float32[2, 2, 2]
    @test network.hubs[2].loads[1].P == Float32[1, 2, 3]
    @test eltype(network.hubs[1].purchasePorts[1].Pmax) === Float32
    @test network.hubs[1].storages[1] isa Hubs.Storage{Float32}
    @test_throws DimensionMismatch Hubs.addLoads(
        network,
        1,
        "Electricity",
        Float32[1, 2],
    )

    matrices = Hubs.Matrices(network)
    @test matrices isa Hubs.Matrices{Float32}
    @test eltype(matrices.loadsP) === Float32

    storage = Hubs.Storage{Float32}(1, 2, 3)
    displayed = sprint(show, storage)
    @test startswith(displayed, "Storage(")
    @test !occursin("{Float32}", displayed)
    @test typeof(storage) === Hubs.Storage{Float32}
end
