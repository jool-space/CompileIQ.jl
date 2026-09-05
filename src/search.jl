# The client side of the core protocol.
#
# The client listens on a localhost TCP port and starts the core with that
# address in CIQ_HOST/CIQ_PORT; the core connects back. Then, per batch:
#
#   core → client   {"params":[{"id":0,"knobs":"…"},…],"invocation_id":i,"generation_num":g}
#   client → core   {"evaluated_params":[{"id":0,"scores":[12.5]},…]}\n
#
# and finally `{"complete":1}` (an integer, not a boolean). An invalid
# candidate's score is the string "*". Messages from the core are not
# newline-delimited, so the client accumulates bytes until they parse.

const INVALID_SCORE = "*"

"""
    Candidate

One evaluated point of a search: `generation`, the core's `id` in its evaluation
batch, the decoded `params` (an [`ACF`](@ref), a `Dict`, or a `Vector`
for mixed spaces) and `scores` — one `Float64` per objective, `missing` where
the candidate was invalid.
"""
struct Candidate
    generation::Int
    id::Int
    params::Any
    scores::Vector{Union{Missing,Float64}}
end

"""
    score(c::Candidate, objective=1)

The candidate's score for `objective`, or `missing` if it was invalid.
"""
score(c::Candidate, objective::Int=1) = c.scores[objective]
Base.isvalid(c::Candidate) = !any(ismissing, c.scores)

function Base.show(io::IO, c::Candidate)
    print(io, "Candidate(gen ", c.generation, " #", c.id, ": ",
          isvalid(c) ? join(c.scores, ", ") : "invalid", ")")
end

"""
    SearchResult

Everything a [`search`](@ref) evaluated, in order: `config`, `space`, and
`candidates`. Use [`best`](@ref) to pick the winner.
"""
struct SearchResult
    config::SearchConfig
    space::Any
    candidates::Vector{Candidate}
end

Base.length(r::SearchResult) = length(r.candidates)
Base.iterate(r::SearchResult, state...) = iterate(r.candidates, state...)
Base.eltype(::Type{SearchResult}) = Candidate

function Base.show(io::IO, r::SearchResult)
    n = length(r.candidates)
    valid = count(isvalid, r.candidates)
    gens = isempty(r.candidates) ? 0 : maximum(c -> c.generation, r.candidates) + 1
    b = best(r)
    print(io, "SearchResult(", gens, " generations, ", n, " candidates, ", valid, " valid",
          b === nothing ? "" : ", best = $(join(b.scores, ", "))", ")")
end

"""
    best(result::SearchResult; objective=1) -> Union{Candidate,Nothing}

The valid candidate with the lowest (`:min`) or highest (`:max`) score for
`objective`, or `nothing` if every candidate was invalid.
"""
function best(result::SearchResult; objective::Int=1)
    valid = filter(isvalid, result.candidates)
    isempty(valid) && return nothing
    by = c -> score(c, objective)
    result.config.problem_type === :min ? argmin(by, valid) : argmax(by, valid)
end

# ---------------------------------------------------------------------------
# Scores

function _wire_score(x::Real)
    value = Float64(x)
    return isfinite(value) ? value : INVALID_SCORE
end
_wire_score(::Missing) = INVALID_SCORE
_wire_score(::Nothing) = INVALID_SCORE
_wire_score(x) = throw(ArgumentError("objective must return a Real, missing, or a tuple/vector of those; got $(typeof(x))"))

# Objective return value → the per-objective list sent to the core.
function _wire_scores(value, num_objectives::Int)
    if value === missing || value === nothing
        return fill(INVALID_SCORE, num_objectives)
    end
    if value isa Union{Tuple,AbstractVector}
        length(value) == num_objectives ||
            throw(ArgumentError("objective returned $(length(value)) values for $num_objectives objectives"))
        return Any[_wire_score(v) for v in value]
    end
    num_objectives == 1 || throw(ArgumentError("objective must return $num_objectives values, got a scalar"))
    return Any[_wire_score(value)]
end

_recorded(s) = s === INVALID_SCORE ? missing : Float64(s)

function _evaluate(objective, params, config::SearchConfig, catch_errors::Bool)
    value = try
        objective(params)
    catch err
        (err isa InterruptException || !catch_errors) && rethrow()
        @warn "objective threw; treating candidate as invalid" exception = (err, catch_backtrace()) maxlog = 5
        missing
    end
    # Snapshot scores immediately: objectives may reuse a mutable output buffer.
    return Union{Missing,Float64}[_recorded.(_wire_scores(value, config.num_objectives))...]
end

# ---------------------------------------------------------------------------
# Search

"""
    search(objective, space; config=SearchConfig(), map=Base.map, catch_errors=true, progress=true, kwargs...)
    search(objective, space, config::SearchConfig; ...)

Run a CompileIQ search of `space` (an [`AbstractSearchSpace`](@ref), or a
vector of them for a mixed space), calling `objective(params)` on each
candidate. Keyword arguments other than the ones listed are passed to
[`SearchConfig`](@ref).

`objective` receives an [`ACF`](@ref) for compiler spaces, a nested `NamedTuple`
for a [`ParamSpace`](@ref), or a `Vector` of those for a mixed space. It
returns a `Real` — or a tuple with one entry per objective — and `missing` for
an invalid candidate (failed compile, wrong answer, timeout). Non-finite values
count as invalid. With `catch_errors=true` an exception from the objective also
marks the candidate invalid instead of aborting the search. Interrupts always
propagate. A scalar `missing` invalidates every objective.

Candidates of a batch are evaluated with `map(f, candidates)`; pass a
concurrent `map` (e.g. `asyncmap`, or one that dispatches to several GPUs) to
evaluate in parallel. The core is always driven sequentially.

`connect_timeout=30` and `io_timeout=60` bound core startup and socket I/O
in seconds; `nothing` disables either limit. Objective evaluation has no imposed
timeout. See [`Session`](@ref).

Returns a [`SearchResult`](@ref).

    result = search(PtxasSearchSpace("13.3"); generations=8, pool_size=16) do acf
        cubin, log = ptxas(ptx; arch="sm_89", acf, timeout=60)
        run_and_time(cubin)          # your kernel launch, correctness check, timing
    end
    write("best.acf", best(result).params)
"""
function search(objective, space; config::Union{Nothing,SearchConfig}=nothing, map=Base.map,
                catch_errors::Bool=true, progress::Bool=true, connect_timeout=30, io_timeout=60, kwargs...)
    config = _resolve_search_config(config, kwargs)
    search(objective, space, config; map, catch_errors, progress, connect_timeout, io_timeout)
end

function search(objective, space, config::SearchConfig; map=Base.map, catch_errors::Bool=true,
                progress::Bool=true, connect_timeout=30, io_timeout=60)
    candidates = Candidate[]
    Session(space, config; connect_timeout, io_timeout) do session
        while (batch = receive(session)) !== nothing
            params = [p.params for p in batch]
            values = collect(map(p -> _evaluate(objective, p, config, catch_errors), params))
            submit!(session, batch, values)
            for (proposal, scores) in zip(batch, values)
                push!(candidates, Candidate(batch.generation, proposal.id, proposal.params, scores))
            end
            if progress
                b = best(SearchResult(config, space, candidates))
                @info "CompileIQ generation $(batch.generation)" batch = batch.sequence candidates = length(batch) valid = count(isvalid, candidates[end-length(batch)+1:end]) best = (b === nothing ? missing : b.scores[1])
            end
        end
    end
    return SearchResult(config, space, candidates)
end

"""
    sample(space, n=1; config=SearchConfig()) -> Vector

Draw `n` candidates from `space` without searching — what the objective would
receive. Useful for a shape check of the objective before starting a search.
Accepts the same `connect_timeout` and `io_timeout` keywords as [`Session`](@ref).
"""
function sample(space, n::Integer=1; config::SearchConfig=SearchConfig(), connect_timeout=30, io_timeout=60)
    n > 0 || throw(ArgumentError("n must be positive"))
    # Same trick as the Python client: ask for one generation with a pool of at
    # least n and stop after the first message.
    probe = SearchConfig(; generations=1, problem_type=config.problem_type, num_objectives=1,
                         pool_size=max(Int(n), 6), cull_size=2, mutate_rate=config.mutate_rate,
                         init_with_true_random_threshold=config.init_with_true_random_threshold,
                         enable_large_fail_pool=config.enable_large_fail_pool)
    Session(space, probe; connect_timeout, io_timeout) do session
        batch = receive(session)
        batch === nothing && error("CompileIQ core finished without producing samples")
        return [p.params for p in batch.candidates[1:min(n, end)]]
    end
end
