# CompileIQ

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://jool-space.github.io/CompileIQ.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://jool-space.github.io/CompileIQ.jl/dev/)
[![Build Status](https://github.com/jool-space/CompileIQ.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/jool-space/CompileIQ.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/jool-space/CompileIQ.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/jool-space/CompileIQ.jl)

Julia client for [NVIDIA CompileIQ](https://github.com/NVIDIA/CompileIQ), the
autotuner for `ptxas`/`nvcc` compiler controls (`--apply-controls`). Drives
NVIDIA's optimizer binary directly; objectives are Julia closures.

```julia
using CompileIQ
CompileIQ.install_core!()   # once

ptx = read("kernel.ptx", String)

result = search(PtxasSearchSpace("13.3"); generations=10, pool_size=16) do acf
    cubin, log = try
        ptxas(ptx; arch="sm_89", acf, timeout=60)
    catch err
        err isa PtxasError ? (return missing) : rethrow()
    end
    # load `cubin` with CuModule, check correctness, time it — or a compile-only proxy:
    CompileIQ.spill_bytes(log)
end

write("best.acf", best(result).params)
```

Objectives receive an `ACF` (compiler spaces), a `Dict{String,Any}`
(`CompileIQ.ParamSpace`), or a vector of those (mixed spaces), and return a
`Real`, a tuple for multiple objectives, or `missing` for an invalid candidate.

Booster packs — NVIDIA's zip format for curated ACFs — are read and written
with `CompileIQ.booster_pack`, `CompileIQ.read_booster_pack` and
`CompileIQ.write_booster_pack`. ACFs load only in the toolkit version that
produced them.

## Requirements

- Linux x86_64 or aarch64.
- `ptxas` ≥ CUDA 13.3 (`CUDA_Compiler_jll` by default).
- `CompileIQ.install_core!()`, once: downloads NVIDIA's `compileiq` wheel
  from PyPI (SHA-pinned) and extracts the optimizer binary. Search spaces
  and booster packs are fetched from NVIDIA's GitHub releases on demand.
  `CompileIQ.functional()` and `CompileIQ.versioninfo()` report the setup.

## License

This package is MIT and contains no NVIDIA code. The optimizer binary, search
spaces and ACFs are covered by the
[NVIDIA Software License Agreement](https://github.com/NVIDIA/CompileIQ/blob/main/LICENSE),
extracted next to the binary on install. It does not permit redistributing
the binary; ACFs may be distributed in binary form with the notice
`© NVIDIA Corporation, 2026.`.
