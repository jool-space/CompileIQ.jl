# Run with: julia --project=. examples/automatic_core.jl
# Uses the real optimizer with a Julia numeric objective; no GPU launch or
# Python installation is needed. The first sample installs the core if absent.
using CompileIQ

space = CompileIQ.ParamSpace(x=CompileIQ.Range(-5, 5))
println("Core installed before sampling: ", CompileIQ.core_available())

samples = CompileIQ.sample(space, 3)
@assert length(samples) == 3
println("Samples: ", samples)

result = search(space; generations=2, pool_size=6) do params
    (params.x - 2)^2
end
winner = best(result)
@assert winner !== nothing
println("Best measured parameters: ", winner.params, "; score: ", CompileIQ.score(winner))
println("Core directory: ", CompileIQ.core_dir())
