# `functional` and `versioninfo`, in the CUDA.jl idiom: one call to find out
# whether a search can run here, and one to paste into a bug report.

"""
    functional(show_reason=false) -> Bool

Whether a search can run on this machine: a supported platform, an installed
core ([`core_available`](@ref); nothing is downloaded), and a `ptxas` new
enough for `--apply-controls` (13.3). With `show_reason=true` the first
failing requirement is logged.
"""
function functional(show_reason::Bool=false)
    reason = _nonfunctional_reason()
    reason === nothing && return true
    show_reason && @warn "CompileIQ is not functional: $reason"
    return false
end

function _nonfunctional_reason()
    Sys.islinux() || return "the CompileIQ core is only available for Linux"
    haskey(CORE_WHEELS, Sys.ARCH) || return "no CompileIQ core wheel for architecture $(Sys.ARCH)"
    available = try
        core_available()
    catch err
        return "core lookup failed: $(sprint(showerror, err))"
    end
    available || return "the core binary is not installed; run CompileIQ.install_core!()"
    CUDA_Compiler_jll.is_available() || return "CUDA_Compiler_jll provides no ptxas on this platform"
    version = try
        ptxas_version()
    catch err
        return "could not determine the ptxas version: $(sprint(showerror, err))"
    end
    version >= v"13.3" || return "ptxas $version is too old; --apply-controls needs CUDA 13.3 or newer"
    return nothing
end

"""
    versioninfo([io::IO])

Print the package version, the core binary in use (and its build, when the
wheel's manifest is present), the `ptxas` it will drive, and which
search-space and booster-pack catalogs are pinned.
"""
function versioninfo(io::IO=stdout)
    println(io, "CompileIQ.jl v", pkgversion(@__MODULE__))

    core = try
        core_dir(install=false)
    catch err
        println(io, "  core: error — ", sprint(showerror, err))
        nothing
    end
    if core === nothing
        println(io, "  core: not installed (wheel compileiq ", CORE_VERSION, "; run CompileIQ.install_core!())")
    else
        build = _core_build(core)
        println(io, "  core: compileiq ", CORE_VERSION, build === nothing ? "" : " ($build)", " at ", core)
    end

    if CUDA_Compiler_jll.is_available()
        version = try
            string(ptxas_version())
        catch
            "unknown version"
        end
        println(io, "  ptxas: ", version, " at ", CUDA_Compiler_jll.ptxas_path)
    else
        println(io, "  ptxas: CUDA_Compiler_jll not available")
    end

    println(io, "  search spaces: ", DEFAULT_SEARCH_SPACES_TAG, " (", _cached_summary(joinpath(@get_scratch!("search-spaces"), DEFAULT_SEARCH_SPACES_TAG), ".bin"), ")")
    println(io, "  booster packs: ", DEFAULT_BOOSTER_PACKS_TAG, " (", _cached_summary(joinpath(@get_scratch!("booster-packs"), DEFAULT_BOOSTER_PACKS_TAG), ".zip"), ")")
    println(io, "  platform: ", Sys.MACHINE, ", Julia ", VERSION)
    return nothing
end

# "commit a5a0b8b, built 2026-08-14" from the wheel's core-manifest.json, if
# install_core! extracted it (older installs lack the file).
function _core_build(core::AbstractString)
    path = joinpath(core, "core-manifest.json")
    isfile(path) || return nothing
    manifest = try
        JSON.parse(read(path, String))
    catch
        return nothing
    end
    parts = String[]
    commit = get(manifest, "core_commit", nothing)
    commit isa AbstractString && push!(parts, "commit " * first(commit, 7))
    built = get(manifest, "built_at", nothing)
    built isa AbstractString && push!(parts, "built " * first(built, 10))
    isempty(parts) ? nothing : join(parts, ", ")
end

function _cached_summary(dir::AbstractString, ext::AbstractString)
    isdir(dir) || return "nothing cached"
    files = filter(f -> endswith(f, ext), readdir(dir))
    isempty(files) ? "nothing cached" : "cached: " * join(files, ", ")
end
