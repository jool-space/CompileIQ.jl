@testset "sessions" begin
    C = CompileIQ
    space = ParamSpace("x" => Choice(1))
    config = SearchConfig(generations=2, pool_size=6)

    @test_throws ArgumentError C.Session(space; io_timeout=0)
    @test_throws ArgumentError C.Session(space; connect_timeout=Inf)
    @test_throws ArgumentError C.Session(space; io_timeout=NaN)
    @test_throws ArgumentError C.Session(space; config, generations=1)

    with_fakecore() do
        withenv("COMPILEIQ_FAKE_MODE" => "repeated_generation") do
            s = C.Session(space, config)
            proc, dir = s.process, s.dir
            try
                @test isopen(s)
                a = C.receive(s)
                @test a isa C.Batch && eltype(a) == C.Proposal
                @test (a.sequence, a.generation, a.invocation_id) == (1, 0, 42)
                @test [p.id for p in a] == [100 + 7i for i in 0:5]
                @test all(p -> p.params == (x=1,), a)
                @test_throws ArgumentError C.receive(s)
                @test_throws ArgumentError C.submit!(s, a, [1])
                @test_throws ArgumentError C.submit!(s, a, fill((1, 2), 6))
                @test_throws ArgumentError C.submit!(s, a, fill("bad", 6))
                reverse!(a.candidates)
                @test_throws ArgumentError C.submit!(s, a, [p.id for p in a])
                reverse!(a.candidates)
                @test C.submit!(s, a, (p.id for p in a)) === nothing
                @test_throws ArgumentError C.submit!(s, a, [p.id for p in a])
                b = C.receive(s)
                @test (b.sequence, b.generation, b.invocation_id) == (2, 0, 42)
                @test [p.id for p in b] == [p.id for p in a]
                @test_throws ArgumentError C.submit!(s, a, [p.id for p in a])
                C.submit!(s, b, [p.id for p in b])
                @test C.receive(s) === nothing
                @test C.receive(s) === nothing
                @test !isopen(s)
                @test process_exited(proc)
                @test !ispath(dir)
                @test !isopen(s.socket) && !isopen(s.server)
                @test close(s) === nothing
            finally
                close(s)
            end
        end

        # A batch from another live session cannot be submitted, even though
        # the core IDs and generation are identical.
        C.Session(space; generations=1, pool_size=6) do a
            C.Session(space; generations=1, pool_size=6) do b
                batch_a, batch_b = C.receive(a), C.receive(b)
                @test_throws ArgumentError C.submit!(b, batch_a, fill(1, 6))
                C.submit!(b, batch_b, fill(1, 6))
                @test C.receive(b) === nothing
                # a deliberately exits with an unsubmitted batch.
            end
        end

        s = C.Session(space; generations=1, pool_size=6)
        batch = C.receive(s)
        close(s)
        @test !isopen(s) && process_exited(s.process) && !ispath(s.dir)
        @test_throws ArgumentError C.receive(s)
        @test_throws ArgumentError C.submit!(s, batch, fill(1, 6))
        @test close(s) === nothing

        held = Ref{C.Session}()
        @test_throws ErrorException C.Session(space; generations=1, pool_size=6) do s
            held[] = s
            C.receive(s)
            error("caller cancelled")
        end
        @test process_exited(held[].process) && !ispath(held[].dir)

        # Reading/scoring a batch starts no timer in the background. Waiting
        # longer than io_timeout between operations is permitted.
        C.Session(space; generations=1, pool_size=6, io_timeout=1) do s
            batch = C.receive(s)
            sleep(1.1)
            @test isopen(s)
            C.submit!(s, batch, fill(1, length(batch)))
            @test C.receive(s) === nothing
        end

        withenv("COMPILEIQ_FAKE_MODE" => "silent") do
            s = C.Session(space; generations=1, pool_size=6, io_timeout=0.1)
            @test_throws C.CoreTimeoutError C.receive(s)
            @test !isopen(s) && process_exited(s.process) && !ispath(s.dir)
        end
        for mode in ("truncated", "malformed", "failed", "duplicate_ids")
            withenv("COMPILEIQ_FAKE_MODE" => mode) do
                s = C.Session(space; generations=1, pool_size=6)
                @test_throws Exception C.receive(s)
                @test !isopen(s) && process_exited(s.process) && !ispath(s.dir)
            end
        end
        withenv("COMPILEIQ_FAKE_MODE" => "complete") do
            C.Session(space; generations=1, pool_size=6, connect_timeout=nothing, io_timeout=nothing) do s
                @test C.receive(s) === nothing
            end
            @test_throws r"without producing samples" sample(space)
        end

        # JSON framing must ignore braces, brackets, quotes, and backslashes
        # embedded in strings, including nested JSON parameter payloads.
        text = "escaped \\\" { [ ] } — λ"
        oddspace = ParamSpace("x" => Literal(text))
        @test all(p -> p.x == text, sample(oddspace, 2))

        # Cancellation escapes the objective wrapper. Whole-candidate invalid
        # scores work for multiple objectives, including caught exceptions.
        @test_throws InterruptException search(space; generations=1, pool_size=6, progress=false) do _
            throw(InterruptException())
        end
        result = search(_ -> missing, space; generations=1, pool_size=8, num_objectives=2, progress=false)
        @test length(result) == 8 && all(c -> isequal(c.scores, [missing, missing]), result)
        result = @test_logs (:warn, r"objective threw") match_mode=:any search(space;
            generations=1, pool_size=8, num_objectives=2, progress=false) do _
            error("invalid compile")
        end
        @test length(result) == 8 && all(c -> !isvalid(c), result)

        # Preserve the original custom-map input shape and snapshot objective
        # outputs before a subsequent evaluation reuses the same buffer.
        mutable_scores = zeros(2)
        mapped_params = Any[]
        custom_map = function (f, xs)
            append!(mapped_params, xs)
            return map(f, xs)
        end
        varied = ParamSpace("x" => Range(1, 10))
        result = search(varied; generations=1, pool_size=8, num_objectives=2,
                        progress=false, map=custom_map) do p
            mutable_scores .= (p.x, p.x^2)
        end
        @test all(p -> p isa NamedTuple, mapped_params)
        @test all(c -> c.scores == [c.params.x, c.params.x^2], result)

        # Incorrect custom map cardinality must be rejected before sending.
        @test_throws ArgumentError search(identity, space; generations=1, pool_size=6,
                                         progress=false, map=(f, xs) -> [1])
    end

    old_launcher = C.core_launcher[]
    created = Ref("")
    try
        C.core_launcher[] = path -> (created[] = dirname(path); `sh -c "exit 17"`)
        @test_throws r"exited with code 17 before connecting" C.Session(space; connect_timeout=5)
        @test !ispath(created[])

        # A running subprocess that never connects; exec keeps a single PID.
        C.core_launcher[] = path -> (created[] = dirname(path); `sleep 60`)
        @test_throws C.CoreTimeoutError C.Session(space; connect_timeout=0.1)
        @test !ispath(created[])

        C.core_launcher[] = path -> (created[] = dirname(path); `/nonexistent/compileiq-core`)
        @test_throws Base.IOError C.Session(space)
        @test !ispath(created[])
    finally
        C.core_launcher[] = old_launcher
    end
end
