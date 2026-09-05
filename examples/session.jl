# Run with: julia --project=. examples/session.jl
# Uses the real core and a numeric Julia objective. No GPU kernel is launched.
using CompileIQ: Session, receive, submit!, ParamSpace, Range

space = ParamSpace(x=Range(-5, 5))
record = Pair{Int,Float64}[]

Session(space; generations=2, pool_size=6) do session
    while (batch = receive(session)) !== nothing
        println(batch)
        scores = [(p.params.x - 2)^2 for p in batch]
        # Compilation, measurement, or other work may happen between calls.
        # Breaking here would close the core without submitting this batch.
        submit!(session, batch, scores)
        append!(record, [Int(p.params.x) => Float64(score) for (p, score) in zip(batch, scores)])
    end
end

@assert !isempty(record)
winner = argmin(last, record)
println("Best measured x: ", first(winner), "; score: ", last(winner))
