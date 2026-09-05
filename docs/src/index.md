```@meta
CurrentModule = CompileIQ
```

# CompileIQ

A pure-Julia client for [NVIDIA CompileIQ](https://github.com/NVIDIA/CompileIQ),
the autotuner for the internal controls of `ptxas` and `nvcc`.

```@docs
CompileIQ
```

## Setup

```@docs
functional
versioninfo
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

## Driving batches explicitly

`search` evaluates its objective internally. `Session` exposes the same core
protocol to callers that own evaluation and scheduling:

```julia
using CompileIQ: Session, receive, submit!, ParamSpace, Range

space = ParamSpace(x=Range(-5, 5))
Session(space; generations=2, pool_size=6) do session
    while (batch = receive(session)) !== nothing
        scores = [(p.params.x - 2)^2 for p in batch]
        submit!(session, batch, scores)
    end
end
```

`receive` returns decoded proposals, with IDs kept separate from their
parameters. Equal parameters can have distinct IDs. A generation can produce
multiple batches; use `batch.sequence` to distinguish them locally and preserve
`generation` and `invocation_id` as upstream metadata.

Submit the original batch and one score per proposal in its original order.
Validation errors leave the batch pending for correction. Successful completion,
transport errors, and the do block's exit release the core and temporary files.
Breaking the loop can abandon a batch without assigning scores to unmeasured
candidates. An explicitly closed session rejects further operations; a completed
session continues to return `nothing` from `receive`.

`connect_timeout=30` bounds connection after launching the subprocess.
`io_timeout=60` bounds each receive or submission. Both are seconds and accept
`nothing` to disable them. They do not bound installation or evaluation time.
Operations on a session must be called sequentially. Evaluation itself may use
any scheduler, provided scores are returned in batch order.

```@docs
Session
Proposal
Batch
receive
submit!
Base.close(::Session)
CoreTimeoutError
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

The first `search` or `sample` automatically downloads the pinned NVIDIA wheel
directly from PyPI, verifies it, and extracts the optimizer and shared library
into a local Julia artifact. Python is not required. The wheel's `LICENSE` and
`NOTICE` accompany the artifact. Call `install_core!()` to prefetch for offline
use; loading CompileIQ and querying diagnostics do not install the core.

Artifact bindings live in scratch space without download metadata. Existing
core preferences, `COMPILEIQ_CORE` overrides, and scratch installs are honored.

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
batch it sends

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
