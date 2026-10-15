module HubsBenchmarkHarness

using Statistics

export BenchmarkResult,
    OperationResult,
    StageResult,
    benchmark_operation,
    benchmark_pipeline,
    benchmark_stage,
    print_comparison,
    print_operation_comparison,
    print_stages

struct BenchmarkResult
    name::String
    build_seconds::Float64
    build_bytes::Int
    optimize_seconds::Float64
    optimize_bytes::Int
    objective::Float64
end

struct OperationResult
    name::String
    seconds::Float64
    bytes::Int
    objective::Float64
end

struct StageResult
    name::String
    seconds::Float64
    bytes::Int
end

function _measure(operation::F, samples::Int) where {F}
    times = Vector{Float64}(undef, samples)
    bytes = Vector{Int}(undef, samples)
    for sample in 1:samples
        GC.gc()
        measurement = @timed operation()
        times[sample] = measurement.time
        bytes[sample] = measurement.bytes
    end
    return median(times), round(Int, median(bytes))
end

"""
    benchmark_pipeline(name, source, compile, solve!, objective; samples=3)

Measure construction and optimization separately. Each optimization sample uses the
artifact constructed in the same sample, so solver state is never reused. `source`
is prepared outside the timed regions and must be safe to compile repeatedly.
"""
function benchmark_pipeline(
    name::AbstractString,
    source,
    compile::C,
    solve!::S,
    objective::O;
    samples::Int=3,
) where {C,S,O}
    samples > 0 || throw(ArgumentError("samples must be positive"))

    # Warm up Julia, JuMP, and the solver before collecting measurements.
    warm = redirect_stdout(devnull) do
        compile(source)
    end
    redirect_stdout(devnull) do
        solve!(warm)
    end

    build_times = Vector{Float64}(undef, samples)
    build_bytes = Vector{Int}(undef, samples)
    optimize_times = Vector{Float64}(undef, samples)
    optimize_bytes = Vector{Int}(undef, samples)
    solved = Ref{Any}()
    for sample in 1:samples
        GC.gc()
        build_measurement = @timed redirect_stdout(devnull) do
            compile(source)
        end
        artifact = build_measurement.value
        build_times[sample] = build_measurement.time
        build_bytes[sample] = build_measurement.bytes

        optimize_measurement = @timed redirect_stdout(devnull) do
            solve!(artifact)
        end
        optimize_times[sample] = optimize_measurement.time
        optimize_bytes[sample] = optimize_measurement.bytes
        solved[] = artifact
    end

    return BenchmarkResult(
        String(name),
        median(build_times),
        round(Int, median(build_bytes)),
        median(optimize_times),
        round(Int, median(optimize_bytes)),
        Float64(objective(solved[])),
    )
end

function benchmark_operation(
    name::AbstractString,
    operation::F,
    objective::O;
    samples::Int=3,
) where {F,O}
    samples > 0 || throw(ArgumentError("samples must be positive"))
    redirect_stdout(devnull) do
        operation()
    end
    result = Ref{Any}()
    seconds, bytes = _measure(samples) do
        result[] = redirect_stdout(devnull) do
            operation()
        end
    end
    return OperationResult(String(name), seconds, bytes, Float64(objective(result[])))
end

function benchmark_stage(name::AbstractString, operation::F; samples::Int=3) where {F}
    samples > 0 || throw(ArgumentError("samples must be positive"))
    redirect_stdout(devnull) do
        operation()
    end
    seconds, bytes = _measure(samples) do
        redirect_stdout(devnull) do
            operation()
        end
    end
    return StageResult(String(name), seconds, bytes)
end

function _print_result(result::BenchmarkResult)
    println(
        rpad(result.name, 14),
        lpad(round(result.build_seconds * 1_000; digits=2), 12),
        lpad(round(result.build_bytes / 2.0^20; digits=2), 13),
        lpad(round(result.optimize_seconds * 1_000; digits=2), 14),
        lpad(round(result.optimize_bytes / 2.0^20; digits=2), 16),
        lpad(round(result.objective; sigdigits=10), 20),
    )
end

function print_comparison(legacy::BenchmarkResult, candidates::BenchmarkResult...)
    println("pipeline          build ms    build MiB    optimize ms    optimize MiB           objective")
    _print_result(legacy)
    for candidate in candidates
        _print_result(candidate)
        println(
            "  vs legacy: build ",
            round(legacy.build_seconds / candidate.build_seconds; digits=2),
            "x, optimize ",
            round(legacy.optimize_seconds / candidate.optimize_seconds; digits=2),
            "x",
        )
    end
    return nothing
end

function print_operation_comparison(legacy::OperationResult, candidate::OperationResult)
    println()
    println("repeated update + solve       time ms       MiB           objective")
    for result in (legacy, candidate)
        println(
            rpad(result.name, 25),
            lpad(round(result.seconds * 1_000; digits=2), 10),
            lpad(round(result.bytes / 2.0^20; digits=2), 10),
            lpad(round(result.objective; sigdigits=10), 20),
        )
    end
    println(
        "  candidate speedup: ",
        round(legacy.seconds / candidate.seconds; digits=2),
        "x",
    )
    return nothing
end

function print_stages(results::StageResult...)
    println()
    println("construction stage              time ms       MiB")
    for result in results
        println(
            rpad(result.name, 31),
            lpad(round(result.seconds * 1_000; digits=2), 9),
            lpad(round(result.bytes / 2.0^20; digits=2), 10),
        )
    end
    return nothing
end

end
