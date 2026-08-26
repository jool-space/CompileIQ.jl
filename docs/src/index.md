```@meta
CurrentModule = CompileIQ
```

# CompileIQ

A pure-Julia client for [NVIDIA CompileIQ](https://github.com/NVIDIA/CompileIQ),
the autotuner for the internal controls of `ptxas` and `nvcc`.

```@docs
CompileIQ
```

## Searching

```@docs
search
sample
SearchConfig
SearchResult
Candidate
best
score
```

## Search spaces

```@docs
AbstractSearchSpace
PtxasSearchSpace
NvccSearchSpace
SearchSpaceFile
ParamSpace
Range
Choice
Literal
DEFAULT_SEARCH_SPACES_TAG
search_space_file
```

## Applying controls

```@docs
ACF
hex
ptxas
ptxas_path
ptxas_version
PtxasError
spill_bytes
```

## Booster packs

```@docs
BoosterPack
write_booster_pack
read_booster_pack
booster_pack
DEFAULT_BOOSTER_PACKS_TAG
```

## The core binary

```@docs
CORE_VERSION
core_dir
core_available
install_core!
core_launcher
```

## Protocol

The core is started as `_core -c main_config.json` with the client's
listening address in `CIQ_HOST`/`CIQ_PORT` and connects back over TCP. Per
generation it sends

```json
{"params":[{"id":0,"knobs":"<payload>"},…],"invocation_id":0,"generation_num":0}
```

and expects one newline-terminated reply

```json
{"evaluated_params":[{"id":0,"scores":[12.5]},…]}
```

where an invalid candidate's score is the string `"*"`. The search ends with
`{"complete":1}`. Payloads are hex ACFs for compiler spaces, JSON objects
(base64-encoded keys, nested keys joined with `_`) for a [`ParamSpace`](@ref),
and a JSON array of base64-encoded per-space payloads for mixed spaces.

```@docs
materialize
decode
core_config
search_space_json
```
