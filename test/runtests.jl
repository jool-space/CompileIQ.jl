using CompileIQ
using CompileIQ: sample, SearchConfig, SearchResult, Candidate, NvccSearchSpace, SearchSpaceFile,
                 ParamSpace, Range, Choice, Literal, spill_bytes,
                 BoosterPack, write_booster_pack, read_booster_pack, booster_pack
using Test
using JSON
using CUDACore
using Base64: base64encode

const FAKECORE = joinpath(@__DIR__, "fakecore.jl")

# Route `search`/`sample` at the fake core for the duration of `f`.
function with_fakecore(f)
    CompileIQ.core_launcher[] = config_path ->
        `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $FAKECORE -c $config_path`
    try
        f()
    finally
        CompileIQ.core_launcher[] = nothing
    end
end

@testset "CompileIQ.jl" begin
    @testset "API surface" begin
        exported = Set(filter(n -> Base.isexported(CompileIQ, n), names(CompileIQ)))   # names() also lists public ones
        @test exported == Set([:CompileIQ, :search, :best, :ACF, :PtxasSearchSpace, :ptxas, :PtxasError])
        for name in (:functional, :versioninfo, :sample, :SearchConfig, :ParamSpace, :Range, :Choice, :Literal,
                     :NvccSearchSpace, :SearchSpaceFile, :spill_bytes, :ptxas_version, :booster_pack,
                     :write_booster_pack, :read_booster_pack, :install_core!, :core_available)
            @test Base.ispublic(CompileIQ, name) && !Base.isexported(CompileIQ, name)
        end
    end

    @testset "diagnostics" begin
        @test CompileIQ.functional() isa Bool
        withenv("COMPILEIQ_CORE" => "/nonexistent") do
            @test !CompileIQ.functional()
            @test_logs (:warn, r"core lookup failed") CompileIQ.functional(true)
        end
        mktempdir() do dir
            plat = joinpath(dir, "bin"); mkpath(plat); touch(joinpath(plat, "_core"))
            withenv("COMPILEIQ_CORE" => dir) do
                # core "installed" → ptxas is the next requirement, whatever its state
                info = sprint(CompileIQ.versioninfo)
                @test occursin("CompileIQ.jl v", info) && occursin("core: compileiq $(CompileIQ.CORE_VERSION)", info)
                @test occursin(dir, info) && occursin("search spaces: ", info) && occursin("ptxas: ", info)
            end
            write(joinpath(dir, "core-manifest.json"), """{"core_commit":"a5a0b8b9414ea62d1d4f6d6bca8dd8904f9518bd","built_at":"2026-08-14T22:16:52Z"}""")
            @test CompileIQ._core_build(dir) == "commit a5a0b8b, built 2026-08-14"
        end
        info = sprint(CompileIQ.versioninfo)
        @test occursin(r"core: (compileiq|not installed)", info)
    end

    @testset "ACF" begin
        acf = ACF("c9e5b121")
        @test acf.bytes == UInt8[0xc9, 0xe5, 0xb1, 0x21]
        @test CompileIQ.hex(acf) == "c9e5b121"
        @test acf == ACF(UInt8[0xc9, 0xe5, 0xb1, 0x21])
        @test hash(acf) == hash(ACF("c9e5b121"))
        @test sprint(show, acf) == "ACF(4 bytes)"
        mktempdir() do dir
            path = joinpath(dir, "x.acf")
            write(path, acf)
            @test read(path) == acf.bytes
            @test read(path, ACF) == acf
            io = IOBuffer(); write(io, acf)
            @test take!(io) == acf.bytes
        end
    end

    @testset "SearchConfig" begin
        cfg = SearchConfig()
        @test cfg.generations == 5 && cfg.problem_type === :min
        # derived sizes, same rule as the Python client
        @test (cfg.pool_size, cfg.cull_size) == (32, 24)
        @test (c -> (c.pool_size, c.cull_size))(SearchConfig(pool_size=16)) == (16, 12)
        @test (c -> (c.pool_size, c.cull_size))(SearchConfig(pool_size=6)) == (6, 2)
        @test (c -> (c.pool_size, c.cull_size))(SearchConfig(pool_size=7)) == (7, 4)
        @test (c -> (c.pool_size, c.cull_size))(SearchConfig(num_objectives=3)) == (32, 24)
        @test (c -> (c.pool_size, c.cull_size))(SearchConfig(num_objectives=20)) == (164, 122)
        @test_throws ArgumentError SearchConfig(generations=0)
        @test_throws ArgumentError SearchConfig(problem_type=:maximize)
        @test_throws ArgumentError SearchConfig(pool_size=4)
        @test_throws ArgumentError SearchConfig(cull_size=3)
        @test_throws ArgumentError SearchConfig(pool_size=8, cull_size=8)
        @test_throws ArgumentError SearchConfig(pool_size=8, cull_size=6)      # only 2 survivors
        @test_throws ArgumentError SearchConfig(mutate_rate=1.0)
        @test_throws ArgumentError SearchConfig(num_objectives=2, objective_weights=[1.0])

        d = CompileIQ.core_config(SearchConfig(generations=2, pool_size=8, cull_size=4, problem_type=:max), "/tmp/ss.json")
        @test d["problem_type"] == "max"
        @test d["generations"] == 2 && d["pool_size"] == 8 && d["cull_size"] == 4
        @test d["dna_config"] == "/tmp/ss.json"
        @test d["normalize"] === false && d["enable_result_file"] === false
        @test !any(v -> v === nothing, values(d))
        @test CompileIQ.core_config(SearchConfig(), "x")["cull_size"] == 24
        @test CompileIQ.core_config(SearchConfig(), ["a", "b"])["dna_config"] == ["a", "b"]
    end

    @testset "ParamSpace JSON" begin
        # Matches the file the Python client writes for
        #   {"x": ss.range(1.0, 20.0, 0.5), "y": ss.choice([1,2,3]), "z": ss.literal("this is a constant", knockout_prob=0.5)}
        space = ParamSpace("x" => Range(1.0, 20.0; step=0.5), "y" => Choice(1, 2, 3),
                           "z" => Literal("this is a constant"; knockout=0.5))
        doc = JSON.parse(CompileIQ.search_space_json(space))
        @test doc.format == "compileiq-search-space-v1"
        @test doc.parameter_layout == ["{", "eA==", "eQ==", "eg==", "}"]
        @test doc.classes["eA=="] == Dict("type" => "range", "low" => 1.0, "high" => 20.0, "step" => 0.5)
        @test doc.classes["eQ=="] == Dict("type" => "enum", "vals" => [1, 2, 3])
        @test doc.classes["eg=="] == Dict("type" => "literal", "value" => "this is a constant", "knockout_threshold" => 0.5)

        nested = ParamSpace("a" => Choice([true, false]), "b" => ParamSpace("c" => Range(1, 4; seed=(2, 3), knockout=0.1)))
        doc = JSON.parse(CompileIQ.search_space_json(nested))
        key = base64encode("b") * "_" * base64encode("c")
        @test doc.parameter_layout == ["{", base64encode("a"), key, "}"]
        @test doc.classes[key]["seed-low"] == 2 && doc.classes[key]["seed-high"] == 3
        @test doc.classes[key].knockout_threshold == 0.9

        @test_throws ArgumentError Range(4, 1)
        @test_throws ArgumentError Range(1, 4; step=0)
        @test_throws ArgumentError Choice(1, 2; knockout=1.5)
        @test Choice([1, 2]) == Choice(1, 2)
    end

    @testset "decode" begin
        ptxas_space = PtxasSearchSpace()
        @test ptxas_space.version == "13.3" && ptxas_space.variant === :default
        @test CompileIQ.decode(ptxas_space, "c9e5b121") == ACF("c9e5b121")
        @test CompileIQ.decode(NvccSearchSpace("13.4"), "00ff") == ACF("00ff")

        space = ParamSpace("x" => Range(1, 2), "y" => Choice(1, 2), "b" => ParamSpace("c" => Literal(7)))
        params = CompileIQ.decode(space, """{"eA==": 1.5, "eQ==": 1, "$(base64encode("b"))_$(base64encode("c"))": 7}""")
        @test params == Dict("x" => 1.5, "y" => 1, "b" => Dict("c" => 7))
        @test params isa Dict{String,Any} && params["b"] isa Dict{String,Any}
        @test CompileIQ.decode(space, """{"eA==": 1.5}""") == Dict("x" => 1.5)   # knocked-out y, b.c
        @test_throws ErrorException CompileIQ.decode(space, "[1,2]")

        mixed = [space, ptxas_space]
        knobs = JSON.json([base64encode("""{"eA==": 2}"""), base64encode("abcd")])
        @test CompileIQ.decode(mixed, knobs) == Any[Dict("x" => 2), ACF("abcd")]
        @test_throws ErrorException CompileIQ.decode(mixed, JSON.json([base64encode("{}")]))

        file = SearchSpaceFile("/nonexistent/space.bin")
        @test CompileIQ.decode(file, "abcd") == ACF("abcd")
        @test CompileIQ.decode(file, """{"k": [1, "v"]}""") == Dict("k" => Any[1, "v"])
        @test CompileIQ.decode(file, "not-hex") == "not-hex"
    end

    @testset "materialize" begin
        mktempdir() do dir
            space = ParamSpace("x" => Choice(1, 2))
            path = CompileIQ.materialize(space, dir)
            @test basename(path) == "search_space.json"
            @test read(path, String) == CompileIQ.search_space_json(space)

            bin = joinpath(dir, "fake.bin"); write(bin, UInt8[1, 2, 3])
            paths = CompileIQ.materialize([space, SearchSpaceFile(bin)], dir)
            @test basename.(paths) == ["0_search_space.json", "1_search_space.json"]
            @test read(paths[2]) == UInt8[1, 2, 3]
            @test_throws ErrorException CompileIQ.materialize(SearchSpaceFile(joinpath(dir, "missing")), dir)
        end
    end

    @testset "core resolution" begin
        mktempdir() do dir
            plat = joinpath(dir, "compileiq", "core", "executable", "linux", string(Sys.ARCH))
            mkpath(joinpath(plat, "bin")); mkpath(joinpath(plat, "lib"))
            touch(joinpath(plat, "bin", "_core"))
            @test CompileIQ._normalize_core_dir(plat) == plat
            @test CompileIQ._normalize_core_dir(joinpath(plat, "bin")) == plat
            @test CompileIQ._normalize_core_dir(joinpath(plat, "bin", "_core")) == plat
            @test CompileIQ._normalize_core_dir(joinpath(dir, "compileiq")) == plat
            @test CompileIQ._normalize_core_dir(dir) == plat
            @test CompileIQ._normalize_core_dir(joinpath(dir, "nope")) === nothing
            withenv("COMPILEIQ_CORE" => joinpath(plat, "bin", "_core")) do
                @test CompileIQ.core_dir() == plat
                @test CompileIQ.core_available()
            end
            withenv("COMPILEIQ_CORE" => joinpath(dir, "nope")) do
                @test_throws ErrorException CompileIQ.core_dir()
                @test !CompileIQ.functional()
            end
            # no core anywhere → core_dir throws with install instructions, never downloads
            withenv("COMPILEIQ_CORE" => nothing) do
                scratch = CompileIQ._scratch_core_dir()
                if !isfile(joinpath(scratch, "bin", "_core"))
                    @test !CompileIQ.core_available()
                    @test_throws r"install_core!" CompileIQ.core_dir()
                end
            end
        end
    end

    @testset "scores" begin
        @test CompileIQ._wire_scores(3, 1) == [3.0]
        @test CompileIQ._wire_scores(missing, 1) == ["*"]
        @test CompileIQ._wire_scores(NaN, 1) == ["*"]
        @test CompileIQ._wire_scores((1, missing), 2) == [1.0, "*"]
        @test CompileIQ._wire_scores([1.0, 2.0], 2) == [1.0, 2.0]
        @test_throws ArgumentError CompileIQ._wire_scores((1, 2), 1)
        @test_throws ArgumentError CompileIQ._wire_scores(1, 2)
        @test_throws ArgumentError CompileIQ._wire_scores("x", 1)
    end

    @testset "protocol (fake core)" begin
        with_fakecore() do
            space = ParamSpace("x" => Range(1.0, 20.0; step=0.5), "y" => Choice(1, 2, 3),
                               "z" => Literal("c"; knockout=0.5))
            seen = Any[]
            result = search(space; generations=2, pool_size=6, cull_size=2, progress=false) do p
                push!(seen, p)
                p["x"]^2 + p["y"]
            end
            @test result isa SearchResult
            @test length(result) == 12
            @test all(isvalid, result)
            @test all(c -> c.params isa Dict{String,Any}, result)
            @test count(p -> haskey(p, "z"), seen) == 6      # knocked out on odd ids
            @test [c.generation for c in result] == [fill(0, 6); fill(1, 6)]
            @test [c.id for c in result] == [0:5; 0:5]
            b = best(result)
            @test b !== nothing && b.scores[1] == minimum(c.scores[1] for c in result)
            @test best(SearchResult(SearchConfig(problem_type=:max), space, result.candidates)).scores[1] ==
                  maximum(c.scores[1] for c in result)
            @test occursin("2 generations, 12 candidates, 12 valid", sprint(show, result))

            # invalid candidates: missing, exceptions, non-finite. The exception
            # path logs a warning per throwing candidate; capture it.
            result = @test_logs (:warn, r"objective threw") match_mode=:any begin
                search(space; generations=1, pool_size=6, progress=false) do p
                    p["y"] == 1 && return missing
                    p["y"] == 2 && error("boom")
                    Inf
                end
            end
            @test count(isvalid, result) == 0
            @test best(result) === nothing
            @test occursin("invalid", sprint(show, first(result)))
            @test_throws ErrorException search(space; generations=1, pool_size=6, progress=false,
                                               catch_errors=false) do p
                error("boom")
            end

            # compiler space → ACF, multi-objective, custom map
            mktempdir() do dir
                bin = joinpath(dir, "space.bin"); write(bin, rand(UInt8, 32))
                calls = Threads.Atomic{Int}(0)
                # 2 objectives need 5 survivors, so a pool of 6 is rejected (as in Python)
                @test_throws ArgumentError SearchConfig(pool_size=6, num_objectives=2)
                result = search(SearchSpaceFile(bin); generations=1, pool_size=8, num_objectives=2,
                                progress=false, map=asyncmap) do acf
                    Threads.atomic_add!(calls, 1)
                    (length(acf.bytes), acf.bytes[1])
                end
                @test calls[] == 8
                @test all(c -> c.params isa ACF && length(c.scores) == 2, result)
                @test all(c -> c.scores[1] == 16.0, result)
                @test best(result; objective=2).scores[2] == minimum(c.scores[2] for c in result)

                # mixed space
                result = search([space, SearchSpaceFile(bin)]; generations=1, pool_size=6, progress=false) do (p, acf)
                    @test p isa Dict{String,Any} && acf isa ACF
                    p["x"]
                end
                @test length(result) == 6 && all(isvalid, result)
                @test all(c -> c.params isa Vector && length(c.params) == 2, result)
            end

            # sample()
            samples = sample(space, 3)
            @test length(samples) == 3 && all(s -> s isa Dict{String,Any}, samples)
            @test_throws ArgumentError sample(space, 0)

            # config validation on the search entry point
            @test_throws ArgumentError search(identity, space; config=SearchConfig(), generations=1)
            @test_throws ArgumentError search(identity, space; generations=0)
        end
    end

    @testset "ptxas log parsing" begin
        log = """
        ptxas info    : Function properties for kernel_a
            48 bytes stack frame, 48 bytes spill stores, 40 bytes spill loads
        ptxas info    : Function properties for kernel_b
            0 bytes stack frame, 0 bytes spill stores, 0 bytes spill loads
        """
        @test spill_bytes(log) == 88
        @test spill_bytes("nothing here") == 0
        @test sprint(showerror, PtxasError("exited with code 255", "bad", `ptxas x`)) ==
              "PtxasError: exited with code 255\n  command: `ptxas x`\nbad"
    end

    @testset "booster packs" begin
        acfs = ["kernel_a" => ACF(rand(UInt8, 64)), "kernel_b.acf" => ACF(rand(UInt8, 32))]
        mktempdir() do dir
            # directory form
            packdir = write_booster_pack(joinpath(dir, "pack"), acfs; pack_id="jool-test", cuda_version="13.3",
                                         supported_gpus=["RTX 6000 Ada"], display_name="Jool test pack",
                                         description="d", created_by="tests", descriptions=Dict("kernel_a" => "A"),
                                         validation_summary=Dict("status" => "untested"), release_tag="v0")
            @test isfile(joinpath(packdir, "booster-pack-manifest.json"))
            @test Set(readdir(packdir)) == Set(["booster-pack-manifest.json", "kernel_a.acf", "kernel_b.acf"])
            pack = read_booster_pack(packdir)
            @test pack isa BoosterPack
            @test length(pack) == 2 && keys(pack) == ["kernel_a", "kernel_b"]
            @test pack["kernel_a"] == acfs[1][2] && pack["kernel_b"] == acfs[2][2]
            @test haskey(pack, "kernel_a") && !haskey(pack, "kernel_c")
            @test_throws KeyError pack["kernel_c"]
            @test collect(pack) == ["kernel_a" => acfs[1][2], "kernel_b" => acfs[2][2]]
            m = pack.manifest
            @test m["schema_version"] == 1 && m["pack_id"] == "jool-test" && m["display_name"] == "Jool test pack"
            @test m["cuda_version"] == "13.3" && m["supported_gpus"] == ["RTX 6000 Ada"]
            @test m["controls_stage"] == "ptxas" && m["pack_type"] == "performance"
            @test m["validation_summary"] == Dict("status" => "untested") && m["release_tag"] == "v0"
            @test m["notice"] == CompileIQ.NVIDIA_OUTPUT_NOTICE
            @test m["caveats"] == CompileIQ.DEFAULT_CAVEATS
            @test m["acfs"][1]["filename"] == "kernel_a.acf" && m["acfs"][1]["size_bytes"] == 64
            @test m["acfs"][1]["description"] == "A" && m["acfs"][2]["description"] == "Jool test pack controls for kernel_b"
            @test m["acfs"][1]["compiler_stages"] == ["ptxas"]
            @test m["acfs"][1]["sha256"] == bytes2hex(CompileIQ.sha256(acfs[1][2].bytes))
            @test sprint(show, pack) == "BoosterPack(\"jool-test\", 2 ACFs, CUDA 13.3)"

            # zip form, NVIDIA layout: one top-level directory named after the file
            zip = write_booster_pack(joinpath(dir, "out", "booster-pack-jool.zip"), acfs; pack_id="jool-test",
                                     cuda_version="13.3", supported_gpus=["ALL"], controls_stage="both",
                                     validation_summary=nothing, notice=nothing)
            @test isfile(zip)
            zpack = read_booster_pack(zip)
            @test collect(zpack) == collect(pack)
            @test zpack.manifest["acfs"][1]["compiler_stages"] == ["nvcc", "ptxas"]
            @test !haskey(zpack.manifest, "validation_summary") && !haskey(zpack.manifest, "notice")
            mktempdir() do x
                run(`$(CompileIQ.p7zip_jll.p7zip()) x $zip -o$x -y -bso0 -bsp0`)
                @test readdir(x) == ["booster-pack-jool"]
            end

            # integrity checks
            write(joinpath(packdir, "kernel_b.acf"), rand(UInt8, 32))
            @test_throws ErrorException read_booster_pack(packdir)
            write(joinpath(packdir, "kernel_b.acf"), rand(UInt8, 33))
            @test_throws ErrorException read_booster_pack(packdir)
            rm(joinpath(packdir, "kernel_b.acf"))
            @test_throws ErrorException read_booster_pack(packdir)
            @test_throws ErrorException read_booster_pack(joinpath(dir, "nonexistent"))
            @test_throws ErrorException read_booster_pack(dir)   # no manifest

            # argument validation
            kw = (; pack_id="p", cuda_version="13.3", supported_gpus=["ALL"])
            @test_throws ArgumentError write_booster_pack(joinpath(dir, "e"), []; kw...)
            @test_throws ArgumentError write_booster_pack(joinpath(dir, "e"), ["a" => acfs[1][2], "a.acf" => acfs[2][2]]; kw...)
            @test_throws ArgumentError write_booster_pack(joinpath(dir, "e"), ["a/b" => acfs[1][2]]; kw...)
            @test_throws ArgumentError write_booster_pack(joinpath(dir, "e"), acfs; kw..., pack_type="fast")
            @test_throws ArgumentError write_booster_pack(joinpath(dir, "e"), acfs; kw..., controls_stage="sass")
        end
    end

    # Launch ptxas output on a GPU. Skipped without a functional CUDA setup.
    @testset "device" begin
        ptxas_ok = try
            CompileIQ.ptxas_version() >= v"13.3"
        catch
            false
        end
        if !(CUDACore.functional() && ptxas_ok)
            @info "skipping CompileIQ device tests (CUDA functional: $(CUDACore.functional()), ptxas ≥ 13.3: $ptxas_ok)"
        else
            ptx = read(joinpath(@__DIR__, "saxpy.ptx"), String)
            n = 1 << 20
            xh, yh, a = rand(Float32, n), rand(Float32, n), 2.0f0
            ref = a .* xh .+ yh
            x, y = CuArray(xh), CuArray(yh)
            argtypes = Tuple{CuPtr{Float32}, CuPtr{Float32}, Float32, UInt32}
            launch(fn) = cudacall(fn, argtypes, pointer(x), pointer(y), a, UInt32(n);
                                  threads=256, blocks=cld(n, 256))
            run_saxpy(cubin) = (copyto!(y, yh); launch(CuFunction(CuModule(cubin), "saxpy")); synchronize(); Array(y))

            cubin, _ = ptxas(ptx; arch="sm_" * string(capability(device()).major) * string(capability(device()).minor))
            @test run_saxpy(cubin) ≈ ref

            # A runtime objective through the real core, when it is installed.
            if CompileIQ.core_available()
                arch = "sm_" * string(capability(device()).major) * string(capability(device()).minor)
                pack = booster_pack("debug"; tag="booster-packs-2026.05.27")
                @test run_saxpy(first(ptxas(ptx; arch, acf=pack["ptxas_opt0"]))) ≈ ref

                result = search(PtxasSearchSpace(); generations=2, pool_size=6, progress=false) do acf
                    cub = try first(ptxas(ptx; arch, acf, timeout=60)) catch e; e isa PtxasError && return missing; rethrow() end
                    fn = CuFunction(CuModule(cub), "saxpy")
                    copyto!(y, yh); launch(fn); synchronize()
                    Array(y) ≈ ref || return missing
                    launch(fn); synchronize()
                    minimum(CUDACore.@elapsed(launch(fn)) for _ in 1:20)
                end
                @test count(isvalid, result) >= 1
                @test best(result).scores[1] > 0
            end
        end
    end

    # Real core + real search space + real ptxas. Skipped unless the core is
    # already installed (no downloads from the test suite).
    @testset "integration" begin
        ptxas_ok = try
            CompileIQ.ptxas_version() >= v"13.3"
        catch
            false
        end
        if !(CompileIQ.core_available() && ptxas_ok)
            @info "skipping CompileIQ integration test (core installed: $(CompileIQ.core_available()), ptxas ≥ 13.3: $ptxas_ok)"
        else
            ptx = read(joinpath(@__DIR__, "saxpy.ptx"), String)
            cubin, log = ptxas(ptx; arch="sm_89")
            @test !isempty(cubin) && occursin("Function properties", log)
            @test_throws PtxasError ptxas("garbage"; arch="sm_89")
            @test_throws PtxasError ptxas(ptx; arch="sm_89", options=["--no-such-option"], timeout=30)

            samples = sample(PtxasSearchSpace(), 2)
            @test length(samples) == 2 && all(s -> s isa ACF && !isempty(s.bytes), samples)
            cubin2, _ = ptxas(ptx; arch="sm_89", acf=samples[1], timeout=60)
            @test !isempty(cubin2)

            result = search(PtxasSearchSpace(); generations=2, pool_size=6, progress=false) do acf   # cull_size derived
                _, log = ptxas(ptx; arch="sm_89", acf, timeout=60)
                spill_bytes(log)
            end
            @test length(result) >= 6
            @test count(isvalid, result) >= 1
            @test best(result).params isa ACF

            # NVIDIA's debug pack: downloads, verifies and reads. The May 2026
            # catalog holds the CUDA 13.3 builds, which the JLL's ptxas accepts.
            pack = booster_pack("debug"; tag="booster-packs-2026.05.27")
            @test length(pack) == 5 && haskey(pack, "ptxas_opt0")
            @test startswith(pack.manifest["cuda_version"], "13.3")
            for name in ("ptxas_opt0", "ptxas_opt3")
                cubin_dbg, _ = ptxas(ptx; arch="sm_89", acf=pack[name], timeout=60)
                @test !isempty(cubin_dbg)
            end
            @test_throws ErrorException booster_pack("nonexistent")

            # Package the search winner and read it back.
            mktempdir() do dir
                zip = write_booster_pack(joinpath(dir, "booster-pack-saxpy.zip"), ["saxpy" => best(result).params];
                                         pack_id="saxpy", cuda_version=string(CompileIQ.ptxas_version()),
                                         supported_gpus=["ALL"])
                repacked = read_booster_pack(zip)["saxpy"]
                @test repacked == best(result).params
                cubin3, _ = ptxas(ptx; arch="sm_89", acf=repacked, timeout=60)
                @test !isempty(cubin3)
            end
        end
    end
end
