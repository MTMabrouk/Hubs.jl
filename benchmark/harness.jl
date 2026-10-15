module HubsBenchmarkHarness

using Statistics

export BenchmarkResult, benchmark_pipeline, print_comparison

struct BenchmarkResult
    name::String
    compile_seconds::Float64
    compile_bytes::Int
    solve_seconds::Float64
    solve_bytes::Int
    objective::Float64
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

Measure compilation and solution separately. A fresh compiled artifact is used for
each solve sample so solver state is never reused. `source` is prepared outside the
timed regions and must be safe to compile repeatedly.
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

    compile_time, compile_bytes = _measure(samples) do
        redirect_stdout(devnull) do
            compile(source)
        end
    end

    solved = Ref{Any}()
    solve_time, solve_bytes = _measure(samples) do
        artifact = redirect_stdout(devnull) do
            compile(source)
        end
        redirect_stdout(devnull) do
            solve!(artifact)
        end
        solved[] = artifact
    end

    return BenchmarkResult(
        String(name),
        compile_time,
        compile_bytes,
        solve_time,
        solve_bytes,
        Float64(objective(solved[])),
    )
end

function _print_result(result::BenchmarkResult)
    println(
        rpad(result.name, 14),
        lpad(round(result.compile_seconds * 1_000; digits=2), 12),
        lpad(round(result.compile_bytes / 2.0^20; digits=2), 15),
        lpad(round(result.solve_seconds * 1_000; digits=2), 12),
        lpad(round(result.solve_bytes / 2.0^20; digits=2), 13),
        lpad(round(result.objective; sigdigits=10), 20),
    )
end

function print_comparison(legacy::BenchmarkResult, candidates::BenchmarkResult...)
    println("pipeline        compile ms     compile MiB    solve ms    solve MiB           objective")
    _print_result(legacy)
    for candidate in candidates
        _print_result(candidate)
        println(
            "  vs legacy: compile ",
            round(legacy.compile_seconds / candidate.compile_seconds; digits=2),
            "x, solve ",
            round(legacy.solve_seconds / candidate.solve_seconds; digits=2),
            "x",
        )
    end
    return nothing
end

end
