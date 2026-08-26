# The optimizer binary (`_core` + `libciq.so`) from NVIDIA's `compileiq` wheel.
# Its license does not allow redistribution, so it is installed per machine
# into scratch space rather than shipped as an artifact.

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

"""
    core_dir() -> String

Directory holding `bin/_core` and `lib/libciq.so`: the `core` preference,
`COMPILEIQ_CORE` (either may name the `_core` file, its directory, or a pip
`compileiq` package directory), or the scratch install from
[`install_core!`](@ref). Throws if none exists.
"""
function core_dir()
    dir = _find_core_dir()
    dir === nothing && error("CompileIQ core not installed; run `CompileIQ.install_core!()` " *
                             "or point the `core` preference / COMPILEIQ_CORE at an existing install")
    return dir
end

function _find_core_dir()
    for (source, value) in (("preference `core`", @load_preference("core", nothing)),
                            ("COMPILEIQ_CORE", get(ENV, "COMPILEIQ_CORE", nothing)))
        value === nothing && continue
        dir = _normalize_core_dir(value)
        dir === nothing && error("$source = $(repr(value)) does not contain a CompileIQ core (bin/_core)")
        return dir
    end
    dir = _scratch_core_dir()
    return isfile(joinpath(dir, "bin", "_core")) ? dir : nothing
end

"""
    core_available() -> Bool

Whether a core binary is installed.
"""
core_available() = _find_core_dir() !== nothing

"""
    install_core!(; force=false) -> String

Download the pinned `compileiq` wheel ([`CORE_VERSION`](@ref)) from PyPI,
verify its SHA-256, and extract the core into scratch space; returns its
directory. NVIDIA's license is extracted alongside as `LICENSE`. An existing
install is kept unless `force=true`.
"""
function install_core!(; force::Bool=false)
    arch = _core_arch()
    dest = joinpath(@get_scratch!("core"), string(CORE_VERSION))
    dir = joinpath(dest, _wheel_platform_dir(arch))
    if !force && isfile(joinpath(dir, "bin", "_core"))
        return dir
    end
    url, expected = CORE_WHEELS[arch]
    @info "Downloading NVIDIA CompileIQ $(CORE_VERSION) from PyPI (~34 MB)" url
    mktempdir() do tmp
        wheel = joinpath(tmp, "compileiq.whl")
        Downloads.download(url, wheel)
        actual = bytes2hex(open(sha256, wheel))
        actual == expected || error("SHA-256 mismatch for $url:\n  expected $expected\n  got      $actual")
        rm(dest; recursive=true, force=true)
        mkpath(dest)
        # A wheel is a zip. Extract only the platform directory and the license.
        run(pipeline(`$(p7zip_jll.p7zip()) x $wheel -o$dest -y -bso0 -bsp0
                      $(_wheel_platform_dir(arch)) compileiq/core/executable/core-manifest.json
                      compileiq-$(CORE_VERSION).dist-info/licenses`))
    end
    for exe in ("_core", "core")
        chmod(joinpath(dir, "bin", exe), 0o755)
    end
    license = joinpath(dest, "compileiq-$(CORE_VERSION).dist-info", "licenses", "LICENSE")
    isfile(license) && cp(license, joinpath(dir, "LICENSE"); force=true)
    manifest = joinpath(dest, "compileiq", "core", "executable", "core-manifest.json")
    isfile(manifest) && cp(manifest, joinpath(dir, "core-manifest.json"); force=true)
    isfile(joinpath(dir, "bin", "_core")) || error("wheel extraction did not produce $(joinpath(dir, "bin", "_core"))")
    @info "CompileIQ core installed" dir license = joinpath(dir, "LICENSE")
    return dir
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
