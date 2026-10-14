
using XLSX, Plots, CSV, JuMP, MAT, HiGHS

# --------------------------------------------------------------------------- #
# # # # # # # # #<=|Defining Time steps and Number of Hubs|=># # # # # # # # #  
# --------------------------------------------------------------------------- #
Nt = 168; # Number of hours / time steps
MCN = Hubs.MultiCarrierNetwork(); # Defining the multi carrier energy network
MCN.Nsteps = Nt; # Defining number of time steps
Hubs.addEnergyHubs(MCN, 3); # Defining number of Hubs


Desal_Fake_Hub2 = Hubs.ConversionUnitTemplate("Desal_Fake_Hub2", ["PotableWater"], ["PotableWater"], 1.0, [1.0], [1.0], Pmax_out=[0.0])
Desal_Fake_Hub3 = Hubs.ConversionUnitTemplate("Desal_Fake_Hub3", ["PotableWater"], ["PotableWater"], 1.0, [1.0], [1.0], Pmax_out=[0.0])

Hubs.addUnitFromTemplate(MCN, Desal_Fake_Hub2, 2)
Hubs.addUnitFromTemplate(MCN, Desal_Fake_Hub3, 3)

# --------------------------------------------------------------------------- #
#<=|Defining systems' capacities, loads, Efficiencies, COPs and Coefficients|=># 
# --------------------------------------------------------------------------- #

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# Hub1 - Renewable Energy# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

Power_Max_FC_Hub1 = 1.0e7; # (kW) Maximum FC electrical production
Eff_FC_Tot_Hub1 = 0.75; # (%) FC total efficiency
Eff_FC_Elec_Hub1 = 0.50; # (%) FC electrical efficiency
FC_Hub1 = Hubs.ConversionUnitTemplate("FC_Hub1", ["H2_HP"], ["Electricity", "Heat_HT"], Eff_FC_Tot_Hub1, [1.0], [Eff_FC_Elec_Hub1 / Eff_FC_Tot_Hub1, 1 - Eff_FC_Elec_Hub1 / Eff_FC_Tot_Hub1], Pmax_out=[Power_Max_FC_Hub1, 0.0], CapitalCost=1.0, MOCost=2.0)
Hubs.addUnitFromTemplate(MCN, FC_Hub1, 1)

Power_Max_Electrolyzer_Hub1 = 1.5e7; # (kW) Maximum electrolyzer electrical power
Eff_Electrolyzer_Hub1 = 0.80; # (%) Electrolyzer H2 production efficiency
Electrolyzer_Hub1 = Hubs.ConversionUnitTemplate("Electrolyzer_Hub1", ["Electricity"], ["H2_LP"], Eff_Electrolyzer_Hub1, [1.0], [1.0], Pmax_out=[Power_Max_Electrolyzer_Hub1])
Hubs.addUnitFromTemplate(MCN, Electrolyzer_Hub1, 1)

Production_Max_Desalination_Hub1 = 0.10 * 1e8; # (m3/s) Maximum distilled water production by thermal desalination                                      
Coef_Desalination_Hub1 = 1 / 15 * 1e4; # (m3/kWh) Thermal desalination production coefficienct
Desalination_Hub1 = Hubs.ConversionUnitTemplate("Desalination_Hub1", ["Heat_HT"], ["PotableWater"], Coef_Desalination_Hub1, [1.0], [1.0], Pmax_in=[Production_Max_Desalination_Hub1 / Coef_Desalination_Hub1])
Hubs.addUnitFromTemplate(MCN, Desalination_Hub1, 1)

Volume_Max_waterStorage = 400000.0; # (m3) Maximum distilled water storage capacity
Hubs.addStorages(MCN, 1, "PotableWater", Volume_Max_waterStorage, Volume_Max_waterStorage, efficiency=1.0)

#$$Correct check efficiency
Power_Max_Compressor_Hub1 = Power_Max_Electrolyzer_Hub1; # (kw) Maximum compressor power
Eff_Compressor_Hub1 = 0.80; # (%) Eficiency of the H2 compressor
Compressor_Hub1 = Hubs.ConversionUnitTemplate("Compressor_Hub1", ["Electricity", "H2_LP"], ["H2_HP"], Eff_Compressor_Hub1, [1 - Eff_Compressor_Hub1, Eff_Compressor_Hub1], [1.0], Pmax_out=[Power_Max_Compressor_Hub1 / Eff_Compressor_Hub1])
Hubs.addUnitFromTemplate(MCN, Compressor_Hub1, 1)


Energy_Max_HydrogenStorage_Hub1 = 1.5e7; # (kWh) Maximum H2 storage capacity
Eff_HydrogenStorage_Hub1 = 0.97; # (%) H2 storage efficiency
Hubs.addStorages(MCN, 1, "H2_HP", Energy_Max_HydrogenStorage_Hub1, Energy_Max_HydrogenStorage_Hub1, efficiency=Eff_HydrogenStorage_Hub1)

Energy_Max_CAES_Hub1 = 1.0e7; # (kWh) Maximum CAES capacity
Eff_CAES_Hub1 = 0.65; # (%) CAES efficiency
CAES2Elec_Hub1 = Hubs.ConversionUnitTemplate("CAES2Elec_Hub1", ["CAES"], ["Electricity"], 1.0, [1.0], [1.0], Pmax_out=[Energy_Max_CAES_Hub1])
Elec2CAES_Hub1 = Hubs.ConversionUnitTemplate("Elec2CAES_Hub1", ["Electricity"], ["CAES"], 1.0, [1.0], [1.0], Pmax_out=[Energy_Max_CAES_Hub1])
Hubs.addUnitFromTemplate(MCN, CAES2Elec_Hub1, 1)
Hubs.addUnitFromTemplate(MCN, Elec2CAES_Hub1, 1)
Hubs.addStorages(MCN, 1, "CAES", Energy_Max_CAES_Hub1, Energy_Max_CAES_Hub1, efficiency=Eff_CAES_Hub1)
Hubs.addPorts(MCN, 1, "CAES", :returnPorts, 0.0, 1.0e100)


Energy_Max_Pumpedhydro_Hub1 = 2.0e7; # (kWh) Maximum Pumped hydro storage capacity
Eff_Pumpedhydro_Hub1 = 0.80; # (%) Pumped hydro storage efficiency
Pumpedhydro2Elec_Hub1 = Hubs.ConversionUnitTemplate("Pumpedhydro2Elec_Hub1", ["Pumpedhydro"], ["Electricity"], 1.0, [1.0], [1.0], Pmax_out=[Energy_Max_Pumpedhydro_Hub1])
Elec2Pumpedhydro_Hub1 = Hubs.ConversionUnitTemplate("Elec2Pumpedhydro_Hub1", ["Electricity"], ["Pumpedhydro"], 1.0, [1.0], [1.0], Pmax_out=[Energy_Max_Pumpedhydro_Hub1])
Hubs.addUnitFromTemplate(MCN, Pumpedhydro2Elec_Hub1, 1)
Hubs.addUnitFromTemplate(MCN, Elec2Pumpedhydro_Hub1, 1)
Hubs.addStorages(MCN, 1, "Pumpedhydro", Energy_Max_Pumpedhydro_Hub1, Energy_Max_Pumpedhydro_Hub1, efficiency=Eff_Pumpedhydro_Hub1)
Hubs.addPorts(MCN, 1, "Pumpedhydro", :returnPorts, 0.0, 1.0e100)

Area_PVT_Hub1 = 5.0e2; # (m2) PVT area
Eff_PVT_Elec_Hub1 = 0.10; # (%) PVT electrical efficiency
Eff_PVT_Heating_Hub1 = 0.40; # (%) PVT thermal efficiency
Solar_Radiation_Hub1 = convert(Vector{Float64}, XLSX.readxlsx(joinpath(@__DIR__, "Radiation.xlsx"))["Radiation"][:][1:Nt, 1]); # (kW/m2) Solar radiation
PVT_Hub1 = Hubs.ConversionUnitTemplate("PVT_Hub1", ["SolarRadiation"], ["Electricity", "Heat_LT"], (Eff_PVT_Elec_Hub1 + Eff_PVT_Heating_Hub1), [1.0], [Eff_PVT_Elec_Hub1 / (Eff_PVT_Elec_Hub1 + Eff_PVT_Heating_Hub1), Eff_PVT_Heating_Hub1 / (Eff_PVT_Elec_Hub1 + Eff_PVT_Heating_Hub1)], Pmax_in=[max(Solar_Radiation_Hub1...) * Area_PVT_Hub1])
Hubs.addUnitFromTemplate(MCN, PVT_Hub1, 1)

Coef_WT_Hub1 = 1.0e2; # (kW*s3/m3) The coefficient represents (π/2 * r²  * ρ * η) in the WT power fodmula = Coef * v³
Wind_Speed3_Hub1 = convert(Vector{Float64}, XLSX.readxlsx(joinpath(@__DIR__, "WindSpeed3.xlsx"))["WindSpeed3"][:][1:Nt, 1]); # (m3/s3) Wind speed ^3 with cut-in of 3m/s
WT_Hub1 = Hubs.ConversionUnitTemplate("WT_Hub1", ["Wind"], ["Electricity"], Coef_WT_Hub1, [1.0], [1.0], Pmax_out=[max(Wind_Speed3_Hub1...) * Coef_WT_Hub1])
Hubs.addUnitFromTemplate(MCN, WT_Hub1, 1)

ThermalDistribution_Hub1 = Hubs.ConversionUnitTemplate("ThermalDistribution_Hub1", ["Heat_HT"], ["Heat_LT"], 1.0, [1.0], [1.0], Pmax_out=[1.0e10])
Hubs.addUnitFromTemplate(MCN, ThermalDistribution_Hub1, 1)


Hubs.addPorts(MCN, 1, "SolarRadiation", :purchasePorts, 0.0, Solar_Radiation_Hub1 .* Area_PVT_Hub1)
Hubs.addPorts(MCN, 1, "Wind", :purchasePorts, 0.0, Wind_Speed3_Hub1)

Hubs.addPorts(MCN, 1, "Electricity", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 1, "Heat_HT", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 1, "Heat_LT", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 1, "H2_HP", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 1, "H2_LP", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 1, "PotableWater", :returnPorts, 0.0, 1.0e100)
# Hubs.addPorts(MCN, 1,  "CAES", :returnPorts, 0.0, 1.0e100)
# Hubs.addPorts(MCN, 1,  "Pumpedhydro", :returnPorts, 0.0, 1.0e100)

Hubs.addPorts(MCN, 1, "Heat_LT", :networkPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 1, "Heat_HT", :networkPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 1, "Electricity", :networkPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 1, "PotableWater", :networkPorts, 0.0, 1.0e100)

Hubs.addPorts(MCN, 1, "Heat_LT", :sellPorts, 0.0, 1.0e100)

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# Hub2 - Residential# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

Power_Max_GasBoiler_Hub2 = 1.0e7; # (kW) Maximum Gas boiler production
Eff_GasBoiler_Hub2 = 0.90; # (%) Gas boiler efficiency
GasBoiler_Hub2 = Hubs.ConversionUnitTemplate("GasBoiler_Hub2", ["CH4"], ["Heat_LT"], Eff_GasBoiler_Hub2, [1.0], [1.0], Pmax_out=[Power_Max_GasBoiler_Hub2])
Hubs.addUnitFromTemplate(MCN, GasBoiler_Hub2, 2)

Power_Max_In_HP_LT_Hub2 = 1.0e7; # (kW) Maximum low temperature HP input power
COP_HP_LT_Heating_Hub2 = 4.00; # (%) COP of low temperature HP in heating mode
# COP_HP_LT_Cooling_Hub2              = 5.00                                          ; # (%) COP of low temperature HP in cooling mode
HP_LT_Heating_Hub2 = Hubs.ConversionUnitTemplate("HP_LT_Heating_Hub2", ["Electricity"], ["Heat_LT"], COP_HP_LT_Heating_Hub2, [1.0], [1.0], Pmax_in=[Power_Max_In_HP_LT_Hub2])
# HP_LT_Cooling_Hub2                  = Hubs.ConversionUnitTemplate("HP_LT_Cooling_Hub2", ["Electricity"], ["Cool"], COP_HP_LT_Cooling_Hub2, [1.0], [1.0], Pmax_in = [Power_Max_In_HP_LT_Hub2])
Hubs.addUnitFromTemplate(MCN, HP_LT_Heating_Hub2, 2)
# Hubs.addUnitFromTemplate(MCN, HP_LT_Cooling_Hub2, 2)

Power_Max_In_HP_HT_Hub2 = 5.0e7; # (kW) Maximum high temperature HP input power
COP_HP_HT_Heating_Hub2 = 4.00; # (%) COP of high temperature HP in heating mode (Only running mode)
HP_HT_Heating_Hub2 = Hubs.ConversionUnitTemplate("HP_HT_Heating_Hub2", ["Electricity"], ["Heat_HT"], COP_HP_HT_Heating_Hub2, [1.0], [1.0], Pmax_in=[Power_Max_In_HP_HT_Hub2])
Hubs.addUnitFromTemplate(MCN, HP_HT_Heating_Hub2, 2)

# Power_Max_In_ABChiller_Hub2         = 3.00                                          ; # (kW) Maximum absorption power
# COP_ABChiller_Hub2                  = 1.00                                          ; # (%) COP of absorption chiller
# ABChiller_Hub2                      = Hubs.ConversionUnitTemplate("ABChiller_Hub2", ["Heat_HT"], ["Cool"], COP_ABChiller_Hub2, [1.0], [1.0], Pmax_in = [Power_Max_In_ABChiller_Hub2])
# Hubs.addUnitFromTemplate(MCN, ABChiller_Hub2, 2)

Power_Max_CHP_Hub2 = 3.0e6; # (kW) Maximum CHP electrical power
Eff_CHP_Elec_Hub2 = 0.35; # (%) CHP electrical efficiency
Eff_CHP_Tot_Hub2 = 0.70; # (%) CHP total efficiency
CHP_Hub2 = Hubs.ConversionUnitTemplate("CHP_Hub2", ["CH4"], ["Electricity", "Heat_HT"], Eff_CHP_Tot_Hub2, [1.0], [Eff_CHP_Elec_Hub2 / Eff_CHP_Tot_Hub2, 1 - Eff_CHP_Elec_Hub2 / Eff_CHP_Tot_Hub2], Pmax_out=[Power_Max_CHP_Hub2, 0.0])
Hubs.addUnitFromTemplate(MCN, CHP_Hub2, 2)

Energy_Max_ThermalStorage_Hub2 = 2.0e7; # (kWh) Maximum Thermal storage capacity
Eff_ThermalStorage_Hub2 = 0.80; # (%) Thermal storage efficiency
Hubs.addStorages(MCN, 2, "Heat_LT", Energy_Max_ThermalStorage_Hub2, Energy_Max_ThermalStorage_Hub2, efficiency=Eff_ThermalStorage_Hub2)

Energy_Max_Battery_Hub2 = 1.5e7; # (kWh) Maximum Battery capacity
Eff_Battery_Hub2 = 0.85; # (%) Battery efficiency
Hubs.addStorages(MCN, 2, "Electricity", Energy_Max_Battery_Hub2, Energy_Max_Battery_Hub2, efficiency=Eff_Battery_Hub2)

Delta_Tin_Tout_House_Hub2 = convert(Vector{Float64}, XLSX.readxlsx(joinpath(@__DIR__, "Tin_Tout_House.xlsx"))["Tin_Tout"][:][1:Nt, 1]); # (K) Inside and outside temperature difference (8h00-22h00 Tin=20 else Tin=19)
Coef_Load_Heat_House_Hub2 = 230 / sum(Delta_Tin_Tout_House_Hub2); # (kW/m2/K) Energy consumption for heating per m2 which is devided into average DeltaTinTout
Area_House_Hub2 = 20 * 5000.0; # (m2) Houses' area in the Hub2
Power_Load_Heat_LT_Hub2 = Delta_Tin_Tout_House_Hub2 .* Coef_Load_Heat_House_Hub2 .* Area_House_Hub2; # (kW) Maximum thermal load power
Hubs.addLoads(MCN, 2, "Heat_LT", Power_Load_Heat_LT_Hub2)

Power_Load_Elec_Hub2_PerPerson = convert(Vector{Float64}, XLSX.readxlsx(joinpath(@__DIR__, "Load_Elec_House.xlsx"))["Load_Elec_House"][:][1:Nt, 1]); # (kW) Electrical load power per person (site data/France population 69390000)
Population_Hub2 = Area_House_Hub2 / 20; # Numper of person lives in Hub2 which is imagine 20m2 per person
Power_Load_Elec_Hub2 = Power_Load_Elec_Hub2_PerPerson .* Population_Hub2;# (kW) Total electrical load in Hub2
Hubs.addLoads(MCN, 2, "Electricity", Power_Load_Elec_Hub2)

Load_Daily_PotableWater_Hub2 = Population_Hub2 * 352; # (L/day) Water consumption
PotableWater_PartialUse_Hub2 = convert(Vector{Float64}, XLSX.readxlsx(joinpath(@__DIR__, "Load_PotableWater_House.xlsx"))["Load_PotableWater_House"][:][1:Nt, 1]); # (%) Hourly percentage of total daily water consumption
Load_PotableWater_Hub2 = PotableWater_PartialUse_Hub2 .* Load_Daily_PotableWater_Hub2; # (L) Potable water load                                            
Hubs.addLoads(MCN, 2, "PotableWater", Load_PotableWater_Hub2)

ThermalDistribution_Hub2 = Hubs.ConversionUnitTemplate("ThermalDistribution_Hub2", ["Heat_HT"], ["Heat_LT"], 1.0, [1.0], [1.0], Pmax_out=[1.0e100, 0.0])
Hubs.addUnitFromTemplate(MCN, ThermalDistribution_Hub2, 2)

Hubs.addPorts(MCN, 2, "CH4", :purchasePorts, 0.0, 1.0e100, 10.0)

Hubs.addPorts(MCN, 2, "Electricity", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 2, "Heat_HT", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 2, "Heat_LT", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 2, "PotableWater", :returnPorts, 0.0, 1.0e100)

Hubs.addPorts(MCN, 2, "Heat_LT", :networkPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 2, "Heat_HT", :networkPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 2, "Electricity", :networkPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 2, "PotableWater", :networkPorts, 0.0, 1.0e100)

Hubs.addPorts(MCN, 2, "Heat_LT", :sellPorts, 0.0, 1.0e100)
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
# Hub3 - Industrial# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 
Power_Max_Furnace_Hub3 = 1.5e7; # (kW) Maximum Gas furnace production
Eff_Furnace_Hub3 = 0.85; # (%) Gas furnace efficiency
Furnace_Hub3 = Hubs.ConversionUnitTemplate("Furnace_Hub3", ["CH4"], ["Heat_HT"], Eff_Furnace_Hub3, [1.0], [1.0], Pmax_out=[Power_Max_Furnace_Hub3])
Hubs.addUnitFromTemplate(MCN, Furnace_Hub3, 3)

Power_Max_Furnace_Waste_Hub3 = 1.5e7; # (kW) Maximum Gas furnace production
Eff_Furnace_Waste_Hub3 = 0.85; # (%) Gas furnace efficiency
Furnace_Waste_Hub3 = Hubs.ConversionUnitTemplate("Furnace_Waste_Hub3", ["Waste"], ["Heat_HT"], Eff_Furnace_Waste_Hub3, [1.0], [1.0], Pmax_out=[Power_Max_Furnace_Waste_Hub3])
Hubs.addUnitFromTemplate(MCN, Furnace_Waste_Hub3, 3)

Energy_Max_WasteStorage_Hub2 = 2.0e7; # (kWh) Maximum Thermal storage capacity
Eff_WasteStorage_Hub2 = 0.80; # (%) Thermal storage efficiency
Hubs.addStorages(MCN, 2, "Waste", Energy_Max_WasteStorage_Hub2, Energy_Max_WasteStorage_Hub2, efficiency=Eff_WasteStorage_Hub2)

Power_Max_In_HP_HT_Hub3 = 1.0e7; # (kW) Maximum high temperature HP input power
COP_HP_HT_Heating_Hub3 = 4.00; # (%) COP of high temperature HP in heating mode (Only running mode)
HP_HT_Heating_Hub3 = Hubs.ConversionUnitTemplate("HP_HT_Heating_Hub3", ["Electricity"], ["Heat_HT"], COP_HP_HT_Heating_Hub3, [1.0], [1.0], Pmax_in=[Power_Max_In_HP_HT_Hub3])
Hubs.addUnitFromTemplate(MCN, HP_HT_Heating_Hub3, 3)

# Power_Max_In_ABChiller_Hub3         = 1.00                                          ; # (kW) COP of absorption chiller input power
# COP_ABChiller_Hub3                  = 0.95                                          ; # (%) COP of absorption chiller
# ABChiller_Hub3                      = Hubs.ConversionUnitTemplate("ABChiller_Hub3", ["Heat_HT"], ["Cool"], COP_ABChiller_Hub3, [1.0], [1.0], Pmax_in = [Power_Max_In_ABChiller_Hub3])
# Hubs.addUnitFromTemplate(MCN, ABChiller_Hub3, 3)

Power_Max_CHP_Hub3 = 5e6; # (kW) Maximum CHP electrical power
Eff_CHP_Elec_Hub3 = 0.38; # (%) CHP electrical efficiency
Eff_CHP_Tot_Hub3 = 0.75; # (%) CHP total efficiency
CHP_Hub3 = Hubs.ConversionUnitTemplate("CHP_Hub3", ["CH4"], ["Electricity", "Heat_HT"], Eff_CHP_Tot_Hub3, [1.0], [Eff_CHP_Elec_Hub3 / Eff_CHP_Tot_Hub3, 1 - Eff_CHP_Elec_Hub3 / Eff_CHP_Tot_Hub3], Pmax_out=[Power_Max_CHP_Hub3, 0.0])
Hubs.addUnitFromTemplate(MCN, CHP_Hub3, 3)

Delta_Tin_Tout_Office_Hub3 = convert(Vector{Float64}, XLSX.readxlsx(joinpath(@__DIR__, "Tin_Tout_Office.xlsx"))["Tin_Tout"][:][1:Nt, 1]); # (K) Inside and outside temperature difference (7h00-19h00 Tin=20 else and weekend Tin=15)
Coef_Load_Heat_Office_Hub3 = 230 / sum(Delta_Tin_Tout_Office_Hub3); # (kW/m2/K) Energy consumption for heating per m2 which is devided into average DeltaTinTout
Area_Office_Hub3 = 10 * 2500; # (m2) Offices' area in the Hub3
Power_Load_Heat_LT_Hub3 = Delta_Tin_Tout_Office_Hub3 .* Coef_Load_Heat_Office_Hub3 .* Area_Office_Hub3; # (kW) Maximum thermal load power
Hubs.addLoads(MCN, 3, "Heat_LT", Power_Load_Heat_LT_Hub3)

Power_Load_Elec_Hub3_PerPerson = Power_Load_Elec_Hub2_PerPerson .* 0.3; # (kW) Electrical load power per person (site data/France population 69390000)
Population_Office_Hub3 = Area_Office_Hub3 / 10; # Numper of person lives in Hub2 which is imagine 20m2 per person
Power_Load_Elec_Office_Hub3 = Power_Load_Elec_Hub3_PerPerson .* Population_Office_Hub3;# (kW) Total electrical load in Hub2

Load_Elec_PerIndustry_Hub3 = convert(Vector{Float64}, XLSX.readxlsx(joinpath(@__DIR__, "Load_Elec_Industrial.xlsx"))["Load_Elec_Industrial"][:][1:Nt, 1]); # (kW) Electrical load power for one industry
NumberofIndustries_Elec_Hub3 = 10.0;
Power_Load_Elec_Industry_Hub3 = Load_Elec_PerIndustry_Hub3 .* NumberofIndustries_Elec_Hub3; # (kW) Electrical load in Hub3

Power_Load_Elec_Hub3 = Power_Load_Elec_Industry_Hub3 + Power_Load_Elec_Office_Hub3;
Hubs.addLoads(MCN, 3, "Electricity", Power_Load_Elec_Hub3)

Load_Heat_PerIndustry_Hub3 = convert(Vector{Float64}, XLSX.readxlsx(joinpath(@__DIR__, "Load_Heat_Industrial.xlsx"))["Load_Heat_Industrial"][:][1:Nt, 1]); # (kW) Electrical load power for one industry
NumberofIndustries_Heat_Hub3 = 15.0;
Power_Load_Heat_HT_Hub3 = Load_Heat_PerIndustry_Hub3 .* NumberofIndustries_Heat_Hub3; # (kW) Electrical load in Hub3
Hubs.addLoads(MCN, 3, "Heat_HT", Power_Load_Heat_HT_Hub3)

Load_Daily_PotableWater_Hub3 = Population_Office_Hub3 * 352 * 0.59; # (L/day) Water consumption - The precentage of the water is generally is used by offices compared to houses was 0.59
PotableWater_PartialUse_Hub3 = convert(Vector{Float64}, XLSX.readxlsx(joinpath(@__DIR__, "Load_PotableWater_Office.xlsx"))["Load_PotableWater_Office"][:][1:Nt, 1]); # (%) Hourly percentage of total daily water consumption
Load_PotableWater_Hub3 = PotableWater_PartialUse_Hub3 .* Load_Daily_PotableWater_Hub3; # (L) Potable water load                                            
Hubs.addLoads(MCN, 3, "PotableWater", Load_PotableWater_Hub3)

ThermalDistribution_Hub3 = Hubs.ConversionUnitTemplate("ThermalDistribution_Hub3", ["Heat_HT"], ["Heat_LT"], 1.0, [1.0], [1.0], Pmax_out=[1.0e10])
Hubs.addUnitFromTemplate(MCN, ThermalDistribution_Hub3, 3)

Hubs.addPorts(MCN, 3, "CH4", :purchasePorts, 0.0, 1.0e100, 10.0)
Hubs.addPorts(MCN, 3, "Waste", :purchasePorts, 1.5e5, 1.5e5, 1.0)

Hubs.addPorts(MCN, 3, "Electricity", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 3, "Heat_HT", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 3, "Heat_LT", :returnPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 3, "Waste", :returnPorts, 0.0, 1.0e100)

Hubs.addPorts(MCN, 3, "Heat_LT", :networkPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 3, "Heat_HT", :networkPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 3, "Electricity", :networkPorts, 0.0, 1.0e100)
Hubs.addPorts(MCN, 3, "PotableWater", :networkPorts, 0.0, 1.0e100)

Hubs.addPorts(MCN, 3, "Heat_LT", :sellPorts, 0.0, 1.0e100)
# # # # # # # --------------------------------------------------- # # # # # # #
#<=<=<=<=<=<=|-|=>=>=>=>=>=># 
# # # # # # # --------------------------------------------------- # # # # # # #
Hubs.fillIndexunitIn(MCN)
Hubs.updateCarriersNumbers(MCN)
Model = Hubs.Matrices(MCN)
OptimizedModel = Hubs.constructModel(Model, HiGHS.Optimizer)
set_silent(OptimizedModel)
Results = Hubs.solve(OptimizedModel)

Unit_Inputs = Hubs.allunitsInlets(MCN) # retourne les n° des hubs, les noms des unités et les noms de vecteurs des entrées des unités
Unit_Outputs = Hubs.allunitsOutlets(MCN) # retourne les n° des hubs, les noms des unités et les noms de vecteurs des sorties des unités
Hubs_Inputs = Hubs.allHubsPurchases(MCN, Model) # retourne les n° des hubs et les noms de vecteurs des entrées (payantes) des hubs
Hubs_Exports = Hubs.allHubsExports(MCN, Model) # retourne les n° des hubs et les noms de vecteurs des sortie payantes des hubs
Loads = Hubs.allHubsLoads(MCN, Model) # retourne les n° des hubs et les noms de vecteurs des charges dans les hubs
Storages = Hubs.allStorages(MCN, Model) # retourne les n° des hubs et les noms de vecteurs des stocks dans les hubs
Network_Outputs = Hubs.allNetworkOutlets(MCN, Model) # retourne les n° des hubs et les noms de vecteurs des sorties réseau
Returns = Hubs.allReturns(MCN, Model) # retourne les n° des hubs et les noms de vecteurs des retours dans les hubs

# r = Hubs.inletIndex(MCN,Model,1,"PV","SolarRadiation")
# r = Hubs.outletIndex(MCN,Model,1,"Desalination_Hub1","PotableWater")
# plot(Results.Xo[4,:])

Unit_I_Names = Unit_Inputs[2];
Input_Names = Unit_Inputs[3];

Unit_O_Names = Unit_Outputs[2];
Output_Names = Unit_Outputs[3];

Load_Names = Loads[2];

@show termination_status(OptimizedModel)

@testset "ECOS numerical regression" begin
    @test termination_status(OptimizedModel) == JuMP.MOI.OPTIMAL
    @test objective_value(OptimizedModel) ≈ 2.9721639445687572e10 rtol = 1.0e-9

    expected = Dict(
        :Xi => ((24, 168), 4.103541274673853e9, 4.103541274673853e9, 4.020318745660811e16, 0.0, 1.3157894736842105e7),
        :Xo => ((27, 168), 3.3336870066022735e9, 3.3336870066022735e9, 1.64293825355407e16, 0.0, 7.467743026229233e6),
        :Xui => ((23, 168), 4.103541274673853e9, 4.103541274673853e9, 4.020318745660811e16, 0.0, 1.3157894736842105e7),
        :Xuo => ((23, 168), 3.333687006602276e9, 3.333687006602276e9, 2.5539652199377144e16, 0.0, 9.868421052631577e6),
        :Xhi => ((17, 168), 4.1035412746738524e9, 4.1035412746738524e9, 4.020318745660811e16, 0.0, 1.3157894736842105e7),
        :Xho => ((16, 168), 3.3336870066022763e9, 3.3336870066022763e9, 1.6637961012299894e16, 0.0, 7.467743026229233e6),
        :Xp => ((5, 168), 2.998626707044714e9, 2.998626707044714e9, 3.2891202551391212e16, 0.0, 1.3157894736842105e7),
        :Xs => ((4, 168), 1.077648686000864e9, 1.077648686000864e9, 6.959644013212426e15, 0.0, 7.309705944999548e6),
        :Xst_charge => ((8, 168), 0.0, 0.0, 0.0, 0.0, 0.0),
        :Xst_discharge => ((8, 168), 0.0, 0.0, 0.0, 0.0, 0.0),
        :XEst => ((8, 168), 0.0, 0.0, 0.0, 0.0, 0.0),
        :Xn => ((13, 168), 2.214255800936371e-8, 3.1147464815879254e9, 1.4165696880011036e16, -4.995881246711578e6, 4.995921052631578e6),
        :Xni => ((17, 168), 1.1049145676291437e9, 1.1049145676291437e9, 7.311984905216836e15, 0.0, 7.467743026229233e6),
    )

    for (field, reference) in expected
        values = getfield(Results, field)
        @test size(values) == reference[1]
        @test sum(values) ≈ reference[2] rtol = 1.0e-9 atol = 1.0e-5
        @test sum(abs, values) ≈ reference[3] rtol = 1.0e-9 atol = 1.0e-5
        @test sum(abs2, values) ≈ reference[4] rtol = 1.0e-9 atol = 1.0e-5
        @test minimum(values) ≈ reference[5] rtol = 1.0e-9 atol = 1.0e-5
        @test maximum(values) ≈ reference[6] rtol = 1.0e-9 atol = 1.0e-5
    end
end

ni = size(Results.Xi)[1];
no = size(Results.Xo)[1];

file = matopen(joinpath(mktempdir(), "matfile.mat"), "w")

for i in 1:ni
    write(file, "IN_" * Unit_I_Names[i] * "__" * Input_Names[i], Results.Xi[i, :])
end

for i in 1:no
    write(file, "OUT_" * Unit_O_Names[i] * "__" * Output_Names[i], Results.Xo[i, :])
end

write(file, "Load_Elec", Power_Load_Elec_Hub2 + Power_Load_Elec_Hub3)
write(file, "Load_Heat_LT", Power_Load_Heat_LT_Hub2 + Power_Load_Heat_LT_Hub3)
write(file, "Load_Heat_HT", Power_Load_Heat_HT_Hub3)

write(file, "Load_PotableWater", Load_PotableWater_Hub2 + Load_PotableWater_Hub3)

close(file)


# let
#     n                                    = size(Results.Xi)[1];
# 	PP = []
# 	for i in 1:n
# 		P = plot(Results.Xi[i,:], title=Unit_Names[i]*"-"*Input_Names[i])
# 		push!(PP, P)
# 	end
# 	plot(PP...; size = default(:size) .* (1, n), layout = (n, 1), left_margin = 5Plots.mm)
# end

