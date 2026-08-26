"""
    CompileIQ

Pure-Julia client for NVIDIA CompileIQ, the compiler autotuner behind
`ptxas --apply-controls`.

CompileIQ's optimizer is a closed binary (`_core`) that NVIDIA ships inside the
`compileiq` Python wheel. The wheel's Python package is only a thin client
that talks to that binary over a localhost socket. This package replaces the
Python client: it fetches the wheel, extracts the core, and speaks the same
newline-delimited JSON protocol, so an objective function is an ordinary Julia
closure running in the process that owns your CUDA context.

    using CompileIQ

    result = search(PtxasSearchSpace("13.3"); generations=10, pool_size=16) do acf
        cubin, log = ptxas(ptx; arch="sm_89", acf)   # throws PtxasError on failure
        spill_bytes(log)                              # lower is better
    end
    write("best.acf", best(result).params)

Objectives receive an [`ACF`](@ref) for compiler search spaces, a nested
`Dict{String,Any}` for a [`ParamSpace`](@ref), or a `Vector` of those for a
mixed space. Return a `Real` (or a tuple of them for multi-objective search),
or `missing` to mark the candidate invalid. Exceptions thrown by the objective
are treated as invalid candidates by default.

The core binary and search spaces are NVIDIA proprietary software, downloaded
from PyPI/GitHub on first use under NVIDIA's license; this package does not
redistribute them. See [`install_core!`](@ref).
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

export ACF
export PtxasSearchSpace, NvccSearchSpace, SearchSpaceFile, ParamSpace, Range, Choice, Literal
export SearchConfig, SearchResult, Candidate, search, sample, best
export ptxas, PtxasError, spill_bytes
export BoosterPack, write_booster_pack, read_booster_pack, booster_pack

include("acf.jl")
include("core.jl")
include("spaces.jl")
include("config.jl")
include("search.jl")
include("ptxas.jl")
include("boosterpack.jl")

end
