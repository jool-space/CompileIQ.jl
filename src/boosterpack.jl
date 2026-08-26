# Booster packs: NVIDIA's zip format for curated ACFs.
#
#   booster-pack-<name>.zip
#   └── booster-pack-<name>/
#       ├── booster-pack-manifest.json
#       └── *.acf

"""
    DEFAULT_BOOSTER_PACKS_TAG

GitHub release tag of NVIDIA's booster-pack catalog used by
[`booster_pack`](@ref) by default.
"""
const DEFAULT_BOOSTER_PACKS_TAG = "booster-packs-2026.08.18"

const MANIFEST_NAME = "booster-pack-manifest.json"

# NVIDIA's license requires this notice on distributed ACFs.
const NVIDIA_OUTPUT_NOTICE = "© NVIDIA Corporation, 2026."

const DEFAULT_CAVEATS = [
    "Validate correctness against a known-good reference before using any ACF.",
    "Compilation failures, wrong answers, and regressions are possible.",
]

"""
    BoosterPack

A read booster pack: `manifest` (the `booster-pack-manifest.json` document)
and `acfs`, `name => ACF` pairs in manifest order. Index with `pack[name]`,
iterate, or `keys(pack)`.
"""
struct BoosterPack
    manifest::Dict{String,Any}
    acfs::Vector{Pair{String,ACF}}
end

Base.length(p::BoosterPack) = length(p.acfs)
Base.iterate(p::BoosterPack, state...) = iterate(p.acfs, state...)
Base.eltype(::Type{BoosterPack}) = Pair{String,ACF}
Base.keys(p::BoosterPack) = first.(p.acfs)
Base.haskey(p::BoosterPack, name::AbstractString) = any(a -> first(a) == name, p.acfs)
function Base.getindex(p::BoosterPack, name::AbstractString)
    i = findfirst(a -> first(a) == name, p.acfs)
    i === nothing && throw(KeyError(name))
    last(p.acfs[i])
end
function Base.show(io::IO, p::BoosterPack)
    print(io, "BoosterPack(", repr(get(p.manifest, "pack_id", "?")), ", ", length(p), " ACFs",
          haskey(p.manifest, "cuda_version") ? ", CUDA $(p.manifest["cuda_version"])" : "", ")")
end

_acf_name(name::AbstractString) = endswith(name, ".acf") ? String(name[1:end-4]) : String(name)

_sha256_hex(bytes::AbstractVector{UInt8}) = bytes2hex(sha256(bytes))

_stages(stage::AbstractString) = stage == "both" ? ["nvcc", "ptxas"] : [String(stage)]

"""
    write_booster_pack(dest, acfs; pack_id, cuda_version, supported_gpus, kwargs...) -> dest

Write `acfs` (`name => ACF` pairs) as a booster pack: a `.zip` whose top-level
directory is named after the file, or a directory otherwise.

Keywords mirror NVIDIA's manifest. Required: `pack_id`, `cuda_version` (ACFs
only load in the toolkit version that produced them), `supported_gpus`.
Optional: `display_name`, `description`, `created_by`, `pack_type`
(`"performance"`/`"diagnostic"`), `controls_stage` (`"ptxas"`/`"nvcc"`/`"both"`),
`descriptions` (name → text), `caveats`, `validation_summary`, `release_tag`,
and `notice` (defaults to the copyright notice NVIDIA's license requires on
distributed ACFs).
"""
function write_booster_pack(dest::AbstractString, acfs;
                            pack_id::AbstractString, cuda_version::AbstractString,
                            supported_gpus::AbstractVector{<:AbstractString},
                            display_name::AbstractString=pack_id,
                            description::AbstractString="",
                            created_by::AbstractString="",
                            pack_type::AbstractString="performance",
                            controls_stage::AbstractString="ptxas",
                            descriptions::AbstractDict=Dict{String,String}(),
                            caveats::AbstractVector{<:AbstractString}=DEFAULT_CAVEATS,
                            validation_summary::Union{Nothing,AbstractDict}=nothing,
                            release_tag::Union{Nothing,AbstractString}=nothing,
                            notice::Union{Nothing,AbstractString}=NVIDIA_OUTPUT_NOTICE)
    pack_type in ("performance", "diagnostic") ||
        throw(ArgumentError("pack_type must be \"performance\" or \"diagnostic\""))
    controls_stage in ("ptxas", "nvcc", "both") ||
        throw(ArgumentError("controls_stage must be \"ptxas\", \"nvcc\" or \"both\""))
    entries = Pair{String,ACF}[_acf_name(name) => acf for (name, acf) in acfs]
    isempty(entries) && throw(ArgumentError("a booster pack needs at least one ACF"))
    allunique(first.(entries)) || throw(ArgumentError("ACF names must be unique"))
    for (name, _) in entries
        (isempty(name) || occursin(r"[/\\]", name)) && throw(ArgumentError("invalid ACF name $(repr(name))"))
    end

    manifest = Dict{String,Any}(
        "schema_version" => 1,
        "pack_id" => String(pack_id),
        "display_name" => String(display_name),
        "pack_type" => String(pack_type),
        "description" => String(description),
        "created_by" => String(created_by),
        "controls_stage" => String(controls_stage),
        "cuda_version" => String(cuda_version),
        "supported_gpus" => String.(supported_gpus),
        "caveats" => String.(caveats),
        "acfs" => [Dict{String,Any}(
            "filename" => name * ".acf",
            "sha256" => _sha256_hex(acf.bytes),
            "size_bytes" => length(acf.bytes),
            "compiler_stages" => _stages(controls_stage),
            "description" => String(get(descriptions, name, "$(display_name) controls for $(name)")),
        ) for (name, acf) in entries],
    )
    release_tag === nothing || (manifest["release_tag"] = String(release_tag))
    validation_summary === nothing || (manifest["validation_summary"] = Dict{String,Any}(validation_summary))
    notice === nothing || (manifest["notice"] = String(notice))

    function write_dir(dir)
        mkpath(dir)
        for (name, acf) in entries
            write(joinpath(dir, name * ".acf"), acf)
        end
        write(joinpath(dir, MANIFEST_NAME), JSON.json(manifest))
    end

    if endswith(dest, ".zip")
        dirname_in_zip = basename(dest)[1:end-4]
        isempty(dirname_in_zip) && throw(ArgumentError("zip file needs a name: $dest"))
        mktempdir() do tmp
            write_dir(joinpath(tmp, dirname_in_zip))
            zip = abspath(dest)
            rm(zip; force=true)
            mkpath(dirname(zip))
            run(Cmd(`$(p7zip_jll.p7zip()) a -tzip -bso0 -bsp0 $zip $dirname_in_zip`; dir=tmp))
        end
    else
        write_dir(dest)
    end
    return dest
end

"""
    read_booster_pack(path) -> BoosterPack

Read a booster pack from a `.zip` or a directory, checking each ACF against
the manifest's size and SHA-256.
"""
function read_booster_pack(path::AbstractString)
    isdir(path) && return _read_pack_dir(path)
    isfile(path) || error("booster pack not found: $path")
    mktempdir() do tmp
        run(`$(p7zip_jll.p7zip()) x $(abspath(path)) -o$tmp -y -bso0 -bsp0`)
        manifests = String[]
        for (root, _, files) in walkdir(tmp)
            MANIFEST_NAME in files && push!(manifests, root)
        end
        length(manifests) == 1 || error("expected exactly one $MANIFEST_NAME in $path, found $(length(manifests))")
        _read_pack_dir(manifests[1])
    end
end

function _read_pack_dir(dir::AbstractString)
    manifest_path = joinpath(dir, MANIFEST_NAME)
    isfile(manifest_path) || error("no $MANIFEST_NAME in $dir")
    manifest = JSON.parse(read(manifest_path, String); dicttype=Dict{String,Any})
    manifest isa Dict{String,Any} && haskey(manifest, "acfs") || error("malformed $manifest_path: no \"acfs\" list")
    acfs = Pair{String,ACF}[]
    for entry in manifest["acfs"]
        filename = String(entry["filename"])
        file = joinpath(dir, filename)
        isfile(file) || error("$filename listed in the manifest is missing from $dir")
        bytes = read(file)
        haskey(entry, "size_bytes") && entry["size_bytes"] != length(bytes) &&
            error("$filename has $(length(bytes)) bytes, manifest says $(entry["size_bytes"])")
        haskey(entry, "sha256") && lowercase(String(entry["sha256"])) != _sha256_hex(bytes) &&
            error("SHA-256 mismatch for $filename")
        push!(acfs, _acf_name(filename) => ACF(bytes))
    end
    BoosterPack(manifest, acfs)
end

"""
    booster_pack(name; tag=DEFAULT_BOOSTER_PACKS_TAG) -> BoosterPack

Download (cached) and read NVIDIA's `booster-pack-<name>.zip` from the `tag`
catalog release, verified against its `booster-pack-catalog.json`. Names at
the default tag: `"helion"`, `"debug"`.

ACFs load only in the toolkit version they were built for
(`pack.manifest["cuda_version"]`): the default tag targets CUDA 13.4,
`"booster-packs-2026.05.27"` targets 13.3. The debug pack's `ptxas_opt0` /
`ptxas_opt3` make a useful canary that an ACF reaches `ptxas`.
"""
function booster_pack(name::AbstractString; tag::AbstractString=DEFAULT_BOOSTER_PACKS_TAG)
    dir = joinpath(@get_scratch!("booster-packs"), tag)
    mkpath(dir)
    catalog_path = joinpath(dir, "booster-pack-catalog.json")
    isfile(catalog_path) || Downloads.download(release_asset_url(tag, "booster-pack-catalog.json"), catalog_path)
    catalog = JSON.parse(read(catalog_path, String))
    artifact = "booster-pack-$(name).zip"
    idx = findfirst(p -> p.artifact_name == artifact, catalog.packs)
    if idx === nothing
        names = join((replace(String(p.artifact_name), r"^booster-pack-|\.zip$" => "") for p in catalog.packs), ", ")
        error("no booster pack $(repr(name)) in $tag; available: $names")
    end
    pack = catalog.packs[idx]
    zip = joinpath(dir, artifact)
    if !_verified(zip, pack.artifact_sha256)
        Downloads.download(release_asset_url(tag, artifact), zip)
        _verified(zip, pack.artifact_sha256) || error("SHA-256 mismatch after downloading $artifact from $tag")
    end
    read_booster_pack(zip)
end
