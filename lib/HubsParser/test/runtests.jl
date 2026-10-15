using HubsParser
using Test

const STORAGE_MODEL = raw"""
# A quote-free Hubs model
[model]
id = battery
kind = storage

[parameters]
existing_power = { unit = MW, default = 0.0 }
charge_efficiency = { default = 1.0 }

[variables]
@inlet p_charge = { carrier = electricity }
@outlet p_discharge = { carrier = electricity }
energy = { unit = MWh, lower = 0.0 }
power_added = { unit = MW, axes = [], lower = 0.0 }

[expressions]
capex = specific_capex * power_added;
variable_om(t) = variable_cost(t) * p_charge(t);

[equations]
charge_limit = p_charge(t) <= existing_power + power_added;

@boundary(drop)
energy_balance =
    energy(t + 1) ~ energy(t)
    + duration(t) * charge_efficiency * p_charge(t)
    - duration(t) * p_discharge(t) / discharge_efficiency
;

[objective]
minimize =
    sum_components(annualize(capex, discount_rate, lifetime))
    + sum_t(duration(t) * weight(t) * sum_components(variable_om(t)))
;
"""

@testset "Hubs model parser" begin
    document = parse_document(STORAGE_MODEL; source="battery.hubs")
    @test length(document.sections) == 6

    model = section(document, :model)
    @test declaration(model, :id).value isa IdentifierExpr
    @test declaration(model, :id).value.parts == [:battery]

    variables = section(document, :variables)
    charge = declaration(variables, :p_charge)
    @test only(charge.annotations).name == :inlet
    @test charge.value isa MapExpr
    @test first(charge.value.entries).first == :carrier

    expressions = section(document, :expressions)
    @test declaration(expressions, :variable_om).indices == [:t]

    equations = section(document, :equations)
    balance = declaration(equations, :energy_balance)
    @test only(balance.annotations).name == :boundary
    @test only(only(balance.annotations).arguments).parts == [:drop]
    @test balance.value isa BinaryExpr
    @test balance.value.operator == :~

    objective = declaration(section(document, :objective), :minimize)
    @test objective.value isa BinaryExpr
    @test objective.value.operator == :+
end

@testset "Expression precedence" begin
    expression = parse_expression("a + b * c ^ 2")
    @test expression isa BinaryExpr
    @test expression.operator == :+
    @test expression.right.operator == :*
    @test expression.right.right.operator == :^

    map = parse_expression("{ carrier = electricity, axes = [time], lower = -1.0 }")
    @test map isa MapExpr
    @test map.entries[2].second isa ArrayExpr
    @test map.entries[3].second isa UnaryExpr
end

@testset "Parser diagnostics" begin
    error = try
        parse_document("[equations]\nbalance = x(t) ~ y(t)"; source="broken.hubs")
        nothing
    catch caught
        caught
    end
    @test error isa ParseError
    @test occursin("expected ';'", sprint(showerror, error))

    @test_throws ParseError parse_document("value = 1")
    @test_throws ParseError parse_expression("a + ?")
end
