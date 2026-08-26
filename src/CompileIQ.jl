"""
    CompileIQ

Julia client for NVIDIA CompileIQ, the autotuner for `ptxas`/`nvcc` compiler
controls (`--apply-controls`). Drives NVIDIA's optimizer binary over its
socket protocol; objectives are Julia closures.

    result = search(PtxasSearchSpace("13.3"); generations=10, pool_size=16) do acf
        cubin, log = ptxas(ptx; arch="sm_89", acf)
        CompileIQ.spill_bytes(log)
    end
    write("best.acf", best(result).params)

Objectives receive an [`ACF`](@ref) for compiler spaces, a `Dict{String,Any}`
for a [`ParamSpace`](@ref), or a `Vector` of those for a mixed space, and
return a `Real`, a tuple for multiple objectives, or `missing` for an invalid
candidate.

Requires a one-time [`install_core!`](@ref); see [`functional`](@ref).
"""
module CompileIQ

using Sockets
using Base64: base64encode, base64decode
using SHA: sha256
using Downloads: Downloads
using JSON: JSON
using Scratch: @get_scratch!
using Preferences: @load_preference
import CUDA_Compiler_jll
import p7zip_jll

export search, best, ACF, PtxasSearchSpace, ptxas, PtxasError

public functional, versioninfo
public sample, SearchConfig, SearchResult, Candidate, score
public AbstractSearchSpace, NvccSearchSpace, SearchSpaceFile, ParamSpace, Range, Choice, Literal
public search_space_file, search_space_json, materialize, decode, DEFAULT_SEARCH_SPACES_TAG
public hex, ptxas_path, ptxas_version, spill_bytes
public BoosterPack, write_booster_pack, read_booster_pack, booster_pack, DEFAULT_BOOSTER_PACKS_TAG
public core_dir, core_available, install_core!, core_launcher, core_config, CORE_VERSION

include("acf.jl")
include("core.jl")
include("spaces.jl")
include("config.jl")
include("search.jl")
include("ptxas.jl")
include("boosterpack.jl")
include("diagnostics.jl")

end
