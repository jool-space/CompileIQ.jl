# Small synthetic wheel: exercises installation without NVIDIA binaries,
# external downloads, or changes to the user's depot.
@testset "local core artifacts" begin
    if Sys.islinux() && haskey(CompileIQ.CORE_WHEELS, Sys.ARCH)
        mktempdir() do tmp
            wheelroot = joinpath(tmp, "wheel")
            platform = joinpath(wheelroot, CompileIQ._wheel_platform_dir(Sys.ARCH))
            mkpath(joinpath(platform, "bin"))
            mkpath(joinpath(platform, "lib"))
            write(joinpath(platform, "bin", "_core"), "#!/bin/sh\nexit 0\n")
            write(joinpath(platform, "bin", "core"), "#!/bin/sh\nexit 0\n")
            write(joinpath(platform, "lib", "libciq.so"), "synthetic library")
            write(joinpath(wheelroot, "compileiq", "core", "executable", "core-manifest.json"), "{}")
            licenses = joinpath(wheelroot, "compileiq-$(CompileIQ.CORE_VERSION).dist-info", "licenses")
            mkpath(licenses)
            write(joinpath(licenses, "LICENSE"), "synthetic license")
            write(joinpath(licenses, "NOTICE"), "synthetic notices")
            write(joinpath(wheelroot, "compileiq", "client.py"), "# should not be installed")
            wheel = joinpath(tmp, "fixture.whl")
            cd(wheelroot) do
                run(`$(CompileIQ.p7zip_jll.p7zip()) a -tzip $wheel compileiq compileiq-$(CompileIQ.CORE_VERSION).dist-info -bso0 -bsp0`)
            end
            expected = bytes2hex(open(CompileIQ.sha256, wheel))
            original_wheel = CompileIQ.CORE_WHEELS[Sys.ARCH]
            original_depots = copy(DEPOT_PATH)
            depot = joinpath(tmp, "depot")
            mkpath(depot)
            try
                empty!(DEPOT_PATH)
                push!(DEPOT_PATH, depot)
                CompileIQ.CORE_WHEELS[Sys.ARCH] = ("file://" * wheel, expected)
                withenv("COMPILEIQ_CORE" => nothing) do
                    @test !CompileIQ.core_available()
                    @test occursin("installs on first search or sample", sprint(CompileIQ.versioninfo))
                    @test !isdir(joinpath(depot, "artifacts"))

                    # No explicit install call: core resolution performs it.
                    dir = CompileIQ.core_dir()
                    @test startswith(dir, joinpath(depot, "artifacts"))
                    @test CompileIQ.core_available()
                    @test read(joinpath(dir, "LICENSE"), String) == "synthetic license"
                    @test read(joinpath(dir, "NOTICE"), String) == "synthetic notices"
                    @test isfile(joinpath(dir, "lib", "libciq.so"))
                    @test isfile(joinpath(dir, "core-manifest.json"))
                    @test !isfile(joinpath(dir, "compileiq", "client.py"))
                    @test filemode(joinpath(dir, "bin", "_core")) & 0o111 == 0o111
                    binding = CompileIQ._core_artifacts_toml()
                    meta = CompileIQ.Artifacts.artifact_meta("core", binding)
                    @test meta["lazy"]
                    @test !haskey(meta, "download")
                    hash = CompileIQ.Artifacts.artifact_hash("core", binding)
                    @test CompileIQ.Artifacts.verify_artifact(hash)
                    @test CompileIQ.core_cmd("config.json"; host="127.0.0.1", port=1234).exec[1] == joinpath(dir, "bin", "_core")

                    # Cached use must work even when the source is unavailable.
                    mv(wheel, wheel * ".saved")
                    @test CompileIQ.core_dir() == dir
                    @test CompileIQ.install_core!() == dir
                    mv(wheel * ".saved", wheel)

                    # Failed refreshes preserve the existing artifact and binding.
                    @test_throws r"SHA-256 mismatch" CompileIQ._install_core_artifact(
                        binding, "file://" * wheel, repeat("0", 64); force=true)
                    @test CompileIQ.Artifacts.artifact_hash("core", binding) == hash
                    @test CompileIQ.Artifacts.verify_artifact(hash)
                    @test CompileIQ.install_core!(force=true) == dir

                    # Explicit overrides still take priority; invalid ones do not
                    # silently trigger a download or fall back to the artifact.
                    withenv("COMPILEIQ_CORE" => platform) do
                        @test CompileIQ.core_dir() == platform
                    end
                    withenv("COMPILEIQ_CORE" => joinpath(tmp, "missing")) do
                        @test_throws ErrorException CompileIQ.core_dir()
                    end

                    # A malformed but correctly hashed wheel creates no binding.
                    rm(joinpath(licenses, "NOTICE"))
                    broken = joinpath(tmp, "broken.whl")
                    cd(wheelroot) do
                        run(`$(CompileIQ.p7zip_jll.p7zip()) a -tzip $broken compileiq compileiq-$(CompileIQ.CORE_VERSION).dist-info -bso0 -bsp0`)
                    end
                    broken_sha = bytes2hex(open(CompileIQ.sha256, broken))
                    broken_binding = joinpath(tmp, "broken-Artifacts.toml")
                    @test_throws r"missing required file" CompileIQ._install_core_artifact(
                        broken_binding, "file://" * broken, broken_sha)
                    @test !isfile(broken_binding)
                end
            finally
                CompileIQ.CORE_WHEELS[Sys.ARCH] = original_wheel
                empty!(DEPOT_PATH)
                append!(DEPOT_PATH, original_depots)
            end
        end
    end
end
