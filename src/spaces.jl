# Search spaces. The core reads one file per space (`dna_config` in its
# config). Two kinds exist:
#
#   * compiler spaces — opaque `.bin` files NVIDIA publishes as GitHub release
#     assets. The core samples ACFs from them; the client just passes the file
#     through untouched and receives hex-encoded ACFs back.
#   * parameter spaces — user-defined JSON (`compileiq-search-space-v1`), for
#     co-tuning application parameters (tile sizes, hints). The core returns a
#     JSON object of sampled values.
#
# A mixed space is a vector of spaces; the core then returns a JSON array of
# base64-encoded per-space payloads, in order.

"""
    AbstractSearchSpace

A search space the core can sample from: [`PtxasSearchSpace`](@ref),
[`NvccSearchSpace`](@ref), [`SearchSpaceFile`](@ref) or [`ParamSpace`](@ref).
A `Vector` of spaces is a mixed space, sampled jointly.
"""
abstract type AbstractSearchSpace end

# ---------------------------------------------------------------------------
# Compiler search spaces (GitHub release assets)

"""
    DEFAULT_SEARCH_SPACES_TAG

GitHub release tag of NVIDIA's search-space catalog used by default. Each
catalog release carries `manifest.json` plus one `.bin` per compiler, version
and variant.
"""
const DEFAULT_SEARCH_SPACES_TAG = "search-spaces-2026.08.14"

const SEARCH_SPACES_REPO = "NVIDIA/CompileIQ"

"""
    PtxasSearchSpace(version="13.3"; variant=:default, tag=DEFAULT_SEARCH_SPACES_TAG)

NVIDIA's control space for `ptxas` from CUDA toolkit `version`
(`variant=:att` is the curated attention-kernel subset). Objectives receive
an [`ACF`](@ref). Fetched from the `tag` release on first use; the
`search_spaces_dir` preference or `COMPILEIQ_SEARCH_SPACES_DIR` names an
offline mirror holding `manifest.json` and the `.bin` files.
"""
struct PtxasSearchSpace <: AbstractSearchSpace
    version::String
    variant::Symbol
    tag::String
end
PtxasSearchSpace(version::AbstractString="13.3"; variant::Symbol=:default, tag::AbstractString=DEFAULT_SEARCH_SPACES_TAG) =
    PtxasSearchSpace(String(version), variant, String(tag))

"""
    NvccSearchSpace(version="13.3"; variant=:default, tag=DEFAULT_SEARCH_SPACES_TAG)

NVIDIA's published control space for `nvcc` (apply with
`nvcc --apply-controls`). See [`PtxasSearchSpace`](@ref).
"""
struct NvccSearchSpace <: AbstractSearchSpace
    version::String
    variant::Symbol
    tag::String
end
NvccSearchSpace(version::AbstractString="13.3"; variant::Symbol=:default, tag::AbstractString=DEFAULT_SEARCH_SPACES_TAG) =
    NvccSearchSpace(String(version), variant, String(tag))

const CompilerSearchSpace = Union{PtxasSearchSpace,NvccSearchSpace}
compiler_name(::PtxasSearchSpace) = "ptxas"
compiler_name(::NvccSearchSpace) = "nvcc"

"""
    SearchSpaceFile(path)

A search-space file already in a core-readable format: a downloaded `.bin`, or
a `compileiq-search-space-v1` JSON file. Objectives receive an [`ACF`](@ref)
when the core's payload is hex, a `Dict{String,Any}` when it is a JSON object
(keys are passed through verbatim), or the raw `String` otherwise.
"""
struct SearchSpaceFile <: AbstractSearchSpace
    path::String
    SearchSpaceFile(path::AbstractString) = new(abspath(expanduser(path)))
end

release_asset_url(tag, name) = "https://github.com/$(SEARCH_SPACES_REPO)/releases/download/$(tag)/$(name)"

function _search_spaces_dir(tag::AbstractString)
    for value in (@load_preference("search_spaces_dir", nothing), get(ENV, "COMPILEIQ_SEARCH_SPACES_DIR", nothing))
        value === nothing && continue
        dir = expanduser(value)
        isfile(joinpath(dir, "manifest.json")) || error("search-space mirror $dir has no manifest.json")
        return dir, false
    end
    return joinpath(@get_scratch!("search-spaces"), tag), true
end

function _verified(path, expected_sha)
    isfile(path) || return false
    return bytes2hex(open(sha256, path)) == expected_sha
end

"""
    search_space_file(space::PtxasSearchSpace) -> String
    search_space_file(space::NvccSearchSpace) -> String

Path of the cached `.bin` for `space`, downloading and SHA-256-verifying it
against the catalog's `manifest.json` if necessary.
"""
function search_space_file(space::CompilerSearchSpace)
    dir, online = _search_spaces_dir(space.tag)
    manifest = joinpath(dir, "manifest.json")
    if !isfile(manifest)
        mkpath(dir)
        Downloads.download(release_asset_url(space.tag, "manifest.json"), manifest)
    end
    entries = JSON.parse(read(manifest, String)).entries
    compiler = compiler_name(space)
    variant = String(space.variant)
    idx = findfirst(e -> e.compiler == compiler && e.compiler_version == space.version && e.variant == variant, entries)
    if idx === nothing
        available = join(("$(e.compiler) $(e.compiler_version) ($(e.variant))" for e in entries), ", ")
        error("no $compiler $(space.version) ($variant) search space in $(space.tag); available: $available")
    end
    entry = entries[idx]
    path = joinpath(dir, String(entry.filename))
    _verified(path, entry.sha256) && return path
    online || error("$(path) is missing or fails its SHA-256 check in the local search-space mirror")
    Downloads.download(release_asset_url(space.tag, entry.filename), path)
    _verified(path, entry.sha256) || error("SHA-256 mismatch after downloading $(entry.filename) from $(space.tag)")
    return path
end

# ---------------------------------------------------------------------------
# Parameter search spaces (user-defined)

abstract type Param end

# The core drops a parameter from a sample with probability `knockout`; the
# file records the complementary threshold.
_knockout_threshold(p::Nothing) = nothing
function _knockout_threshold(p::Real)
    0 <= p <= 1 || throw(ArgumentError("knockout probability must be in [0, 1], got $p"))
    round(1 - Float64(p); digits=10)
end

"""
    Range(low, high; step=1, seed=nothing, knockout=nothing)

Numeric parameter sampled from `low:step:high`. `seed=(lo, hi)` narrows the
sub-range that most initial samples (90% by default, see
[`SearchConfig`](@ref)) are drawn from. `knockout` is the probability the
parameter is omitted from a sample.
"""
struct Range <: Param
    low::Real
    high::Real
    step::Real
    seed::Union{Nothing,Tuple{Real,Real}}
    knockout::Union{Nothing,Float64}
end
function Range(low::Real, high::Real; step::Real=1, seed=nothing, knockout=nothing)
    step > 0 || throw(ArgumentError("step must be positive"))
    low <= high || throw(ArgumentError("low must not exceed high"))
    Range(low, high, step, seed === nothing ? nothing : (seed[1], seed[2]), _knockout_threshold(knockout))
end

"""
    Choice(values...; knockout=nothing)
    Choice(values::AbstractVector; knockout=nothing)

Categorical parameter: one of `values` (numbers, strings or booleans).
"""
struct Choice <: Param
    vals::Vector{Any}
    knockout::Union{Nothing,Float64}
    # Explicit so that `Choice(1, 2)` reaches the varargs method below instead
    # of the default two-field constructor.
    Choice(vals::AbstractVector, knockout::Union{Nothing,Float64}) = new(Any[vals...], knockout)
end
Choice(vals::AbstractVector; knockout=nothing) = Choice(vals, _knockout_threshold(knockout))
Choice(vals...; knockout=nothing) = Choice(collect(Any, vals), _knockout_threshold(knockout))

"""
    Literal(value; knockout=nothing)

A constant, mainly useful with `knockout` to test presence/absence.
"""
struct Literal <: Param
    value::Union{Real,String}
    knockout::Union{Nothing,Float64}
end
Literal(value; knockout=nothing) = Literal(value, _knockout_threshold(knockout))

"""
    ParamSpace(pairs...)

User-defined search space over named parameters, for co-tuning application
parameters with (or without) a compiler space:

    space = ParamSpace(
        "tile" => Choice(64, 128, 256),
        "stages" => Range(2, 6),
        "load" => ParamSpace("latency" => Choice(1, 4, 8)),   # nesting is allowed
    )

Objectives receive a `Dict{String,Any}` with the same nesting; knocked-out
parameters are absent.
"""
struct ParamSpace <: AbstractSearchSpace
    params::Vector{Pair{String,Union{Param,ParamSpace}}}
end
ParamSpace(pairs::Pair...) = ParamSpace(Pair{String,Union{Param,ParamSpace}}[String(k) => v for (k, v) in pairs])

Base.:(==)(a::ParamSpace, b::ParamSpace) = a.params == b.params
Base.:(==)(a::Range, b::Range) = (a.low, a.high, a.step, a.seed, a.knockout) == (b.low, b.high, b.step, b.seed, b.knockout)
Base.:(==)(a::Choice, b::Choice) = (a.vals, a.knockout) == (b.vals, b.knockout)
Base.:(==)(a::Literal, b::Literal) = (a.value, a.knockout) == (b.value, b.knockout)

# Keys are transported base64-encoded, nested paths joined with `_`. Base64's
# alphabet has no `_`, so the join is unambiguous.
encode_key(key::AbstractString) = base64encode(key)
decode_key(key::AbstractString) = String(base64decode(key))

function _param_json(p::Range)
    d = Dict{String,Any}("type" => "range", "low" => p.low, "high" => p.high, "step" => p.step)
    if p.seed !== nothing
        d["seed-low"], d["seed-high"] = p.seed
    end
    p.knockout === nothing || (d["knockout_threshold"] = p.knockout)
    d
end
function _param_json(p::Choice)
    d = Dict{String,Any}("type" => "enum", "vals" => p.vals)
    p.knockout === nothing || (d["knockout_threshold"] = p.knockout)
    d
end
function _param_json(p::Literal)
    d = Dict{String,Any}("type" => "literal", "value" => p.value)
    p.knockout === nothing || (d["knockout_threshold"] = p.knockout)
    d
end

function _flatten!(classes, layout, space::ParamSpace, prefix::String)
    for (name, p) in space.params
        key = isempty(prefix) ? encode_key(name) : prefix * "_" * encode_key(name)
        if p isa ParamSpace
            _flatten!(classes, layout, p, key)
        else
            classes[key] = _param_json(p)
            push!(layout, key)
        end
    end
end

"""
    search_space_json(space::ParamSpace) -> String

The `compileiq-search-space-v1` document the core reads for `space`.
"""
function search_space_json(space::ParamSpace)
    classes = Dict{String,Any}()
    layout = String["{"]
    _flatten!(classes, layout, space, "")
    push!(layout, "}")
    JSON.json((; format="compileiq-search-space-v1", classes, parameter_layout=layout))
end

# ---------------------------------------------------------------------------
# Materializing spaces for the core and decoding what it sends back

"""
    materialize(space, dir) -> String
    materialize(spaces::AbstractVector, dir) -> Vector{String}

Write the core-readable file(s) for `space` into `dir` and return the path(s)
to put in the core config's `dna_config`.
"""
function materialize(space::AbstractSearchSpace, dir::AbstractString; index::Union{Nothing,Int}=nothing)
    name = index === nothing ? "search_space.json" : "$(index)_search_space.json"
    path = joinpath(dir, name)
    _materialize(space, path)
    return path
end
materialize(spaces::AbstractVector, dir::AbstractString) =
    String[materialize(s, dir; index=i - 1) for (i, s) in enumerate(spaces)]

_materialize(space::CompilerSearchSpace, path) = cp(search_space_file(space), path)
_materialize(space::SearchSpaceFile, path) = (isfile(space.path) || error("search-space file not found: $(space.path)"); cp(space.path, path))
_materialize(space::ParamSpace, path) = write(path, search_space_json(space))

"""
    decode(space, knobs::AbstractString)

Turn the core's raw candidate payload into what the objective receives.
"""
decode(::CompilerSearchSpace, knobs::AbstractString) = ACF(knobs)

function decode(::SearchSpaceFile, knobs::AbstractString)
    # Hex before JSON: a digits-only hex string such as "0007000e0015" parses
    # as a JSON number in exponent notation.
    all(isxdigit, knobs) && iseven(length(knobs)) && !isempty(knobs) && return ACF(knobs)
    if startswith(lstrip(knobs), ('{', '['))
        parsed = try
            JSON.parse(knobs; dicttype=Dict{String,Any})
        catch
            nothing
        end
        parsed === nothing || return parsed
    end
    return String(knobs)
end

function decode(::ParamSpace, knobs::AbstractString)
    flat = JSON.parse(knobs; dicttype=Dict{String,Any})
    flat isa Dict || error("expected a JSON object for a ParamSpace candidate, got: $(repr(knobs))")
    restored = Dict{String,Any}()
    for (key, value) in flat
        path = decode_key.(split(key, "_"))
        node = restored
        for name in path[1:end-1]
            node = get!(node, name, Dict{String,Any}())::Dict{String,Any}
        end
        node[path[end]] = value
    end
    restored
end

function decode(spaces::AbstractVector, knobs::AbstractString)
    parts = JSON.parse(knobs)
    parts isa AbstractVector && length(parts) == length(spaces) ||
        error("expected a JSON array of $(length(spaces)) payloads for a mixed space, got: $(repr(knobs))")
    Any[decode(space, String(base64decode(String(part)))) for (space, part) in zip(spaces, parts)]
end
