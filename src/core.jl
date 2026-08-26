# The optimizer itself. NVIDIA ships it only as `_core` (a ~90 MB Racket
# executable) plus `libciq.so`, bundled inside the `compileiq` Python wheel under
# an NVIDIA Software License Agreement that permits installing and using it but
# not redistributing it. So there is no JLL: the user's machine downloads the
# wheel from PyPI on first use, and only the core's files are extracted.

"""
    CORE_VERSION

Version of the `compileiq` wheel whose core this package is pinned to. The
wire protocol is undocumented, so the binary is pinned by URL and SHA-256
rather than tracked as "latest".
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
    core_dir(; install=true) -> Union{String,Nothing}

Directory containing `bin/_core` and `lib/libciq.so`. Resolved, in order, from
the `core` preference, the `COMPILEIQ_CORE` environment variable (either may
name the `_core` file, its directory, or a pip `compileiq` package directory),
then this package's scratch space. With `install=true` (the default) a missing
scratch install is created by [`install_core!`](@ref); otherwise `nothing` is
returned when no core is found.
"""
function core_dir(; install::Bool=true)
    for (source, value) in (("preference `core`", @load_preference("core", nothing)),
                            ("COMPILEIQ_CORE", get(ENV, "COMPILEIQ_CORE", nothing)))
        value === nothing && continue
        dir = _normalize_core_dir(value)
        dir === nothing && error("$source = $(repr(value)) does not contain a CompileIQ core (bin/_core)")
        return dir
    end
    dir = _scratch_core_dir()
    isfile(joinpath(dir, "bin", "_core")) && return dir
    install || return nothing
    install_core!()
end

"""
    core_available() -> Bool

Whether a core binary is already installed (without triggering a download).
"""
core_available() = core_dir(install=false) !== nothing

"""
    install_core!(; force=false) -> String

Download the pinned `compileiq` wheel ([`CORE_VERSION`](@ref)) from PyPI,
verify its SHA-256, and extract the core binary into this package's scratch
space. Returns the core directory. Already-installed cores are kept unless
`force=true`.

The wheel is NVIDIA proprietary software; downloading it means accepting the
NVIDIA Software License Agreement bundled with it, which is extracted alongside
the binary as `LICENSE`.
"""
function install_core!(; force::Bool=false)
    arch = _core_arch()
    dest = joinpath(@get_scratch!("core"), string(CORE_VERSION))
    dir = joinpath(dest, _wheel_platform_dir(arch))
    if !force && isfile(joinpath(dir, "bin", "_core"))
        return dir
    end
    url, expected = CORE_WHEELS[arch]
    @info "Downloading NVIDIA CompileIQ $(CORE_VERSION) from PyPI (~34 MB). The core binary is proprietary " *
          "and licensed to you under the NVIDIA Software License Agreement shipped in the wheel." url
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
    return dir
end

"""
    core_launcher

Testing hook. When set to a function `config_path -> Cmd`, [`search`](@ref)
runs that command instead of the real core. The command must implement the
core's side of the protocol (connect to `CIQ_HOST:CIQ_PORT`, stream candidate
generations, read scores, send `{"complete":1}`).
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
