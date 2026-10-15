using HubsParser

const ML = Hubs.ModelLanguage
const HP = HubsParser

@testset "Hubs model language semantics" begin
    model = ML.load_component(joinpath(@__DIR__, "models", "battery.hubs"))
    @test model.id == :battery
    @test model.kind == :storage
    @test length(model.parameters) == 9
    @test length(model.variables) == 5
    @test length(model.equations) == 5
    @test length(model.expressions) == 4
    @test model.objective === nothing

    charge = only(filter(variable -> variable.name == :p_charge, model.variables))
    @test charge.port !== nothing
    @test charge.port.carrier == :electricity
    @test charge.port.direction == Hubs.Domain.Input
    @test charge.axes == [:time]
    @test charge.domain == :continuous
    @test charge.lower.value == 0.0

    energy_added = only(filter(variable -> variable.name == :energy_added, model.variables))
    @test energy_added.port === nothing
    @test isempty(energy_added.axes)

    balance = only(filter(equation -> equation.name == :energy_balance, model.equations))
    @test balance.boundary == :drop
end

@testset "Text model compilation and parameter refresh" begin
    D = Hubs.Domain
    C = Hubs.Compiler
    definition = ML.load_component(joinpath(@__DIR__, "models", "battery.hubs"))
    system = D.HubSystem(steps=3, time_step=0.5)
    D.addCarrier(system, D.Carrier(:electricity; unit=:MW))
    hub = D.addHub(system, D.Hub(:site))
    storage = D.addStorage(
        system,
        hub,
        definition;
        name=:battery_1,
        parameters=(
            existing_power=10.0,
            existing_energy=20.0,
            initial_energy=4.0,
            charge_efficiency=0.9,
            discharge_efficiency=0.8,
            specific_power_capex=100.0,
            specific_energy_capex=50.0,
            lifetime=15.0,
        ),
    )

    library = C.ComponentLibrary()
    compiled = C.compile_linear(system; library)
    component_block = only(block for block in compiled.blocks if block.owner == C.OwnerRef(storage))
    @test length(compiled.variables) == 11
    @test length(component_block) == 12
    @test length(component_block.coefficients) == 27
    @test component_block.rhs[1:3] == fill(10.0, 3)
    @test component_block.rows[end].name == :energy_balance
    @test component_block.rows[end].index == 2
    @test C.templateStatistics(library) == (templates=1, hits=0, misses=1)

    C.compile_linear(system; library)
    @test C.templateStatistics(library) == (templates=1, hits=1, misses=1)

    D.setParameters(system, storage; existing_power=12.0)
    C.refreshParameters(compiled, system)
    @test component_block.rhs[1:3] == fill(12.0, 3)
end

@testset "Study objective and optional component expressions" begin
    battery = ML.load_component(joinpath(@__DIR__, "models", "battery.hubs"))
    flexible_load = ML.lower_component(HP.parse_document(raw"""
    [model]
    id = flexible_load
    kind = process
    [parameters]
    variable_cost = { axes = [time], default = 0.0 }
    [variables]
    @inlet consumption = { carrier = electricity }
    [expressions]
    variable_om(t) = variable_cost(t) * consumption(t);
    [equations]
    nonnegative = consumption(t) >= 0.0;
    """))
    objective = ML.load_objective(joinpath(@__DIR__, "models", "least_cost.objective.hubs"))

    @test objective.objective.sense == :minimize
    @test ML.validate_objective(objective, [battery, flexible_load]) === objective
    @test ML.expression_contributors([battery, flexible_load], :capex) == [battery]
    @test ML.expression_contributors([battery, flexible_load], :variable_om) == [battery, flexible_load]

    misspelled = ML.lower_objective(HP.parse_document(raw"""
    [objective]
    minimize = sum_components(cappex);
    """))
    @test_throws ML.SemanticError ML.validate_objective(misspelled, [battery, flexible_load])
end

@testset "Semantic validation" begin
    missing_carrier = raw"""
    [model]
    id = invalid
    kind = process
    [variables]
    @inlet flow = { }
    [equations]
    balance = flow(t) ~ 0;
    """
    @test_throws ML.SemanticError ML.lower_component(HP.parse_document(missing_carrier))

    role_keyword = raw"""
    [model]
    id = invalid
    kind = process
    [variables]
    flow = { role = state }
    [equations]
    balance = flow(t) ~ 0;
    """
    @test_throws ML.SemanticError ML.lower_component(HP.parse_document(role_keyword))

    invalid_equation = raw"""
    [model]
    id = invalid
    kind = process
    [variables]
    flow = { lower = 0.0 }
    [equations]
    balance = flow(t) + 1;
    """
    @test_throws ML.SemanticError ML.lower_component(HP.parse_document(invalid_equation))

    unknown_reference = raw"""
    [model]
    id = invalid
    kind = process
    [variables]
    flow = { lower = 0.0 }
    [equations]
    balance = flow(t) ~ missing_parameter;
    """
    @test_throws ML.SemanticError ML.lower_component(HP.parse_document(unknown_reference))

    cyclic_expressions = raw"""
    [model]
    id = invalid
    kind = process
    [variables]
    flow = { lower = 0.0 }
    [expressions]
    a = b + 1;
    b = a + 1;
    [equations]
    balance = flow(t) ~ a;
    """
    @test_throws ML.SemanticError ML.lower_component(HP.parse_document(cyclic_expressions))
end
