module Hubs

using SparseArrays
using JuMP
using Gurobi

IndexType = Int32
R = Float64
convert(::Type{R}, x) = R(x)
convert(::Type{IndexType}, x) = IndexType(x)
const zero = R(0.0)
const one = R(1.0)
const Izero = IndexType(0)
const Ione = IndexType(1)
const Imax = typemax(IndexType)
const Nu_max = IndexType(1000)
const Ni_max = IndexType(10)
const Nh_max = Imax ÷ Nu_max * Ni_max

function decomposeIndex(index::IndexType)
    hubIndex = (index ÷ (Nu_max * Ni_max)) + Ione
    unitIndex = ((index % (Nu_max * Ni_max)) ÷ Ni_max) + Ione
    inletIndex = ((index % (Nu_max * Ni_max)) % Ni_max)
    return hubIndex, unitIndex, inletIndex
end

composeIndex(hubIndex::IndexType, unitIndex::IndexType, inletIndex::IndexType) = (hubIndex - Ione) * Nu_max * Ni_max + (unitIndex - Ione) * Ni_max + inletIndex

mutable struct EnergyCarrier
    name::String
    index::IndexType                             # Num du vecteur ener dans le réseau
    #Exergy::R                                    # Exergy to be added                  
    index_unit_in::Vector{Vector{IndexType}}     # present in input of unit/entry
    index_unit_out::Vector{Vector{IndexType}}    # present in output unit/entry
    index_hub_in::Vector{IndexType}              # hubs in which the carrier is present as an input
    index_hub_out::Vector{IndexType}             # hubs in which the carrier is present as an output
    inCosts::Vector{R}                           # purshase costs in the hubs
    outCosts::Vector{R}                          # export costs in the hubs
    networkLossFactor::R
    EnergyCarrier(name::String) = new(name, Izero, Vector{Vector{IndexType}}(undef, 0), Vector{Vector{IndexType}}(undef, 0), Vector{IndexType}(undef, 0), Vector{IndexType}(undef, 0), Vector{R}(undef, 0), Vector{R}(undef, 0), R(0.05))
end

mutable struct Network
    carrier::EnergyCarrier
    index::IndexType                             # Num du vecteur ener dans le réseau
    CapitalCost::Vector{R}
    MOCost::Vector{R}
    DevelopementCost::R
    HubIndex::Vector{Int64}
    Network(carrier::EnergyCarrier, CapitalCost::Vector{R}, MOCost::Vector{R}, DevelopementCost::R) = new(carrier, Izero, CapitalCost, MOCost, DevelopementCost, Vector{Int64}(undef, 0))
    Network(carrier::EnergyCarrier, CapitalCost::Vector{R}, MOCost::Vector{R}) = new(carrier, Izero, CapitalCost, MOCost, Izero, Vector{Int64}(undef, 0))
    Network(carrier::EnergyCarrier) = new(carrier, Izero, [Izero], [Izero], Izero, Vector{Int64}(undef, 0))
    Network(carrier::EnergyCarrier, HubIndex::Vector{Int64}) = new(carrier, Izero, [Izero], [Izero], Izero, HubIndex)

end

mutable struct ConversionUnit
    technology::String
    carriersIndexes_in::Vector{IndexType}
    carriersIndexes_out::Vector{IndexType}
    globalEfficiency::R
    proportions_input::Vector{R}
    proportions_output::Vector{R}
    Pmax_in::Vector{R}
    Pmax_out::Vector{R}
    CapitalCost::R
    MOCost::R
end

struct ConversionUnitTemplate
    technology::String
    carriers_input::Vector{String}
    carriers_output::Vector{String}
    globalEfficiency::R
    proportions_input::Vector{R}
    proportions_output::Vector{R}
    Pmax_in::Vector{R}
    Pmax_out::Vector{R}
    CapitalCost::R
    MOCost::R
end
ConversionUnitTemplate(technology::String, carriers_input::Vector{String}, carriers_output::Vector{String}, globalEfficiency::R=1.0, proportions_input::Vector{R}=[0.0], proportions_output::Vector{R}=[0.0]; Pmax_in::Vector{R}=[0.0], Pmax_out::Vector{R}=[0.0], CapitalCost::R=0.0, MOCost::R=0.0) where {R<:Union{Real,Integer}} = ConversionUnitTemplate(technology, carriers_input, carriers_output, globalEfficiency, proportions_input, proportions_output, Pmax_in, Pmax_out, CapitalCost, MOCost)

mutable struct PowerPort
    carrierIndex::IndexType
    Pmin::Vector{R}
    Pmax::Vector{R}
    cost::Vector{R}
    InvestmentParameterMax::R
    InvestmentCost::R
    OperatingCost::R
    P::Vector{R}
    PowerPort(carrier::EnergyCarrier, Pmin::R, Pmax::R, cost::R=zero, InvestmentParameterMax::R=zero, InvestmentCost::R=zero, OperatingCost::R=zero) = new(carrier.index, [Pmin], [Pmax], [cost], InvestmentParameterMax, InvestmentCost, OperatingCost, Vector{R}(undef, 0))
    PowerPort(carrier::EnergyCarrier, Pmin::Vector{R}, Pmax::Vector{R}, cost::R=zero, InvestmentParameterMax::R=zero, InvestmentCost::R=zero, OperatingCost::R=zero) = new(carrier.index, Pmin, Pmax, [cost], InvestmentParameterMax, InvestmentCost, OperatingCost, Vector{R}(undef, 0))
    PowerPort(carrier::EnergyCarrier, Pmin::Vector{R}, Pmax::Vector{R}, cost::Vector{R}, InvestmentParameterMax::R=zero, InvestmentCost::R=zero, OperatingCost::R=zero) = new(carrier.index, Pmin, Pmax, cost, InvestmentParameterMax, InvestmentCost, OperatingCost, Vector{R}(undef, 0))
    PowerPort(index::IndexType, Pmin::R, Pmax::R, cost::R=zero, InvestmentParameterMax::R=zero, InvestmentCost::R=zero, OperatingCost::R=zero) = new(index, [Pmin], [Pmax], [cost], InvestmentParameterMax, InvestmentCost, OperatingCost, Vector{R}(undef, 0))
    PowerPort(index::IndexType, Pmin::Vector{R}, Pmax::Vector{R}, cost::R=zero, InvestmentParameterMax::R=zero, InvestmentCost::R=zero, OperatingCost::R=zero) = new(index, Pmin, Pmax, [cost], InvestmentParameterMax, InvestmentCost, OperatingCost, Vector{R}(undef, 0))
    PowerPort(index::IndexType, Pmin::Vector{R}, Pmax::Vector{R}, cost::Vector{R}, InvestmentParameterMax::R=zero, InvestmentCost::R=zero, OperatingCost::R=zero) = new(index, Pmin, Pmax, cost, InvestmentParameterMax, InvestmentCost, OperatingCost, Vector{R}(undef, 0))
end

#=
mutable struct PowerPort
    carrierIndex::IndexType
    Pmin::Vector{R}
    Pmax::Vector{R}
    cost::Vector{R}
    P::Vector{R}
    PowerPort(carrier::EnergyCarrier, Pmin::R, Pmax::R, cost::R=zero) = new(carrier.index, [Pmin], [Pmax], [cost], Vector{R}(undef, 0))
    PowerPort(carrier::EnergyCarrier, Pmin::Vector{R}, Pmax::Vector{R}, cost::R=zero) = new(carrier.index, Pmin, Pmax, [cost], Vector{R}(undef, 0))
    PowerPort(carrier::EnergyCarrier, Pmin::Vector{R}, Pmax::Vector{R}, cost::Vector{R}) = new(carrier.index, Pmin, Pmax, cost, Vector{R}(undef, 0))
    PowerPort(index::IndexType, Pmin::R, Pmax::R, cost::R=zero) = new(index, [Pmin], [Pmax], [cost], Vector{R}(undef, 0))
    PowerPort(index::IndexType, Pmin::Vector{R}, Pmax::Vector{R}, cost::R=zero) = new(index, Pmin, Pmax, [cost], Vector{R}(undef, 0))
    PowerPort(index::IndexType, Pmin::Vector{R}, Pmax::Vector{R}, cost::Vector{R}) = new(index, Pmin, Pmax, cost, Vector{R}(undef, 0))
end
=#
mutable struct Storage
    carrierIndex::IndexType
    Pmax::R
    Emax::R
    E0::R
    efficiency::R
    #E::Vector{R}
    CapitalCost::R
    MOCost::R
    Storage(carrier::EnergyCarrier, Pmax::R, Emax::R=zero, E0::R=zero, efficiency::R=one, CapitalCost::R=zero, MOCost::R=zero) = new(carrier.index, Pmax, Emax, E0, efficiency, CapitalCost, MOCost)
    Storage(index::IndexType, Pmax::R, Emax::R=zero, E0::R=zero, efficiency::R=one, CapitalCost::R=zero, MOCost::R=zero) = new(index, Pmax, Emax, E0, efficiency, CapitalCost, MOCost)
end

mutable struct Load
    carrierIndex::IndexType
    P::Vector{R}
    Load(carrier::EnergyCarrier) = new(carrier.index, Vector{R}(undef, 0))
    Load(index::IndexType, P::Vector{R}) = new(index, P)
    Load(index::IndexType) = new(index, Vector{R}(undef, 0))
end



mutable struct EnergyHub
    units::Vector{ConversionUnit}               # energy conversion units
    purchasePorts::Vector{PowerPort}
    sellPorts::Vector{PowerPort}
    returnPorts::Vector{PowerPort}
    networkPorts::Vector{PowerPort}
    storagePorts::Vector{PowerPort}
    storageCapacities::Vector{R}
    storages::Vector{Storage}
    loads::Vector{Load}
    Ncarriers_in::IndexType
    Ncarriers_out::IndexType

    function EnergyHub()
        Conversion_matrix = Vector{ConversionUnit}(undef, 0)
        purchasePorts = Vector{PowerPort}(undef, 0)
        sellPorts = Vector{PowerPort}(undef, 0)
        returnPorts = Vector{PowerPort}(undef, 0)
        networkPorts = Vector{PowerPort}(undef, 0)
        storagePorts = Vector{PowerPort}(undef, 0)
        storageCapacities = Vector{R}(undef, 0)
        storages = Vector{Storage}(undef, 0)
        loads = Vector{Load}(undef, 0)
        Ncarriers_in = Izero
        Ncarriers_out = Izero
        return new(Conversion_matrix, purchasePorts, sellPorts, returnPorts, networkPorts, storagePorts, storageCapacities, storages, loads, Ncarriers_in, Ncarriers_out)
    end
end

mutable struct MultiCarrierNetwork
    Pmax::R
    Nsteps::IndexType
    timeStep::R
    Nunits::IndexType
    Ninlets::IndexType
    Noutlets::IndexType
    energy_carriers::Vector{EnergyCarrier}
    hubs::Vector{EnergyHub}
    networks::Vector{Network}
    MultiCarrierNetwork() = new(zero, Ione, one, Izero, Izero, Izero, Vector{EnergyCarrier}(undef, 0), Vector{EnergyHub}(undef, 0), Vector{Network}(undef, 0))
end

mutable struct UnitVariableContainer
    in::Array{VariableRef}
    out::Array{VariableRef}
    tin::Array{VariableRef}
    tout::Array{VariableRef}
    # UnitVariableContainer() = new(Array{VariableRef}(undef,0), Array{VariableRef}(undef,0))
end

mutable struct HubVariableContainer
    units::Array{UnitVariableContainer}
    P_purchased::Array{VariableRef}             # power purchased
    P_imported::Array{VariableRef}              # power imported from network for energy conversion units
    P_produced::Array{VariableRef}              # power produced by energy conversion units
    P_sold::Array{VariableRef}                  # power sold to the external grid
    P_stored::Array{VariableRef}                # power stored in storage units
    P_interface::Array{VariableRef}             # Extra power inported or exported to the betwork
    HubVariableContainer() = new(Array{UnitVariableContainer}(undef, 0), Array{VariableRef}(undef, 0), Array{VariableRef}(undef, 0), Array{VariableRef}(undef, 0), Array{VariableRef}(undef, 0), Array{VariableRef}(undef, 0), Array{VariableRef}(undef, 0))
end

mutable struct GlobalVariableContainer
    hubs::Array{HubVariableContainer}
    GlobalVariableContainer() = new(Array{HubVariableContainer}(undef, 0))
end

struct OptimResults
    Xi::Matrix{R}
    Xo::Matrix{R}
    Xui::Matrix{R}
    Xuo::Matrix{R}
    Xhi::Matrix{R}
    Xho::Matrix{R}
    Xp::Matrix{R}
    Xs::Matrix{R}
    Xst_charge::Matrix{R}
    Xst_discharge::Matrix{R}
    XEst::Matrix{R}
    Xn::Matrix{R}
    Xni::Matrix{R}
end

struct Matrices
    Nunits::IndexType
    Ninlets::IndexType
    Noutlets::IndexType
    Nsteps::IndexType
    timeStep::R

    #= 
    inletsPerCarrier::SparseMatrixCSC{IndexType, IndexType}
    outletsPerCarrier::SparseMatrixCSC{IndexType, IndexType} 
    =#

    inletsPerUnit::SparseMatrixCSC{IndexType,IndexType}
    outletsPerUnit::SparseMatrixCSC{IndexType,IndexType}
    hubsPerCarrierIn::SparseMatrixCSC{IndexType,IndexType}
    hubsPerCarrierOut::SparseMatrixCSC{IndexType,IndexType}
    carrierInletBalance::SparseMatrixCSC{IndexType,IndexType}
    carrierOutletBalance::SparseMatrixCSC{IndexType,IndexType}
    purchasePerCarrier::SparseMatrixCSC{IndexType,IndexType}
    sellPerCarrier::SparseMatrixCSC{IndexType,IndexType}
    loadPerCarrier::SparseMatrixCSC{IndexType,IndexType}
    storagePerCarrier::SparseMatrixCSC{IndexType,IndexType}
    networkPortsPerCarrier::SparseMatrixCSC{IndexType,IndexType}
    returnPerCarrier::SparseMatrixCSC{IndexType,IndexType}
    proportionsIn::Vector{R}
    proportionsOut::Vector{R}
    unitsEfficiencies::Vector{R}
    unitsCapitalCosts::Vector{R}
    unitsMOCosts::Vector{R}
    purchaseCosts::Vector{Vector{R}}
    purchasePmax::Vector{Vector{R}}
    purchasePmin::Vector{Vector{R}}
    purchaseInvestmentParameterMax::Vector{R}
    purchaseInvestmentCost::Vector{R}
    purchaseOperatingCost::Vector{R}
    sellCosts::Vector{Vector{R}}
    sellPmax::Vector{Vector{R}}
    storagePmax::Vector{R}
    storageEmax::Vector{R}
    storageE0::Vector{R}
    storageEfficiencies::Vector{R}
    storageCapitalCosts::Vector{R}
    storageMOCosts::Vector{R}
    networkCapitalCosts::Vector{Vector{R}}
    networkMOCosts::Vector{Vector{R}}
    networkDevelopementCosts::Vector{R}
    networkPortsPmax::Vector{Vector{R}}
    networkPortsPmin::Vector{Vector{R}}
    returnPmax::Vector{Vector{R}}
    networkPortsCosts::Vector{Vector{R}}
    loadsP::Matrix{R}
    Pmax_in::Vector{R}
    Pmax_out::Vector{R}
    networkLossesFactors::Vector{R}

    function Matrices(MCN::MultiCarrierNetwork)
        Nunits = MCN.Nunits
        Ninlets = MCN.Ninlets
        Noutlets = MCN.Noutlets
        Nsteps = MCN.Nsteps
        timeStep = MCN.timeStep

        # inletsPerCarrier = fillInletsMatrix(MCN)
        inletsPerUnit, proportionsIn, Pmax_in = inletsPerUnitMatrix(MCN)
        # outletsPerCarrier = fillOutletsMatrix(MCN)
        outletsPerUnit, proportionsOut, Pmax_out = outletsPerUnitMatrix(MCN)
        hubsPerCarrierIn, carrierInletBalance = fillHubsInletsPerCarrierMatrix(MCN)
        hubsPerCarrierOut, carrierOutletBalance = fillHubsOutletsPerCarrierMatrix(MCN)
        purchasePerCarrier = fillPortsPerCarrier(MCN, :purchasePorts)
        sellPerCarrier = fillPortsPerCarrier(MCN, :sellPorts)
        loadPerCarrier = fillPortsPerCarrier(MCN, :loads)
        storagePerCarrier = fillPortsPerCarrier(MCN, :storages)
        networkPortsPerCarrier = fillPortsPerCarrier(MCN, :networkPorts)
        returnPerCarrier = fillPortsPerCarrier(MCN, :returnPorts)
        purchaseCosts = fillPortsParametersArray(MCN, :purchasePorts, :cost)
        purchasePmax = fillPortsParametersArray(MCN, :purchasePorts, :Pmax)
        purchasePmin = fillPortsParametersArray(MCN, :purchasePorts, :Pmin)
        purchaseInvestmentParameterMax = fillPortsParametersArray(MCN, :purchasePorts, :InvestmentParameterMax, 2)
        purchaseInvestmentCost = fillPortsParametersArray(MCN, :purchasePorts, :InvestmentCost, 2)
        purchaseOperatingCost = fillPortsParametersArray(MCN, :purchasePorts, :OperatingCost, 2)
        sellCosts = fillPortsParametersArray(MCN, :sellPorts, :cost)
        sellPmax = fillPortsParametersArray(MCN, :sellPorts, :Pmax)
        storagePmax = fillPortsParametersArray(MCN, :storages, :Pmax, 2)
        storageEmax = fillPortsParametersArray(MCN, :storages, :Emax, 2)
        storageE0 = fillPortsParametersArray(MCN, :storages, :E0, 2)
        storageEfficiencies = fillPortsParametersArray(MCN, :storages, :efficiency, 2)
        storageCapitalCosts = fillPortsParametersArray(MCN, :storages, :CapitalCost, 2)
        storageMOCosts = fillPortsParametersArray(MCN, :storages, :MOCost, 2)
        networkCapitalCosts = fillNetworksParametersArray(MCN, :CapitalCost)
        networkMOCosts = fillNetworksParametersArray(MCN, :MOCost)
        networkDevelopementCosts = fillNetworksParametersArray(MCN, :DevelopementCost, 2)
        unitsCapitalCosts = fillPortsParametersArray(MCN, :units, :CapitalCost, 2)
        unitsMOCosts = fillPortsParametersArray(MCN, :units, :MOCost, 2)
        unitsEfficiencies = fillPortsParametersArray(MCN, :units, :globalEfficiency, 2)
        networkPortsPmax = fillPortsParametersArray(MCN, :networkPorts, :Pmax)
        networkPortsPmin = fillPortsParametersArray(MCN, :networkPorts, :Pmin)
        returnPmax = fillPortsParametersArray(MCN, :returnPorts, :Pmax)
        networkPortsCosts = fillPortsParametersArray(MCN, :networkPorts, :cost)
        loadsP = fillLoadsPArray(MCN)
        networkLossesFactors = fillNetworkLossesFactors(MCN)
        return new(Nunits, Ninlets, Noutlets, Nsteps, timeStep, inletsPerUnit,
            outletsPerUnit, hubsPerCarrierIn, hubsPerCarrierOut, carrierInletBalance,
            carrierOutletBalance, purchasePerCarrier, sellPerCarrier, loadPerCarrier,
            storagePerCarrier, networkPortsPerCarrier, returnPerCarrier, proportionsIn, proportionsOut,
            unitsEfficiencies, unitsCapitalCosts, unitsMOCosts, purchaseCosts, purchasePmax, purchasePmin, purchaseInvestmentParameterMax, purchaseInvestmentCost, purchaseOperatingCost, sellCosts, sellPmax,
            storagePmax, storageEmax, storageE0, storageEfficiencies, storageCapitalCosts, storageMOCosts, networkCapitalCosts, networkMOCosts, networkDevelopementCosts,
            networkPortsPmax, networkPortsPmin, returnPmax, networkPortsCosts, loadsP, Pmax_in, Pmax_out, networkLossesFactors)
    end
end

# functions
function inletsPerUnitMatrix(MCN::MultiCarrierNetwork)
    inletsVarIndexes = Array{IndexType}(undef, MCN.Ninlets)
    inletsIndexes = Array{IndexType}(undef, MCN.Ninlets)
    unitIndexes = Array{IndexType}(undef, MCN.Ninlets)
    proportions = Array{R}(undef, MCN.Ninlets)
    Pmax_in = Array{R}(undef, MCN.Ninlets)
    inletsVarIndex = Izero
    unitVarIndex = Izero

    for (hubIndex, hub) in enumerate(MCN.hubs)
        for (unitIndex, unit) in enumerate(hub.units)
            unitVarIndex = unitVarIndex + Ione
            for (inletIndex, inletCarrierIndex) in enumerate(unit.carriersIndexes_in)
                inletsVarIndex = inletsVarIndex + Ione
                proportions[inletsVarIndex] = unit.proportions_input[inletIndex]
                inletIndex <= length(unit.Pmax_in) ? Pmax_in[inletsVarIndex] = unit.Pmax_in[inletIndex] : Pmax_in[inletsVarIndex] = 0.0
                inletsIndexes[inletsVarIndex] = IndexType(inletIndex)
                inletsVarIndexes[inletsVarIndex] = IndexType(inletsVarIndex)
                unitIndexes[inletsVarIndex] = IndexType(unitVarIndex)
            end
        end
    end

    return sparse(inletsIndexes, unitIndexes, inletsVarIndexes), proportions, Pmax_in
end

function outletsPerUnitMatrix(MCN::MultiCarrierNetwork)
    outletsVarIndexes = Array{IndexType}(undef, MCN.Noutlets)
    outletsIndexes = Array{IndexType}(undef, MCN.Noutlets)
    unitIndexes = Array{IndexType}(undef, MCN.Noutlets)
    proportions = Array{R}(undef, MCN.Noutlets)
    Pmax_out = Array{R}(undef, MCN.Noutlets)
    outletsVarIndex = Izero
    unitVarIndex = Izero
    for (hubIndex, hub) in enumerate(MCN.hubs)
        for (unitIndex, unit) in enumerate(hub.units)
            unitVarIndex = unitVarIndex + Ione
            for (outletIndex, outletCarrierIndex) in enumerate(unit.carriersIndexes_out)
                outletsVarIndex = outletsVarIndex + Ione
                proportions[outletsVarIndex] = unit.proportions_output[outletIndex]
                outletIndex <= length(unit.Pmax_out) ? Pmax_out[outletsVarIndex] = unit.Pmax_out[outletIndex] : Pmax_out[outletsVarIndex] = 0.0
                outletsIndexes[outletsVarIndex] = IndexType(outletIndex)
                outletsVarIndexes[outletsVarIndex] = IndexType(outletsVarIndex)
                unitIndexes[outletsVarIndex] = IndexType(unitVarIndex)
            end
        end
    end

    return sparse(outletsIndexes, unitIndexes, outletsVarIndexes), proportions, Pmax_out
end

function fillInletsMatrix(MCN::MultiCarrierNetwork)
    inletsNumbers = Array{IndexType}(undef, MCN.Ninlets)
    inletsIndexes = Array{IndexType}(undef, MCN.Ninlets)
    inletsCarriers = Array{IndexType}(undef, MCN.Ninlets)
    inletNumber = Izero

    for (hubIndex, hub) in enumerate(MCN.hubs)
        for (unitIndex, unit) in enumerate(hub.units)
            for (inletIndex, inletCarrierIndex) in enumerate(unit.carriersIndexes_in)
                inletNumber = inletNumber + Ione
                inletsNumbers[inletNumber] = IndexType(inletNumber)
                inletsIndexes[inletNumber] = composeIndex(IndexType(hubIndex), IndexType(unitIndex), IndexType(inletIndex))
                inletsCarriers[inletNumber] = IndexType(inletCarrierIndex)
            end
        end
    end

    return sparse(inletsIndexes, inletsCarriers, inletsNumbers)
end

function fillOutletsMatrix(MCN::MultiCarrierNetwork)
    outletsNumbers = Array{IndexType}(undef, MCN.Noutlets)
    outletsIndexes = Array{IndexType}(undef, MCN.Noutlets)
    outletsCarriers = Array{IndexType}(undef, MCN.Noutlets)
    outletNumber = Izero

    for (hubIndex, hub) in enumerate(MCN.hubs)
        for (unitIndex, unit) in enumerate(hub.units)
            for (outletIndex, outletCarrierIndex) in enumerate(unit.carriersIndexes_out)
                outletNumber = outletNumber + Ione
                outletsNumbers[outletNumber] = IndexType(outletNumber)
                outletsIndexes[outletNumber] = composeIndex(IndexType(hubIndex), IndexType(unitIndex), IndexType(outletIndex))
                outletsCarriers[outletNumber] = IndexType(outletCarrierIndex)
            end
        end
    end

    return sparse(outletsIndexes, outletsCarriers, outletsNumbers)
end

# This function generates hubsPerCarrierMatrix which indicates what hubs contain each carrier (rows: hub's n° / cols: carrier's n°)
# hubsPerCarrierMatrix is filled with hub's inlet variable numbers and can be applied to units inlets and units outlets

# This function generates also carrierInletBalance which indicates what inlets need to be summed to calculate the inlet at the hub level (rows: inlets variable n° / cols: hubs inlets variable n°)
# carrierInletBalance is filled with ones and can be applied to units inlets and unit outlets outlets

function fillHubsPerCarrierMatrix(inletsMatrix::SparseMatrixCSC{IndexType,IndexType})
    Nhubs = (inletsMatrix.m ÷ (Nu_max * Ni_max)) + Ione
    Ninlets = length(inletsMatrix.nzval)
    Ncarriers = inletsMatrix.n
    rows = rowvals(inletsMatrix)
    vals = nonzeros(inletsMatrix)
    # matrices for hubsPerCarrierMatrix
    variableNumbers = Array{IndexType}(undef, 0)
    hubIndexes = Array{IndexType}(undef, 0)
    carriersIndexes = Array{IndexType}(undef, 0)
    # matrices for carrierInletBalanceMatrix
    Ones = Array{IndexType}(undef, Ninlets)
    varInletsIndexes = Array{IndexType}(undef, Ninlets)
    variableNumbers2 = Array{IndexType}(undef, Ninlets)

    variableNumber = Izero

    for carrierIndex = 1:Ncarriers
        hubIndex_old = Izero
        for i in nzrange(inletsMatrix, carrierIndex)  # à améliorer pour ne pas parcourir toute la matrice (ou pas!)
            inletIndex = rows[i]
            varInletIndex = vals[i]
            hubIndex, unitIndex, inletIndex = decomposeIndex(inletIndex)
            if hubIndex > hubIndex_old
                hubIndex_old = hubIndex
                variableNumber = variableNumber + Ione
                push!(variableNumbers, variableNumber)
                push!(hubIndexes, hubIndex)
                push!(carriersIndexes, carrierIndex)
            end
            Ones[i] = Ione
            varInletsIndexes[i] = varInletIndex
            variableNumbers2[i] = variableNumber
        end
    end
    return sparse(hubIndexes, carriersIndexes, variableNumbers), sparse(varInletsIndexes, variableNumbers2, Ones)
end

# This function generates hubsPerCarrierMatrixIn  (for Inlets only) which indicates what hubs contain each carrier (rows: hub's n° / cols: carrier's n°)
# hubsPerCarrierMatrix is filled with hub's inlet variable numbers (same as the previous one but has network input)

# This function generates also carrierInletBalanceIn which indicates what inlets need to be summed to calculate the inlet at the hub level (rows: inlets variable n° / cols: hubs inlets variable n°)
# carrierInletBalance is filled with ones

function fillHubsInletsPerCarrierMatrix(MCN::MultiCarrierNetwork)
    inletsMatrix = fillInletsMatrix(MCN)
    Nhubs = (inletsMatrix.m ÷ (Nu_max * Ni_max)) + Ione
    Ninlets = length(inletsMatrix.nzval)
    Ncarriers = inletsMatrix.n
    rows = rowvals(inletsMatrix)
    vals = nonzeros(inletsMatrix)
    # matrices for hubsPerCarrierMatrix
    variableNumbers = Array{IndexType}(undef, 0)
    hubIndexes = Array{IndexType}(undef, 0)
    carriersIndexes = Array{IndexType}(undef, 0)
    # matrices for carrierInletBalanceMatrix
    Ones = Array{IndexType}(undef, Ninlets)
    varInletsIndexes = Array{IndexType}(undef, Ninlets)
    variableNumbers2 = Array{IndexType}(undef, Ninlets)

    variableNumber = Izero

    for carrierIndex = 1:Ncarriers
        hubIndex_old = Izero
        for i in nzrange(inletsMatrix, carrierIndex)  # à améliorer pour ne pas parcourir toute la matrice (ou pas!)
            inletIndex = rows[i]
            varInletIndex = vals[i]
            hubIndex, unitIndex, inletIndex = decomposeIndex(inletIndex)
            if hubIndex > hubIndex_old
                hubIndex_old = hubIndex
                variableNumber = variableNumber + Ione
                push!(variableNumbers, variableNumber)
                push!(hubIndexes, hubIndex)
                push!(carriersIndexes, carrierIndex)
            end
            Ones[i] = Ione
            varInletsIndexes[i] = varInletIndex
            variableNumbers2[i] = variableNumber
        end
    end
    return sparse(hubIndexes, carriersIndexes, variableNumbers), sparse(varInletsIndexes, variableNumbers2, Ones)
end

# This function generates hubsPerCarrierMatrixIn  (for Outlets only) which indicates what hubs contain each carrier (rows: hub's n° / cols: carrier's n°)
# hubsPerCarrierMatrix is filled with hub's outet variable numbers (same as the previous one but has network input)

# This function generates also carrierOutletBalanceOut which indicates what outlets need to be summed to calculate the inlet at the hub level (rows: inlets variable n° / cols: hubs inlets variable n°)
# carrierInletBalance is filled with ones

function fillHubsOutletsPerCarrierMatrix(MCN::MultiCarrierNetwork)
    outletsMatrix = fillOutletsMatrix(MCN)
    Nhubs = (outletsMatrix.m ÷ (Nu_max * Ni_max)) + Ione
    Noutlets = length(outletsMatrix.nzval)
    Ncarriers = outletsMatrix.n
    rows = rowvals(outletsMatrix)
    vals = nonzeros(outletsMatrix)
    # Arrays for hubsPerCarrierMatrix
    variableNumbers = Array{IndexType}(undef, 0)
    hubIndexes = Array{IndexType}(undef, 0)
    carriersIndexes = Array{IndexType}(undef, 0)
    # Arrays for carrierOutetBalanceMatrix
    Ones = Array{IndexType}(undef, Noutlets)
    varOutletsIndexes = Array{IndexType}(undef, Noutlets)
    variableNumbers2 = Array{IndexType}(undef, Noutlets)

    variableNumber = Izero

    for carrierIndex = 1:Ncarriers
        hubIndex_old = Izero
        for i in nzrange(outletsMatrix, carrierIndex)  # à améliorer pour ne pas parcourir toute la matrice (ou pas!)
            outletIndex = rows[i]
            varOutletIndex = vals[i]
            hubIndex, unitIndex, outletIndex = decomposeIndex(outletIndex)
            if hubIndex > hubIndex_old
                hubIndex_old = hubIndex
                variableNumber = variableNumber + Ione
                push!(variableNumbers, variableNumber)
                push!(hubIndexes, hubIndex)
                push!(carriersIndexes, carrierIndex)
            end
            Ones[i] = Ione
            varOutletsIndexes[i] = varOutletIndex
            variableNumbers2[i] = variableNumber
        end
    end
    return sparse(hubIndexes, carriersIndexes, variableNumbers), sparse(varOutletsIndexes, variableNumbers2, Ones)
end

# This function allows to fill a matrix with the variable numbers of all the ports (purchase, sell, network, load and storage)
# hubs indexes are put in rows and carrier indexes are put in the colomns 
function fillPortsPerCarrier(MCN::MultiCarrierNetwork, portNature::Symbol)
    Nports = countPorts(MCN, portNature)
    varIndexes = Array{IndexType}(undef, Nports)
    hubIndexes = Array{IndexType}(undef, Nports)
    carrierIndexes = Array{IndexType}(undef, Nports)
    varIndex = Izero
    for (hubIndex, hub) in enumerate(MCN.hubs)
        ports = getfield(hub, portNature)
        for port in ports
            varIndex = varIndex + Ione
            varIndexes[varIndex] = varIndex
            hubIndexes[varIndex] = hubIndex
            carrierIndexes[varIndex] = port.carrierIndex
        end
    end
    return sparse(hubIndexes, carrierIndexes, varIndexes)
end

function fillPortsParametersArray(MCN::MultiCarrierNetwork, portName::Symbol, parameterName::Symbol, type::I=1) where {I<:Integer}
    # type = 1 : récupérer des vecteurs de réels // type = 2 : récupérer des réels
    Nports = countPorts(MCN, portName)   # peut être à supprimer
    # added zero at the end to handle the absence of some ports using extra variables
    if type == 2
        values = Vector{R}(undef, Nports + 1)
        values[Nports+1] = zero
    else
        values = Vector{Vector{R}}(undef, Nports + 1)
        values[Nports+1] = [zero]
    end
    varIndex = Izero
    for (hubIndex, hub) in enumerate(MCN.hubs)
        ports = getfield(hub, portName)
        for port in ports
            varIndex = varIndex + Ione
            values[varIndex] = getfield(port, parameterName)
        end
    end
    return values
end

function fillNetworksParametersArray(MCN::MultiCarrierNetwork, parameterName::Symbol, type::I=1) where {I<:Integer}
    if type == 1
        values = Vector{Vector{R}}(undef, length(MCN.networks))
        for (networkPortsIndex, network) in enumerate(MCN.networks)
            values[networkPortsIndex] = getfield(network, parameterName)
        end
    else
        values = Vector{R}(undef, length(MCN.networks))
        for (networkPortsIndex, network) in enumerate(MCN.networks)
            values[networkPortsIndex] = getfield(network, parameterName)
        end
    end
    return values
end

function fillLoadsPArray(MCN::MultiCarrierNetwork)
    Nloads = countPorts(MCN, :loads)  # peut être à supprimer
    Nsteps = MCN.Nsteps
    values = Matrix{R}(undef, Nloads, Nsteps)
    varIndex = Izero
    for (hubIndex, hub) in enumerate(MCN.hubs)
        loads = hub.loads
        for load in loads
            varIndex = varIndex + Ione
            values[varIndex, 1:Nsteps] = load.P
        end
    end
    return values
end

function fillNetworkLossesFactors(MCN::MultiCarrierNetwork)
    Ncarriers = length(MCN.energy_carriers)
    factors = Vector{R}(undef, Ncarriers)
    for (i, carrier) in enumerate(MCN.energy_carriers)
        factors[i] = carrier.networkLossFactor
    end

    return factors
end

addPurchasePort(hub::EnergyHub, port::PowerPort) = push!(hub.purchasePorts, port)
addSellPort(hub::EnergyHub, port::PowerPort) = push!(hub.sellPorts, port)
addLoadPort(hub::EnergyHub, port::PowerPort) = push!(hub.loadPorts, port)
addNetworkPort(hub::EnergyHub, port::PowerPort) = push!(hub.networkPorts, port)
addStoragePort(hub::EnergyHub, port::PowerPort) = push!(hub.storagePorts, port)
addStorage(hub::EnergyHub, storage::Storage) = push!(hub.storages, storage)
addLoad(hub::EnergyHub, load::Load) = push!(hub.loads, load)

function addPorts(MCN::MultiCarrierNetwork, hubsIndexes, carrierName::String, portType::Symbol, Pmin::Vector{R}, Pmax::Vector{R}, cost::R=zero, storageCapacity::R=zero, InvestmentParameterMax::R=zero, InvestmentCost::R=zero, OperatingCost::R=zero)
    MCNEnergyCarrierIndex = MCNHubJU.findMCNEnergyCarrier(MCN, carrierName)
    if MCNEnergyCarrierIndex == 0
        println("Energy carrier ", carrierName, " does not exist ! - Port cannot be added")
    else
        for hubIndex in hubsIndexes
            port = PowerPort(MCNHubJU.findMCNEnergyCarrier(MCN, carrierName), Pmin, Pmax, cost .* ones(MCN.Nsteps), InvestmentParameterMax, InvestmentCost, OperatingCost) # ajouter un message d'erreur si le carrier n'existe pas
            push!(getfield(MCN.hubs[hubIndex], portType), port)
            if portType == :storagePorts
                push!(MCN.hubs[hubIndex].storageCapacities, storageCapacity)
            end
            if portType == :networkPorts
                NetworkEnergyCarrierIndex = MCNHubJU.findNetworkEnergyCarrier(MCN, carrierName)
                if NetworkEnergyCarrierIndex == 0
                    addNetwork(MCN, Network(MCN.energy_carriers[MCNEnergyCarrierIndex]))
                    push!(MCN.networks[end].HubIndex, hubIndex)
                else
                    push!(MCN.networks[NetworkEnergyCarrierIndex].HubIndex, hubIndex)
                end
            end
        end
    end
end
addPorts(MCN::MultiCarrierNetwork, hubsIndexes, carrierName::String, portType::Symbol, Pmin::R, Pmax::R, cost::R=zero, storageCapacity::R=zero, InvestmentParameterMax::R=zero, InvestmentCost::R=zero, OperatingCost::R=zero) = addPorts(MCN, hubsIndexes, carrierName, portType, [Pmin], [Pmax], cost, storageCapacity, InvestmentParameterMax, InvestmentCost, OperatingCost)
addPorts(MCN::MultiCarrierNetwork, hubsIndexes, carrierName::String, portType::Symbol, Pmin::R, Pmax::Vector{R}, cost::R=zero, storageCapacity::R=zero, InvestmentParameterMax::R=zero, InvestmentCost::R=zero, OperatingCost::R=zero) = addPorts(MCN, hubsIndexes, carrierName, portType, [Pmin], Pmax, cost, storageCapacity, InvestmentParameterMax, InvestmentCost, OperatingCost)

function addStorages(MCN::MultiCarrierNetwork, hubsIndexes, carrierName::String, Pmax::R, Emax::R=zero, E0::R=zero; efficiency::R=one, CapitalCost::R=zero, MOCost::R=zero)
    storage = Storage(MCNHubJU.findMCNEnergyCarrier(MCN, carrierName), Pmax, Emax, E0, efficiency, CapitalCost, MOCost) # ajouter un message d'erreur si le carrier n'existe pas
    for hubIndex in hubsIndexes
        push!(MCN.hubs[hubIndex].storages, storage)
    end
end

function addLoads(MCN::MultiCarrierNetwork, hubsIndexes, carrierName::String, P::Vector{R}=Vector{R}(undef, 0))
    load = Load(MCNHubJU.findMCNEnergyCarrier(MCN, carrierName), P) # ajouter un message d'erreur si le carrier n'existe pas
    for hubIndex in hubsIndexes
        push!(MCN.hubs[hubIndex].loads, load)
    end
end

function addLoads(MCN::MultiCarrierNetwork, hubsIndexes, carrierName::String, P::R)
    Pvec = Vector{R}(undef, Int64(MCN.Nsteps))
    fill!(Pvec, P)
    addLoads(MCN, hubsIndexes, carrierName, Pvec)
end

function countPorts(MCN::MultiCarrierNetwork, fieldName::Symbol)
    nbr = 0
    for hub in MCN.hubs
        nbr = nbr + length(getfield(hub, fieldName))
    end
    return nbr
end

function addEnergyHub(MCN::MultiCarrierNetwork)
    push!(MCN.hubs, EnergyHub())
end

function addEnergyHubs(MCN::MultiCarrierNetwork, n::I) where {I<:Integer}
    for i in 1:n
        push!(MCN.hubs, EnergyHub())
    end
end

function addNetwork(MCN::MultiCarrierNetwork, network::Network)
    N = length(MCN.networks)
    network.index = N + 1
    push!(MCN.networks, network)
end

function addEnergyCarrier(MCN::MultiCarrierNetwork, carrier::EnergyCarrier)
    N = length(MCN.energy_carriers)
    carrier.index = N + 1
    push!(MCN.energy_carriers, carrier)
end

function addUnit(MCN::MultiCarrierNetwork, hubIndex::IndexType, unit::ConversionUnit)
    push!(MCN.hubs[hubIndex].units, unit)
    return length(MCN.hubs[hubIndex].units)
end

function findStringInObjectArray()     # 

end

function findMCNEnergyCarrier(MCN::MultiCarrierNetwork, energyCarrierName::String)
    index = 0
    for c in MCN.energy_carriers
        if c.name == energyCarrierName
            index = c.index
            break
        end
    end
    return index
end

function findNetworkEnergyCarrier(MCN::MultiCarrierNetwork, energyCarrierName::String)
    index = 0
    for Network in MCN.networks
        if Network.carrier.name == energyCarrierName
            index = Network.index
            break
        end
    end
    return index
end

function findUnitsInHub(MCN::MultiCarrierNetwork, hubIndex::I, unitName::String) where {I<:Integer}

    indexes = Vector{I}(undef, 0)
    for (unitIndex, unit) in enumerate(MCN.hubs[hubIndex].units)
        if unit.technology == unitName
            push!(indexes, unitIndex)
        end
    end

    return indexes
end

function addEnergCarriers(MCN::MultiCarrierNetwork, carriers_names::Array{String})
    N = length(carriers_names)
    indexes = Vector{IndexType}(undef, N)
    i = 0
    for carrier in carriers_names
        i = i + 1
        index = findMCNEnergyCarrier(MCN, carrier)
        if index == 0
            new_carrier = EnergyCarrier(carrier)
            addEnergyCarrier(MCN, new_carrier)
            indexes[i] = length(MCN.energy_carriers)
        else
            indexes[i] = index
        end
    end
    return indexes
end

# function addNetworks(MCN::MultiCarrierNetwork, network_name::String)
#     N = length(MCN.networks)
#     indexes = Vector{IndexType}(undef, N)
#     i = 0
#     for network in MCN.networks.name
#         i = i + 1
#         index = findNetworkEnergyCarrier(MCN, network)
#         if index == 0
#             new_network = Network(network)
#             addNetwork(MCN, new_network)
#             indexes[i] = length(MCN.networks)
#         else
#             indexes[i] = index
#         end
#     end
#     return indexes
# end

function addUnitFromTemplate(MCN::MultiCarrierNetwork, unit::ConversionUnitTemplate, hubIndex::IndexType)
    # adding energy carrier if not exist (from inputs)
    in_indexes = addEnergCarriers(MCN, unit.carriers_input)
    Ninputs = IndexType(length(in_indexes))
    # adding energy carrier if not exist (from outputs)
    out_indexes = addEnergCarriers(MCN, unit.carriers_output)
    Noutputs = IndexType(length(out_indexes))

    if Ninputs > length(unit.proportions_input)
        proportions_input = zero .* in_indexes
    else
        proportions_input = unit.proportions_input
    end

    if Noutputs > length(unit.proportions_output)
        proportions_output = one .* out_indexes
    else
        proportions_output = unit.proportions_output
    end

    new_unit = ConversionUnit(unit.technology, in_indexes, out_indexes, unit.globalEfficiency, proportions_input, proportions_output, unit.Pmax_in, unit.Pmax_out, unit.CapitalCost, unit.MOCost)
    unitIndex = addUnit(MCN, hubIndex, new_unit)
    MCN.Nunits = MCN.Nunits + Ione
    MCN.Ninlets = MCN.Ninlets + Ninputs
    MCN.Noutlets = MCN.Noutlets + Noutputs
end
addUnitFromTemplate(MCN::MultiCarrierNetwork, unit::ConversionUnitTemplate, hubIndex::I) where {I<:Integer} = addUnitFromTemplate(MCN, unit, IndexType(hubIndex))
function addUnitFromTemplate(MCN::MultiCarrierNetwork, unit::ConversionUnitTemplate, hubIndexes::Vector{I}) where {I<:Integer}
    for hubIndex in hubIndexes
        addUnitFromTemplate(MCN, unit, IndexType(hubIndex))
    end
end


function addUnit(MCN::MultiCarrierNetwork, hubIndex::I, technology::String, carriers_input::Vector{String}, carriers_output::Vector{String}, globalEfficiency::R=1.0, proportions_input::Vector{R}=[0.0], proportions_output::Vector{R}=[0.0]; Pmax_in::Vector{R}=[0.0], Pmax_out::Vector{R}=[0.0], CapitalCost::R=0.0, MOCost::R=0.0) where {I<:Integer,R<:Real}
    unitTemplate = ConversionUnitTemplate(technology, carriers_input, carriers_output, globalEfficiency, proportions_input, proportions_output, Pmax_in, Pmax_out, CapitalCost, MOCost)
    addUnitFromTemplate(MCN, unitTemplate, hubIndex)
end

function fillIndexunitIn(MCN::MultiCarrierNetwork)
    vector = Vector{IndexType}(undef, 3)
    for (hubIndex, hub) in enumerate(MCN.hubs)
        vector[1] = hubIndex
        for (unitIndex, unit) in enumerate(hub.units)
            vector[2] = unitIndex
            # adding information in energy carrier vectors  [hubIndex, unitIndex, inputIndex]
            i = Izero
            for (i, iCarrier) in enumerate(unit.carriersIndexes_in)
                vector[3] = i
                push!(MCN.energy_carriers[iCarrier].index_unit_in, copy(vector))

            end
            # adding information in energy carrier vectors  [hubIndex, unitIndex, inputIndex]
            i = Izero
            for (i, iCarrier) in enumerate(unit.carriersIndexes_out)
                vector[3] = i
                push!(MCN.energy_carriers[iCarrier].index_unit_out, copy(vector))
            end
        end
    end
end

function updateCarriersNumbers(MCN::MultiCarrierNetwork)
    for (carrierIndex, carrier) in enumerate(MCN.energy_carriers)
        index = Izero
        for i in carrier.index_unit_in
            if i[1] != index
                index = i[1]
                MCN.hubs[index].Ncarriers_in += Ione
            end
        end
        index = Izero
        for i in carrier.index_unit_out
            if i[1] != index
                index = i[1]
                MCN.hubs[index].Ncarriers_out += Ione
            end
        end
    end
end



function fillHubsInOutIndexes(MCN::MultiCarrierNetwork)
    for (carrierIndex, carrier) in enumerate(MCN.energy_carriers)
        index = Izero
        for i in carrier.index_unit_in
            if i[1] != index
                index = i[1]
                push!(carrier.index_hub_in, index)
                # push!(MCN.hubs[index].carriersIndexes_in, carrierIndex)
            end
        end
        index = Izero
        for i in carrier.index_unit_out
            if i[1] != index
                index = i[1]
                push!(carrier.index_hub_out, index)
                # push!(MCN.hubs[index].carriersIndexes_out, carrierIndex)
            end
        end
    end
end

function addProportionsConstraint(model::Model, mat::SparseMatrixCSC{IndexType,IndexType}, proportionsIn::Array{R}, Pmax_In::Array{R}, Xi::Array{VariableRef}, Xui::Array{VariableRef}, Nstep::IndexType)
    rows = rowvals(mat)
    vals = nonzeros(mat)
    m, n = size(mat)

    for unitIndex = 1:n
        for i in nzrange(mat, unitIndex)
            inletIndex = rows[i]
            inletVarIndex = vals[i]
            if proportionsIn[inletVarIndex] > 0.0
                @constraint(model, Xi[inletVarIndex, 1:Nstep] .== proportionsIn[inletVarIndex] * Xui[unitIndex, 1:Nstep])
                println("variable n° ", inletVarIndex, " is equal to a prop of variable n° ", unitIndex)
            else
                println("variable n° ", inletVarIndex, " has no proportion ")
            end
            #=             if Pmax_In[inletVarIndex] > 0.0
                            @constraint(model, Xi[inletVarIndex, 1:Nstep] .<= Pmax_In[inletVarIndex])
                            println("variable n° ", inletVarIndex, " is smaller than ", Pmax_In[inletVarIndex])
                        end =#
        end
    end
end

function addInletsSumConstraint(model::Model, mat::SparseMatrixCSC{IndexType,IndexType}, Xi::Array{VariableRef}, Xui::Array{VariableRef}, Nstep::IndexType)
    rows = rowvals(mat)
    vals = nonzeros(mat)
    m, n = size(mat)

    for unitIndex = 1:n
        inletVarIndexes = vals[nzrange(mat, unitIndex)]
        @constraint(model, sum(Xi[k, 1:Nstep] for k = inletVarIndexes) .== Xui[unitIndex, 1:Nstep])
    end
end

function addhubsInletsConstraint(model::Model, mat::SparseMatrixCSC{IndexType,IndexType}, Xui::Array{VariableRef}, Xhi::Array{VariableRef}, Nstep::IndexType)
    rows = rowvals(mat)
    vals = nonzeros(mat)
    m, n = size(mat)

    for j = 1:n
        hubInletVarIndex = j
        unitInletVarIndexes = rows[nzrange(mat, j)]

        @constraint(model, sum(Xui[k, 1:Nstep] for k = unitInletVarIndexes) .== Xhi[hubInletVarIndex, 1:Nstep])

    end
end

function addHubBalanceConstaintOut(model::Model, mat::Matrices, Xho::Array{VariableRef}, Xs::Array{VariableRef},
    Xst_charge::Array{VariableRef}, Xst_discharge::Array{VariableRef}, XEst::Array{VariableRef}, Xnp::Array{VariableRef}, Xnn::Array{VariableRef},
    Xni::Array{VariableRef}, Nsell::I, Nstorage::I, Nnetwork::I, Nreturn::I) where {I<:Integer}

    Nsteps = mat.Nsteps
    # add constraints for Xs, Xst, Xni and Xn to set the last row to zero 
    @constraint(model, Xs[Nsell+1, 1:Nsteps] .== 0.0)
    @constraint(model, Xst_charge[Nstorage+1, 1:Nsteps] .== 0.0)
    @constraint(model, Xst_discharge[Nstorage+1, 1:Nsteps] .== 0.0)
    @constraint(model, Xnp[Nnetwork+1, 1:Nsteps] .== 0.0)
    @constraint(model, Xnn[Nnetwork+1, 1:Nsteps] .== 0.0)
    @constraint(model, Xni[Nreturn+1, 1:Nsteps] .== 0.0)

    rows = rowvals(mat.hubsPerCarrierOut)
    vals = nonzeros(mat.hubsPerCarrierOut)
    m, n = size(mat.hubsPerCarrierOut)

    for carrierIndex = 1:n
        for i in nzrange(mat.hubsPerCarrierOut, carrierIndex)
            hubIndex = rows[i]
            outVarIndex = vals[i]

            # reformulate using sparse containers
            (size(mat.sellPerCarrier, 1) >= hubIndex && size(mat.sellPerCarrier, 2) >= carrierIndex) ? sellIndex = mat.sellPerCarrier[hubIndex, carrierIndex] : sellIndex = Nsell + 1
            (size(mat.loadPerCarrier, 1) >= hubIndex && size(mat.loadPerCarrier, 2) >= carrierIndex) ? loadIndex = mat.loadPerCarrier[hubIndex, carrierIndex] : loadIndex = Izero
            (size(mat.storagePerCarrier, 1) >= hubIndex && size(mat.storagePerCarrier, 2) >= carrierIndex) ? storageIndex = mat.storagePerCarrier[hubIndex, carrierIndex] : storageIndex = Nstorage + 1
            (size(mat.networkPortsPerCarrier, 1) >= hubIndex && size(mat.networkPortsPerCarrier, 2) >= carrierIndex) ? networkPortsIndex = mat.networkPortsPerCarrier[hubIndex, carrierIndex] : networkPortsIndex = Nnetwork + 1
            (size(mat.returnPerCarrier, 1) >= hubIndex && size(mat.returnPerCarrier, 2) >= carrierIndex) ? returnIndex = mat.returnPerCarrier[hubIndex, carrierIndex] : returnIndex = Nreturn + 1
            sellIndex == zero ? sellIndex = Nsell + 1 : sellIndex = sellIndex
            storageIndex == zero ? storageIndex = Nstorage + 1 : storageIndex = storageIndex
            networkPortsIndex == zero ? networkPortsIndex = Nnetwork + 1 : networkPortsIndex = networkPortsIndex
            returnIndex == zero ? returnIndex = Nreturn + 1 : returnIndex = returnIndex

            if loadIndex > Izero
                Pl = mat.loadsP[loadIndex, 1:Nsteps]
            else
                Pl = 0.0
            end
            println("Hub n°: ", hubIndex, ", carrier n°: ", carrierIndex, ", hasSellPort: ", sellIndex < Nsell + 1, ", hasStorage: ", storageIndex < Nstorage + 1, ", load: ", loadIndex)
            @constraint(model, Xho[outVarIndex, 1:Nsteps] + Xst_discharge[storageIndex, 1:Nsteps] + Xnn[networkPortsIndex, 1:Nsteps] .== Pl + Xs[sellIndex, 1:Nsteps] + Xst_charge[storageIndex, 1:Nsteps] + Xnp[networkPortsIndex, 1:Nsteps] + Xni[returnIndex, 1:Nsteps])
            #@constraint(model, Xn[networkPortsIndex,1:Nsteps] + Xni[networkPortsIndex,1:Nsteps] .>= zero)
            if storageIndex < Nstorage + 1
                @constraint(model, XEst[storageIndex, 1] == mat.storageE0[storageIndex] + mat.storageEfficiencies[storageIndex] * Xst_charge[storageIndex, 1] - Xst_discharge[storageIndex, 1] / mat.storageEfficiencies[storageIndex])
                @constraint(model, XEst[storageIndex, 2:Nsteps] .== XEst[storageIndex, 1:Nsteps-1] .+ mat.storageEfficiencies[storageIndex] .* Xst_charge[storageIndex, 2:Nsteps] .- Xst_discharge[storageIndex, 2:Nsteps] ./ mat.storageEfficiencies[storageIndex])

            end




            # if (sellIndex == Izero) & (storageIndex == Izero) & (networkPortsIndex == Izero)
            #     println("Hub n° ", hubIndex, ": case without sell, without storage and without network")
            #     @constraint(model, Xho[outVarIndex,1:Nsteps] .== Pl)
            # elseif (sellIndex > Izero) & (storageIndex == Izero) & (networkPortsIndex == Izero)
            #     println("Hub n° ", hubIndex, ": case with sell, without storage and without network")
            #     @constraint(model, Xho[outVarIndex,1:Nsteps] .== Pl + Xs[sellIndex,1:Nsteps])
            # elseif (sellIndex > Izero) & (storageIndex > Izero) & (networkPortsIndex == Izero)
            #     println("Hub n° ", hubIndex, ": case with sell, with storage and without network")
            #     @constraint(model, Xho[outVarIndex,1:Nsteps] .== Pl + Xs[sellIndex,1:Nsteps] + Xst[storageIndex,1:Nsteps])
            #     @constraint(model, XEst[storageIndex,1] == mat.storageE0[storageIndex] + Xst[storageIndex,1])
            #     @constraint(model, XEst[storageIndex,2:Nsteps] .== XEst[storageIndex,1:Nsteps - 1] + Xst[storageIndex,2:Nsteps])
            # elseif (sellIndex > Izero) & (storageIndex > Izero) & (networkPortsIndex > Izero)
            #     println("Hub n° ", hubIndex, ": case with sell, with storage and with network")
            #     @constraint(model, Xho[outVarIndex,1:Nsteps] .== Pl + Xs[sellIndex,1:Nsteps] + Xst[storageIndex,1:Nsteps] + Xn[networkPortsIndex,1:Nsteps] + Xni[networkPortsIndex,1:Nsteps])
            #     @constraint(model, Xn[networkPortsIndex,1:Nsteps] + Xni[networkPortsIndex,1:Nsteps] .>= zero)
            #     @constraint(model, XEst[storageIndex,1] == mat.storageE0[storageIndex] + Xst[storageIndex,1])
            #     @constraint(model, XEst[storageIndex,2:Nsteps] .== XEst[storageIndex,1:Nsteps - 1] + Xst[storageIndex,2:Nsteps])
            # elseif (sellIndex == Izero) & (storageIndex > Izero) & (networkPortsIndex > Izero)
            #     println("Hub n° ", hubIndex, ": case without sell, with storage and with network")
            #     @constraint(model, Xho[outVarIndex,1:Nsteps] .== Pl + Xst[storageIndex,1:Nsteps] + Xn[networkPortsIndex,1:Nsteps])
            #     @constraint(model, Xn[networkPortsIndex,1:Nsteps] + Xni[networkPortsIndex,1:Nsteps] .>= zero)
            #     @constraint(model, XEst[storageIndex,1] == mat.storageE0[storageIndex] + Xst[storageIndex,1])
            #     @constraint(model, XEst[storageIndex,2:Nsteps] .== XEst[storageIndex,1:Nsteps - 1] + Xst[storageIndex,2:Nsteps])
            # end
        end
    end
end

function addHubBalanceConstaintIn(model::Model, mat::Matrices, Xhi::Array{VariableRef}, Xp::Array{VariableRef}, Xni::Array{VariableRef})
    rows = rowvals(mat.hubsPerCarrierIn)
    vals = nonzeros(mat.hubsPerCarrierIn)
    m, n = size(mat.hubsPerCarrierIn)
    Nsteps = mat.Nsteps

    for carrierIndex = 1:n
        for i in nzrange(mat.hubsPerCarrierIn, carrierIndex)
            hubIndex = rows[i]
            inVarIndex = vals[i]

            (size(mat.purchasePerCarrier, 1) >= hubIndex && size(mat.purchasePerCarrier, 2) >= carrierIndex) ? purchaseVarIndex = mat.purchasePerCarrier[hubIndex, carrierIndex] : purchaseVarIndex = Izero
            (size(mat.returnPerCarrier, 1) >= hubIndex && size(mat.returnPerCarrier, 2) >= carrierIndex) ? returnIndex = mat.returnPerCarrier[hubIndex, carrierIndex] : returnIndex = Izero
            hasPurchase = purchaseVarIndex > Izero
            hasReturn = returnIndex > Izero

            if hasPurchase & !hasReturn
                println("Hub Inlet n°: ", inVarIndex, " is equal to purchase Inlet n°: ", purchaseVarIndex)
                @constraint(model, Xhi[inVarIndex, 1:Nsteps] .== Xp[purchaseVarIndex, 1:Nsteps])
            elseif hasPurchase & hasReturn
                println("Hub Inlet n°: ", inVarIndex, " is equal to purchase Inlet n°: ", purchaseVarIndex, " and to return Inlet N°: ", returnIndex)
                @constraint(model, Xhi[inVarIndex, 1:Nsteps] .== Xp[purchaseVarIndex, 1:Nsteps] + Xni[returnIndex, 1:Nsteps])
            elseif !hasPurchase & hasReturn
                println("Hub Inlet n°: ", inVarIndex, " is equal to return Inlet n°: ", returnIndex)
                @constraint(model, Xhi[inVarIndex, 1:Nsteps] .== Xni[returnIndex, 1:Nsteps])
            else
                println("Hub Inlet n°: ", inVarIndex, " is not connected")
                @constraint(model, Xhi[inVarIndex, 1:Nsteps] .== zero)
            end
        end
    end
end

function addNetworkBalanceConstraint(model::Model, mat::Matrices, Xnp::Array{VariableRef}, Xnn::Array{VariableRef})
    rows = rowvals(mat.networkPortsPerCarrier)
    vals = nonzeros(mat.networkPortsPerCarrier)
    m, n = size(mat.networkPortsPerCarrier)
    Nsteps = mat.Nsteps

    for carrierIndex = 1:n
        hubIndexes = vals[nzrange(mat.networkPortsPerCarrier, carrierIndex)]
        if length(hubIndexes) > 0
            # @constraint(model, sum(Xnp[i, 1:Nsteps] for i = hubIndexes) .== (one + mat.networkLossesFactors[carrierIndex]) * sum(Xnn[i, 1:Nsteps] for i = hubIndexes))
            @constraint(model, sum(Xnp[i, 1:Nsteps] for i = hubIndexes) .== sum(Xnn[i, 1:Nsteps] for i = hubIndexes))

        end
    end

end

function addEpsilonConstraint(model::Model, MCN::MultiCarrierNetwork, mat::Matrices, carrier::String, constraint::R)
    carrierIndex = findMCNEnergyCarrier(MCN, carrier)
    carrierIndexSell = nonzeros(mat.sellPerCarrier)[nzrange(mat.sellPerCarrier, carrierIndex)]
    # return carrierIndexSell, constraint
    @constraint(model, sum(sum(model.obj_dict[:Xs][i, j] for i = carrierIndexSell) for j = 1:mat.Nsteps) .<= constraint)
end
addEpsilonConstraint(MCN::MultiCarrierNetwork, Carrier::String, Constraint::R) = addEpsilonConstraint(Model, MCN, matrices, Carrier, Constraint)

function constructModel(matrices::Matrices)
    Nstep = matrices.Nsteps # will become a parameter
    # Preparing an optimization model
    model = Model(Gurobi.Optimizer)

    # Extracting number of variables
    NhubsInlets = matrices.carrierInletBalance.n              # Total number of inlets in the network (systems)
    NhubsOutlets = matrices.carrierOutletBalance.n            # Total number of outlets in the network (systems)
    NPurchase = length(matrices.purchasePerCarrier.nzval)     # Total number of purchase ports in the network (hubs, one for each carrier)
    NPurchaseInvestment = length(findall(!iszero, matrices.purchaseInvestmentParameterMax))
    NSell = length(matrices.sellPerCarrier.nzval)             # Total number of sell ports in the network (hubs, one for each carrier)
    NStorage = length(matrices.storagePerCarrier.nzval)       # Total number of storage units in the network
    NNetworkPorts = length(matrices.networkPortsPerCarrier.nzval)       # Total number of network ports the network (hubs)
    Nreturn = length(matrices.returnPerCarrier.nzval)       # Total number of network ports the network (hubs)
    Nunits = matrices.Nunits                                # Total number of units (systems) in the network

    NPmax_in = length(filter(x -> x > 0, matrices.Pmax_in))
    NPmax_out = length(filter(x -> x > 0, matrices.Pmax_out))
    PmaxIndexesIn = zeros(Int64, NPmax_in)
    PmaxUnitIndexIn = zeros(Int64, NPmax_in)
    PmaxIndexesOut = zeros(Int64, NPmax_out)
    PmaxUnitIndexOut = zeros(Int64, NPmax_out)



    np = 0
    rows = rowvals(matrices.inletsPerUnit)
    vals = nonzeros(matrices.inletsPerUnit)
    m, n = size(matrices.inletsPerUnit)

    for unitIndex = 1:n
        for i in nzrange(matrices.inletsPerUnit, unitIndex)


            inletIndex = rows[i]
            inletVarIndex = vals[i]

            if matrices.Pmax_in[inletVarIndex] > 0.0
                np = np + 1
                PmaxIndexesIn[np] = inletVarIndex
                PmaxUnitIndexIn[np] = unitIndex
            end

        end
    end

    rows = rowvals(matrices.outletsPerUnit)
    vals = nonzeros(matrices.outletsPerUnit)
    m, n = size(matrices.outletsPerUnit)

    np = 0
    for unitIndex = 1:n
        for i in nzrange(matrices.outletsPerUnit, unitIndex)

            outletIndex = rows[i]
            outletVarIndex = vals[i]

            if matrices.Pmax_out[outletVarIndex] > 0.0
                np = np + 1
                PmaxIndexesOut[np] = outletVarIndex
                PmaxUnitIndexOut[np] = unitIndex
            end

        end
    end


    ##### Declaring variables
    # we will add an extra variable at the end of Xs, Xst, Xni, Xn to handle the case where a port does not exist

    # inlets and outlets of the units
    Xi = @variable(model, Xi[i=1:matrices.Ninlets, j=1:Nstep], lower_bound = zero)        # Variables container for powers in the inlets (systems)
    Xo = @variable(model, Xo[i=1:matrices.Noutlets, j=1:Nstep], lower_bound = zero)       # Variables container for powers in the outlets (systems)

    for i = 1:matrices.Ninlets
        if matrices.Pmax_in[i] > 0
            for j = 1:Nstep
                set_upper_bound(Xi[i, j], matrices.Pmax_in[i])
            end
        end
    end

    for i = 1:matrices.Noutlets
        if matrices.Pmax_out[i] > 0
            for j = 1:Nstep
                set_upper_bound(Xo[i, j], matrices.Pmax_out[i])
            end
        end

    end

    # Maximum inlet and outlet power 
    Ximax = @variable(model, Ximax[i=1:NPmax_in], lower_bound = zero)
    Xomax = @variable(model, Xomax[i=1:NPmax_out], lower_bound = zero)


    for (index, inletIndex) = enumerate(PmaxIndexesIn)
        set_upper_bound(Ximax[index], matrices.Pmax_in[inletIndex])
    end

    for (index, outletIndex) = enumerate(PmaxIndexesOut)
        set_upper_bound(Xomax[index], matrices.Pmax_out[outletIndex])
    end

    # Inlet and outlet power is less than maximum inlet and outlet power
    for t = 1:Nstep
        @constraint(model, Ximax - Xi[PmaxIndexesIn, t] .>= 0)
    end
    for t = 1:Nstep
        @constraint(model, Xomax - Xo[PmaxIndexesOut, t] .>= 0)
    end

    # Maximum storage power capacity
    Xstoragemax = @variable(model, Xstoragemax[i=1:NStorage], lower_bound = zero)
    for index in NStorage
        set_upper_bound(Xstoragemax[index], matrices.storagePmax[index])
    end
    # Total power inlets and outlets of each unit
    Xui = @variable(model, Xui[i=1:Nunits, j=1:Nstep], lower_bound = zero)
    Xuo = @variable(model, Xuo[i=1:Nunits, j=1:Nstep], lower_bound = zero)

    # Total power inlet at the hub level for each carrier (only present carriers have variables)
    Xhi = @variable(model, Xhi[i=1:NhubsInlets, j=1:Nstep], lower_bound = zero)
    Xho = @variable(model, Xho[i=1:NhubsOutlets, j=1:Nstep], lower_bound = zero)

    # purshased power (only present carriers have variables)
    Xp = @variable(model, Xp[i=1:NPurchase, j=1:Nstep], lower_bound = zero)
    XpMax = @variable(model, XpMax[i=1:NPurchaseInvestment], lower_bound = zero)

    kk = Izero
    for i = 1:NPurchase
        if ((matrices.purchaseInvestmentParameterMax[i]) == 0.0)
            if length(matrices.purchasePmax[i]) == 1
                for j = 1:Nstep
                    set_upper_bound(Xp[i, j], matrices.purchasePmax[i][1])
                end
            else
                for j = 1:Nstep
                    set_upper_bound(Xp[i, j], matrices.purchasePmax[i][j])
                end
            end
        else
            kk = kk + Ione
            if length(matrices.purchasePmax[i]) == 1
                for j = 1:Nstep
                    @constraint(model, Xp[i, j] .<= matrices.purchasePmax[i][1] .* XpMax[kk])
                end
            else
                for j = 1:Nstep
                    @constraint(model, Xp[i, j] .<= matrices.purchasePmax[i][j] .* XpMax[kk])
                end
            end
        end
    end

    for i = 1:NPurchase
        if length(matrices.purchasePmin[i]) == 1
            for j = 1:Nstep
                set_lower_bound(Xp[i, j], matrices.purchasePmin[i][1])
            end
        else
            for j = 1:Nstep
                set_lower_bound(Xp[i, j], matrices.purchasePmin[i][j])
            end
        end
    end
    # sold power (only present carriers have variables)
    Xs = @variable(model, Xs[i=1:NSell+1, j=1:Nstep], lower_bound = zero)
    for i = 1:NSell
        if length(matrices.sellPmax[i]) == 1
            for j = 1:Nstep
                set_upper_bound(Xs[i, j], matrices.sellPmax[i][1])
            end
        else
            for j = 1:Nstep
                set_upper_bound(Xs[i, j], matrices.sellPmax[i][j])
            end
        end

    end

    # stored power and Energy (only present carriers have variables)
    Xst_charge = @variable(model, Xst_charge[i=1:NStorage+1, j=1:Nstep], lower_bound = zero, upper_bound = matrices.storagePmax[i])
    Xst_discharge = @variable(model, Xst_discharge[i=1:NStorage+1, j=1:Nstep], lower_bound = zero, upper_bound = matrices.storagePmax[i])
    XEst = @variable(model, XEst[i=1:NStorage+1, j=1:Nstep], lower_bound = zero, upper_bound = matrices.storageEmax[i])
    for i = 1:NStorage
        for t = 1:Nstep
            @constraint(model, Xstoragemax[i] - XEst[i, t] .>= 0)
        end
    end


    # Power injected to the network (only present carriers have variables) Rq: here a return from the network is always present if a network port is present
    Xnp = @variable(model, Xnp[i=1:NNetworkPorts+1, j=1:Nstep], lower_bound = zero) # Power injected to the networks
    Xnn = @variable(model, Xnn[i=1:NNetworkPorts+1, j=1:Nstep], lower_bound = zero) # Power extracted from the networks
    for i = 1:NNetworkPorts
        if length(matrices.networkPortsPmax[i]) == 1
            for j = 1:Nstep
                set_upper_bound(Xnp[i, j], matrices.networkPortsPmax[i][1])
            end
        else
            for j = 1:Nstep
                set_upper_bound(Xnp[i, j], matrices.networkPortsPmax[i][j])
            end
        end
    end

    for i = 1:NNetworkPorts
        if length(matrices.networkPortsPmin[i]) == 1
            for j = 1:Nstep
                set_lower_bound(Xnn[i, j], matrices.networkPortsPmin[i][1])
            end
        else
            for j = 1:Nstep
                set_lower_bound(Xnn[i, j], matrices.networkPortsPmin[i][j])
            end
        end
    end
    Xni = @variable(model, Xni[i=1:Nreturn+1, j=1:Nstep], lower_bound = zero) #change variable name
    # add return power upper limits

    ###### Declaring equality constraints

    # inlets proportions 
    println("*** constraints: inlets proportions")
    addProportionsConstraint(model, matrices.inletsPerUnit, matrices.proportionsIn, matrices.Pmax_in, Xi, Xui, Nstep)

    # outlets proportions 
    println("*** constraints: outlets proportions ")
    addProportionsConstraint(model, matrices.outletsPerUnit, matrices.proportionsOut, matrices.Pmax_out, Xo, Xuo, Nstep)

    # unit inlets sum constraints
    println("*** constraints : unit intlets sum is equal to total unit intlet")
    addInletsSumConstraint(model, matrices.inletsPerUnit, Xi, Xui, Nstep)

    # constraints: unit outlets sum is equal to total unit outlet 
    println("*** constraints: unit outlets sum is equal to total unit outlet")
    addInletsSumConstraint(model, matrices.outletsPerUnit, Xo, Xuo, Nstep)

    # units efficiencies constraints
    println("*** constraints: units total outlet is equal to efficiencies multiplied by unit's efficiency")
    @constraint(model, Xuo .== matrices.unitsEfficiencies[1:Nunits] .* Xui)

    # hubs inlets (sum of unit's inlets of the same carrier)
    println("*** constraints: hubs inlets (sum of unit's inlets of the same carrier)")
    addhubsInletsConstraint(model, matrices.carrierInletBalance, Xi, Xhi, Nstep)

    # hubs outlets (sum of unit's oulets of the same carrier)
    println("*** constraints: hubs inlets (sum of unit's inlets of the same carrier)")
    addhubsInletsConstraint(model, matrices.carrierOutletBalance, Xo, Xho, Nstep)


    println("*** constraints: Energy balances at the outlets of the hubs")
    addHubBalanceConstaintOut(model, matrices, Xho, Xs, Xst_charge, Xst_discharge, XEst, Xnp, Xnn, Xni, NSell, NStorage, NNetworkPorts, Nreturn)

    println("*** constraints: Energy balances at the inlets of the hubs")
    addHubBalanceConstaintIn(model, matrices, Xhi, Xp, Xni)

    println("*** constraints: Energy balances at the network's level for each energy carrier")
    addNetworkBalanceConstraint(model, matrices, Xnp, Xnn)

    # @objective(model, Min,sum(sum(matrices.purchaseCosts[j][i] .* Xp[j,i] for j = 1:NPurchase) - sum(matrices.sellCosts[k][i] .* Xs[k,i] for k = 1:NSell) + sum(matrices.networkPortsCosts[l][i] .* Xn[l,i] for l = 1:NNetworkPorts) for i = 1:Nstep))


    VCU = matrices.unitsCapitalCosts .+ matrices.unitsMOCosts
    VCS = matrices.storageCapitalCosts .+ matrices.storageMOCosts
    VCP = matrices.purchaseInvestmentCost .+ matrices.purchaseOperatingCost
    @objective(model, Min, sum(VCP[i] .* XpMax[i] for i = 1:NPurchaseInvestment) + sum(VCU[PmaxUnitIndexIn[i]] .* Ximax[i] for i = 1:length(PmaxUnitIndexIn)) + sum(VCU[PmaxUnitIndexOut[i]] .* Xomax[i] for i = 1:length(PmaxUnitIndexOut)) + sum(VCS[i] .* Xstoragemax[i] for i = 1:NStorage) + sum(sum(matrices.purchaseCosts[j][i] .* Xp[j, i] for j = 1:NPurchase) - sum(matrices.sellCosts[k][i] .* Xs[k, i] for k = 1:NSell) for i = 1:Nstep))
    # @objective(model, Min, sum(sum(matrices.purchaseCosts[j][i] .* Xp[j, i] for j = 1:NPurchase) - sum(matrices.sellCosts[k][i] .* Xs[k, i] for k = 1:NSell) for i = 1:Nstep))
    return model
end

function solve(model)

    #println(model)
    optimize!(model)

    #=   
       println("Optimal Solutions:")
       println("Xi = ", JuMP.value.(Xi))
       println("Xo = ", JuMP.value.(Xo))
       println("Xui = ", JuMP.value.(Xui))
       println("Xuo = ", JuMP.value.(Xuo))
       println("Xhi = ", JuMP.value.(Xhi))
       println("Xho = ", JuMP.value.(Xho))
       println("Xp = ", JuMP.value.(Xp))
       println("Xs = ", JuMP.value.(Xs))
       println("Xst = ", JuMP.value.(Xst))
       println("XEst = ", JuMP.value.(XEst))
       println("Xn = ", JuMP.value.(Xn))
       println("Xni = ", JuMP.value.(Xni))     

    =#

    println("Réseau : simultanés ? = ", sum(JuMP.value.(model.obj_dict[:Xnp]) .> 0 .* JuMP.value.(model.obj_dict[:Xnn]) .> 0))
    println("Stockage : simultanés ? = ", sum(JuMP.value.(model.obj_dict[:Xst_charge]) .> 0 .* JuMP.value.(model.obj_dict[:Xst_discharge]) .> 0))
    results = OptimResults(JuMP.value.(model.obj_dict[:Xi]), JuMP.value.(model.obj_dict[:Xo]), JuMP.value.(model.obj_dict[:Xui]), JuMP.value.(model.obj_dict[:Xuo]), JuMP.value.(model.obj_dict[:Xhi]), JuMP.value.(model.obj_dict[:Xho]), JuMP.value.(model.obj_dict[:Xp]), JuMP.value.(model.obj_dict[:Xs]), JuMP.value.(model.obj_dict[:Xst_charge]), JuMP.value.(model.obj_dict[:Xst_discharge]), JuMP.value.(model.obj_dict[:XEst]), JuMP.value.(model.obj_dict[:Xnp]) .- JuMP.value.(model.obj_dict[:Xnn]), JuMP.value.(model.obj_dict[:Xni]))
    return results
end


function inletIndex(MCN::MultiCarrierNetwork, mat::Matrices, hubIndex::I, unitName::String, carrierName::String) where {I<:Integer}
    NumberOfUnitsInPreviousHubs = I(0)
    for hub in MCN.hubs[1:hubIndex-1]
        NumberOfUnitsInPreviousHubs += length(hub.units)
    end

    MCNEnergyCarrierIndex = findMCNEnergyCarrier(MCN, carrierName)
    unitIndexes = findUnitsInHub(MCN, hubIndex, unitName)
    unitInletVarIndexes = copy(unitIndexes)

    for (i, unit) in enumerate(MCN.hubs[hubIndex].units[unitIndexes])
        unitInletIndex = findfirst(x -> x == MCNEnergyCarrierIndex, unit.carriersIndexes_in) # inlet indexes in the unit
        unitIndexes[i] += NumberOfUnitsInPreviousHubs
        unitInletVarIndexes[i] = mat.inletsPerUnit[unitInletIndex, unitIndexes[i]]

    end

    return unitIndexes, unitInletVarIndexes
end

function outletIndex(MCN::MultiCarrierNetwork, mat::Matrices, hubIndex::I, unitName::String, carrierName::String) where {I<:Integer}
    NumberOfUnitsInPreviousHubs = I(0)
    for hub in MCN.hubs[1:hubIndex-1]
        NumberOfUnitsInPreviousHubs += length(hub.units)
    end

    MCNEnergyCarrierIndex = findMCNEnergyCarrier(MCN, carrierName)
    unitIndexes = findUnitsInHub(MCN, hubIndex, unitName)
    unitOutletVarIndexes = copy(unitIndexes)

    for (i, unit) in enumerate(MCN.hubs[hubIndex].units[unitIndexes])
        unitOutletIndex = findfirst(x -> x == MCNEnergyCarrierIndex, unit.carriersIndexes_out) # outlet indexes in the unit
        unitIndexes[i] += NumberOfUnitsInPreviousHubs
        unitOutletVarIndexes[i] = mat.outletsPerUnit[unitOutletIndex, unitIndexes[i]]

    end

    return unitIndexes, unitOutletVarIndexes
end

function allInletsOutlets(MCN::MultiCarrierNetwork, portNature::Symbol)

    hubIndexes = Vector{IndexType}(undef, 0)
    unitNames = Vector{String}(undef, 0)
    carrierNames = Vector{String}(undef, 0)

    for (hubIndex, hub) in enumerate(MCN.hubs)
        for unit in hub.units
            unitName = unit.technology
            for carrierIndex in getfield(unit, portNature)
                carrierName = MCN.energy_carriers[carrierIndex].name
                push!(hubIndexes, hubIndex)
                push!(unitNames, unitName)
                push!(carrierNames, carrierName)
            end
        end
    end

    return hubIndexes, unitNames, carrierNames
end

allunitsInlets(MCN) = allInletsOutlets(MCN, :carriersIndexes_in)
allunitsOutlets(MCN) = allInletsOutlets(MCN, :carriersIndexes_out)

function iterate(M::SA) where {SA<:AbstractSparseArray}

    rows = rowvals(M)
    vals = nonzeros(M)
    m, n = size(M)
    T = typeof(vals[1])
    r = Vector{Tuple{Int64,Int64,T}}(undef, length(vals))

    c = 0
    for j = 1:n
        for i in nzrange(M, j)
            c += 1
            r[c] = (rows[i], j, vals[i])
        end
    end

    return r
end

function allHubsResults(MCN::MultiCarrierNetwork, mat::Matrices, portNature::Symbol)
    M = getfield(mat, portNature)
    Nelements = length(M.nzval)
    hubIndexes = Vector{IndexType}(undef, Nelements)
    InvestmentCost = Vector{R}(undef, Nelements)
    OperatingCost = Vector{R}(undef, Nelements)
    carrierNames = Vector{String}(undef, Nelements)
    for (hubIndex, carrierIndex, varIndex) in iterate(M)
        hubIndexes[varIndex] = hubIndex
        carrierNames[varIndex] = MCN.energy_carriers[carrierIndex].name
        if portNature == :purchasePerCarrier
            InvestmentCost[varIndex] = mat.purchaseInvestmentCost[varIndex]
            OperatingCost[varIndex] = mat.purchaseOperatingCost[varIndex]
        else
            InvestmentCost[varIndex] = 0.0
            OperatingCost[varIndex] = 0.0
        end
    end
    return hubIndexes, carrierNames, InvestmentCost, OperatingCost
end

allHubsPurchases(MCN, mat) = allHubsResults(MCN, mat, :purchasePerCarrier)
allHubsExports(MCN, mat) = allHubsResults(MCN, mat, :sellPerCarrier)
allHubsLoads(MCN, mat) = allHubsResults(MCN, mat, :loadPerCarrier)
allStorages(MCN, mat) = allHubsResults(MCN, mat, :storagePerCarrier)
allNetworkOutlets(MCN, mat) = allHubsResults(MCN, mat, :networkPortsPerCarrier)
allReturns(MCN, mat) = allHubsResults(MCN, mat, :returnPerCarrier)
allHubsOutlets(MCN, mat) = allHubsResults(MCN, mat, :hubsPerCarrierOut)

function setNetworkLossFactor(MCN::MultiCarrierNetwork, carrierName::String, value::R)
    carrierIndex = findMCNEnergyCarrier(MCN, carrierName)
    if carrierIndex > 0
        MCN.energy_carriers[carrierIndex].networkLossFactor = value
    else
        println("There is no carrier called ", carrierName)
    end
end
#= 
function constructVariablesContainer(model::JuMP.Model,MCN::MultiCarrierNetwork,Nstep::IndexType)
    # create variables
    variables = GlobalVariableContainer()
    for hub in MCN.hubs
        push!(variables.hubs, HubVariableContainer())
        for unit in hub.units
            Nin = length(unit.carriersIndexes_in)
            Nout = length(unit.carriersIndexes_out)
            xi = @variable(model, [i=1:Nin, j=1:Nstep], lower_bound=zero)
            xo = @variable(model, [i=1:Nout, j=1:Nstep], lower_bound=zero)
            ti = @variable(model, [i=1:Nstep], lower_bound=zero)
            to = @variable(model, [i=1:Nstep], lower_bound=zero)

            UnitVariableContainer(xi,xo,ti,to)
            #=
            push!(variables.hubs[end].units, UnitVariableContainer(xi,xo,ti,to))
            # input/output balance in each unit
            for j=1:Nstep
                @constraint(model, to[1,j] == unit.globalEfficiency*ti[1,j])
                for i=1:Nin
                    @constraint(model, xi[i] == unit.proportions_input[i]*ti[1,j] )
                end
                for i=1:Nout
                    @constraint(model, xo[i] == unit.proportions_output[i]*to[1,j] )
                end
            end
            =#
        end
        Ncarriers_in = hub.Ncarriers_in
        Ncarriers_out = hub.Ncarriers_out
        variables.hubs[end].P_purchased = @variable(model, [i=1:Ncarriers_in, j=1:Nstep], lower_bound=zero)
        variables.hubs[end].P_produced = @variable(model, [i=1:Ncarriers_in, j=1:Nstep], lower_bound=zero)
        #variables.hubs[end].P_imported = @variable(model, [i=1:Ncarriers_out, j=1:Nstep])
        #variables.hubs[end].P_sold = @variable(model, [i=1:Ncarriers_out, j=1:Nstep])
        #variables.hubs[end].P_stored = @variable(model, [i=1:Ncarriers_out, j=1:Nstep])
        #variables.hubs[end].P_interface = @variable(model, [i=1:Ncarriers_out, j=1:Nstep])
    end
    return variables
end
function constructModel(MCN::MultiCarrierNetwork,Nstep::IndexType)
    # Preparing an optimization model
    model = Model(Gurobi.Optimizer)
    fillHubsInOutIndexes(MCN)
    variables = constructVariablesContainer(model, MCN, Nstep)
    indexes_in = fill(Izero, length(MCN.hubs))
    indexes_out = fill(Izero, length(MCN.hubs))
    for carrier in MCN.energy_carriers
        # adding constraints sum of inputs = to input for that energy carrier
        if length(carrier.index_unit_in) > Izero
            lastHub = carrier.index_unit_in[1][1]
            indexes_in[lastHub] += Ione
            indexFirst = Ione
            indexLast = Ione
            for vector in carrier.index_unit_in
                Nh = vector[1]
                Nu = vector[2]
                Ni = vector[3]
                if lastHub == Nh
                    indexLast += Ione
                else
                    indexes_in[lastHub]+= Ione
                    @constraint(model,sum(variables.hubs[lasHub].units[carrier.index_unit_in[i][2]][carrier.index_unit_in[i][2]] for i=indexFirst:indexLast) == variables.hubs[lasHub].P_purchased)
                    lastHub = Nh
                    indexLast += Ione
                    indexFirst = indexLast
                end
                for j = 1:Nstep
                    @constraint(model,sum(variables.hubs[lastHub].units[carrier.index_unit_in[i][2]].in[carrier.index_unit_in[i][3],j] for i=indexFirst:length(carrier.index_unit_in)) == variables.hubs[lastHub].P_purchased[indexes_in[lastHub],j])
                end
            end
        end
    end

    for carrier in MCN.energy_carriers
        # adding constraints sum of inputs = to produced energy for that energy carrier
        if length(carrier.index_unit_out) > Izero
            lastHub = carrier.index_unit_out[1][1]
            indexes_out[lastHub] += Ione
            indexFirst = Ione
            indexLast = Ione
            for vector in carrier.index_unit_out
                Nh = vector[1]
                Nu = vector[2]
                Ni = vector[3]
                if lastHub == Nh
                    indexLast += Ione
                else
                    indexes_out[lastHub]+= Ione
                    @constraint(model,sum(variables.hubs[lastHub].units[carrier.index_unit_out[i][2]].out[carrier.index_unit_out[i][3],j] for i=indexFirst:indexLast) == variables.hubs[lastHub].P_produced[indexes_out[lastHub],j])
                    lastHub = Nh
                    indexLast += Ione
                    indexFirst = indexLast
                end
                for j = 1:Nstep
                    @constraint(model,sum(variables.hubs[lastHub].units[carrier.index_unit_out[i][2]].out[carrier.index_unit_out[i][3],j] for i=indexFirst:length(carrier.index_unit_out)) == variables.hubs[lastHub].P_produced[indexes_out[lastHub],j])
                end
            end
        end
    end

    for hub in variables.hubs
        for j = 1:Nstep
            for p in hub.P_produced[:,j]
                @constraint(model, p == 1e5)
            end
        end
    end

    @objective(model, Min,sum(sum(sum(variables.hubs[j].P_purchased[k,i] for k=1:length(variables.hubs[j].P_purchased[:,i])) for j=1:length(MCN.hubs)) for i=1:Nstep))
    optimize!(model)
    println("results !!!!!!!!!!!!!!!")
    for hub in variables.hubs
        for v in hub.P_purchased
            println(JuMP.value(v))
        end
        println("results (units) !!!!!!!!!!!!!!!")
        for u in hub.units
            for i in u.in
                println(JuMP.value(i))
            end
            for i in u.out
                println(JuMP.value(i))
            end
        end
    end


    return model
end =#

end # module Hubs
