@testset "parallel batch evaluation" begin
    with_fakecore() do
        for workers in (1, 4)
            active = Ref(0)
            peak = Ref(0)
            started = Ref(0)
            completed = Int[]
            kwargs = workers == 1 ? (;) : (; map=(f, xs) -> asyncmap(f, xs; ntasks=workers))
            result = search(ParamSpace("x" => Range(1, 10)); generations=2,
                            pool_size=8, progress=false, catch_errors=false, kwargs...) do _
                started[] += 1
                index = started[]
                active[] += 1
                peak[] = max(peak[], active[])
                try
                    # Real subprocess waits yield to other asyncmap tasks.
                    # Unequal durations exercise out-of-order completion.
                    run(`sleep $(0.04 + 0.02 * (4 - mod(index - 1, 4)))`)
                    push!(completed, index)
                    return index
                finally
                    active[] -= 1
                end
            end
            @test peak[] == workers
            @test active[] == 0
            @test length(result) == 16 && all(isvalid, result)
            @test [CompileIQ.score(c) for c in result] == collect(1.0:16.0)
            @test [c.id for c in result] == repeat(collect(0:7), 2)
            @test sort(completed) == collect(1:16)
            @info "Batch concurrency verified" workers peak=peak[] evaluations=length(result)
        end
    end
end
