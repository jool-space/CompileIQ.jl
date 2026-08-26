# CompileIQ

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://jool-space.github.io/CompileIQ.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://jool-space.github.io/CompileIQ.jl/dev/)
[![Build Status](https://github.com/jool-space/CompileIQ.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/jool-space/CompileIQ.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/jool-space/CompileIQ.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/jool-space/CompileIQ.jl)

A pure-Julia client for [NVIDIA CompileIQ](https://github.com/NVIDIA/CompileIQ),
the autotuner for the internal controls of `ptxas` and `nvcc`
(`--apply-controls`).

CompileIQ's optimizer is a closed binary (`_core`) that NVIDIA ships inside
the `compileiq` Python wheel; the wheel's Python code is only a thin client
that talks to that binary over a localhost socket. This package speaks the
same protocol directly, so an objective function is an ordinary Julia closure
running in the process that owns your CUDA context.

```julia
using CompileIQ

ptx = read("kernel.ptx", String)

result = search(PtxasSearchSpace("13.3"); generations=10, pool_size=16) do acf
    cubin, log = try
        ptxas(ptx; arch="sm_89", acf, timeout=60)
    catch err
        err isa PtxasError && return missing     # invalid candidate
        rethrow()
    end
    # load `cubin` with CUDA.jl's CuModule, check the output, time it …
    CompileIQ.spill_bytes(log)                   # …or use a compile-only proxy
end

write("best.acf", best(result).params)
```

Objectives receive an `ACF` for compiler search spaces, a nested
`Dict{String,Any}` for a user-defined `CompileIQ.ParamSpace` (co-tuning tile
sizes and the like), or a `Vector` of those for a mixed space
`[space1, space2]`. Return a `Real` (a tuple for multi-objective search) or
`missing` for an invalid candidate.

Only the session-level names are exported (`search`, `best`, `ACF`,
`PtxasSearchSpace`, `ptxas`, `PtxasError`); the rest of the API is `public`
and used qualified. `CompileIQ.functional()` tells you whether a search can
run here and `CompileIQ.versioninfo()` what it would run with.

## Booster packs

A booster pack is NVIDIA's distribution format for curated ACFs: a zip of
`.acf` files plus `booster-pack-manifest.json`. Both directions are supported:

```julia
pack = CompileIQ.booster_pack("debug"; tag="booster-packs-2026.05.27")   # NVIDIA's, CUDA 13.3 builds
ptxas(ptx; arch="sm_89", acf=pack["ptxas_opt0"])                # canary: should be slower than no ACF
```

ACFs only load in the toolkit version they were produced with — a 13.4 pack
is rejected by a 13.3 `ptxas` — so check `pack.manifest["cuda_version"]`
against `CompileIQ.ptxas_version()`.

## Requirements

- Linux x86_64 or aarch64 (where NVIDIA publishes the core).
- `ptxas` ≥ CUDA 13.3 to apply the results; `ptxas` from `CUDA_Compiler_jll`
  is used by default.
- Network access on first use: the core (~34 MB wheel from PyPI) and the
  search-space `.bin` (from NVIDIA's GitHub releases) are downloaded to the
  package's scratch space. Point the `core` / `search_spaces_dir`
  preferences (or `COMPILEIQ_CORE` / `COMPILEIQ_SEARCH_SPACES_DIR`) at local
  copies to work offline.

## Licensing

The core binary and the search spaces are NVIDIA proprietary software under
the NVIDIA Software License Agreement bundled with the wheel; that license
permits installing and using them but not redistributing them. This package
therefore contains no NVIDIA code: it downloads the wheel on the user's
machine and extracts the core (the license text is placed next to it as
`LICENSE`). This package itself is MIT.
