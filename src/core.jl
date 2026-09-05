# The optimizer binary (`_core` + `libciq.so`) from NVIDIA's `compileiq` wheel.
# Downloaded directly from NVIDIA's PyPI wheel on the user's machine, then
# stored as a locally created artifact. Its binding lives in scratch space,
# without download metadata: no binary is published or mirrored by this package.

"""
    CORE_VERSION

Version of the `compileiq` wheel this package's core is pinned to.
"""
const CORE_VERSION = v"1.0.3"

# Sys.ARCH => (wheel URL, sha256). From https://pypi.org/pypi/compileiq/1.0.3/json.
const CORE_WHEELS = Dict{Symbol,Tuple{String,String}}(
    :x86_64 => (
        "https://files.pythonhosted.org/packages/97/84/be6e21c3cc5187a83ce96344be71502fa7c3870d44a7743661ddd96b1f71/compileiq-1.0.3-py3-none-manylinux_2_34_x86_64.whl",
        "2f7a54bf920274b5245c060a622af543b69cd66c5b02186247eacae7a41810b8"),
    :aarch64 => (
        "https://files.pythonhosted.org/packages/67/ce/0c4ca0617d7ff9158bf21dc5c0364207e757b2e2070af6937402f5b3176d/compileiq-1.0.3-py3-none-manylinux_2_34_aarch64.whl",
        "4ab6b7a578d13eaf0575bb34f339c70c297b3dcbd4b2a2bddb41c6f66b7dd835"),
)

# Path of the platform directory inside the wheel; it holds `bin/_core`,
# `bin/core` (a launcher script) and `lib/libciq.so`.
_wheel_platform_dir(arch::Symbol) = joinpath("compileiq", "core", "executable", "linux", string(arch))

function _core_arch()
    Sys.islinux() || error("CompileIQ's core is only published for Linux (x86_64, aarch64) and Windows x86_64; " *
                           "this package supports the Linux builds. Set the `core` preference to point at a manual install.")
    haskey(CORE_WHEELS, Sys.ARCH) || error("no CompileIQ core wheel for architecture $(Sys.ARCH)")
    Sys.ARCH
end

# Accept the various things a user might point at: the `_core` file, its `bin/`
# directory, the platform directory, or a pip `site-packages/compileiq` tree.
function _normalize_core_dir(path::AbstractString)
    path = expanduser(path)
    if isfile(path) && basename(path) in ("_core", "core")
        return dirname(dirname(path))
    end
    isdir(path) || return nothing
    isfile(joinpath(path, "_core")) && return dirname(path)
    isfile(joinpath(path, "bin", "_core")) && return path
    for candidate in (joinpath(path, "core", "executable", "linux", string(Sys.ARCH)),
                      joinpath(path, "compileiq", "core", "executable", "linux", string(Sys.ARCH)))
        isfile(joinpath(candidate, "bin", "_core")) && return candidate
    end
    return nothing
end

_scratch_core_dir() = joinpath(@get_scratch!("core"), string(CORE_VERSION), _wheel_platform_dir(_core_arch()))

_core_artifacts_toml() = joinpath(@get_scratch!("core-artifacts"), "$(CORE_VERSION)-$(Sys.ARCH)-Artifacts.toml")
const CORE_INSTALL_LOCK = ReentrantLock()

function _artifact_core_dir(artifacts_toml::AbstractString=_core_artifacts_toml())
    hash = Artifacts.artifact_hash("core", artifacts_toml)
    hash === nothing && return nothing
    Artifacts.artifact_exists(hash) || return nothing
    dir = Artifacts.artifact_path(hash)
    return isfile(joinpath(dir, "bin", "_core")) && isfile(joinpath(dir, "lib", "libciq.so")) ? dir : nothing
end

"""
    core_dir() -> String

Directory holding `bin/_core` and `lib/libciq.so`: the `core` preference,
`COMPILEIQ_CORE` (either may name the `_core` file, its directory, or a pip
`compileiq` package directory), a local artifact, or a legacy scratch install.
If none exists, downloads the pinned wheel and creates a local artifact via
[`install_core!`](@ref). Invalid explicit overrides raise an error.
"""
function core_dir()
    dir = _find_core_dir()
    return dir === nothing ? install_core!() : dir
end

function _find_core_dir()
    for (source, value) in (("preference `core`", @load_preference("core", nothing)),
                            ("COMPILEIQ_CORE", get(ENV, "COMPILEIQ_CORE", nothing)))
        value === nothing && continue
        dir = _normalize_core_dir(value)
        dir === nothing && error("$source = $(repr(value)) does not contain a CompileIQ core (bin/_core)")
        return dir
    end
    dir = _artifact_core_dir()
    dir === nothing || return dir
    # Continue to recognize installs made by earlier package versions.
    dir = _scratch_core_dir()
    return isfile(joinpath(dir, "bin", "_core")) ? dir : nothing
end

"""
    core_available() -> Bool

Whether a core binary is installed. Does not download it.
"""
core_available() = _find_core_dir() !== nothing

"""
    install_core!(; force=false) -> String

Download the pinned `compileiq` wheel ([`CORE_VERSION`](@ref)) from PyPI,
verify its SHA-256, and extract the core into a local Julia artifact; returns
its directory. Preserves the wheel's `LICENSE`, `NOTICE`, and core manifest.
The artifact binding is stored in scratch space with no download URLs.

Called automatically when [`search`](@ref) or [`sample`](@ref) needs the core.
Call explicitly to prefetch for offline use. An existing artifact is reused
unless `force=true`, which downloads and verifies the wheel again. Explicit
core overrides and legacy scratch installs are left untouched.
"""
function install_core!(; force::Bool=false)
    arch = _core_arch()
    url, expected = CORE_WHEELS[arch]
    return _install_core_artifact(_core_artifacts_toml(), url, expected; arch, force)
end

# Kept separate so tests can install a small local wheel with its own checksum.
function _install_core_artifact(artifacts_toml, url, expected; arch::Symbol=Sys.ARCH,
                                force::Bool=false)
    lock(CORE_INSTALL_LOCK) do
        if !force
            dir = _artifact_core_dir(artifacts_toml)
            dir === nothing || return dir
        end
        @info "Downloading NVIDIA CompileIQ $(CORE_VERSION) directly from PyPI" url
        hash = mktempdir() do tmp
            wheel = joinpath(tmp, "compileiq.whl")
            Downloads.download(url, wheel)
            actual = bytes2hex(open(sha256, wheel))
            actual == expected || error("SHA-256 mismatch for $url:\n  expected $expected\n  got      $actual")
            unpacked = joinpath(tmp, "unpacked")
            run(`$(p7zip_jll.p7zip()) x $wheel -o$unpacked -y -bso0 -bsp0
                  $(_wheel_platform_dir(arch)) compileiq/core/executable/core-manifest.json
                  compileiq-$(CORE_VERSION).dist-info/licenses`)
            platform_dir = joinpath(unpacked, _wheel_platform_dir(arch))
            licenses = joinpath(unpacked, "compileiq-$(CORE_VERSION).dist-info", "licenses")
            for path in (joinpath(platform_dir, "bin", "_core"), joinpath(platform_dir, "bin", "core"),
                         joinpath(platform_dir, "lib", "libciq.so"), joinpath(licenses, "LICENSE"),
                         joinpath(licenses, "NOTICE"), joinpath(unpacked, "compileiq", "core", "executable", "core-manifest.json"))
                isfile(path) || error("CompileIQ wheel is missing required file: $path")
            end
            Artifacts.create_artifact() do dir
                cp(joinpath(platform_dir, "bin"), joinpath(dir, "bin"))
                cp(joinpath(platform_dir, "lib"), joinpath(dir, "lib"))
                for exe in ("_core", "core")
                    chmod(joinpath(dir, "bin", exe), 0o755)
                end
                for name in readdir(licenses)
                    cp(joinpath(licenses, name), joinpath(dir, name))
                end
                cp(joinpath(unpacked, "compileiq", "core", "executable", "core-manifest.json"),
                   joinpath(dir, "core-manifest.json"))
            end
        end
        # Only publish the binding after extraction and validation succeed. Pkg
        # writes it atomically and records its use for artifact garbage collection.
        mkpath(dirname(artifacts_toml))
        Artifacts.bind_artifact!(artifacts_toml, "core", hash; lazy=true, force=true)
        dir = Artifacts.artifact_path(hash)
        @info "CompileIQ core installed as a local artifact" dir
        return dir
    end
end

"""
    core_launcher

Testing hook: a function `config_path -> Cmd` run in place of the real core.
"""
const core_launcher = Ref{Any}(nothing)

# The command that starts the optimizer. Mirrors the wheel's `bin/core` launcher
# script: `_core -c main_config.json` with `lib/` on LD_LIBRARY_PATH, and the
# client's listening address in CIQ_HOST/CIQ_PORT.
function core_cmd(config_path::AbstractString; host::AbstractString, port::Integer)
    env = Dict{String,String}("CIQ_HOST" => String(host), "CIQ_PORT" => string(port))
    cmd = if core_launcher[] !== nothing
        core_launcher[](config_path)::Cmd
    else
        dir = core_dir()
        lib = joinpath(dir, "lib")
        env["LD_LIBRARY_PATH"] = haskey(ENV, "LD_LIBRARY_PATH") ? ENV["LD_LIBRARY_PATH"] * ":" * lib : lib
        `$(joinpath(dir, "bin", "_core")) -c $config_path`
    end
    return addenv(cmd, env...)
end
