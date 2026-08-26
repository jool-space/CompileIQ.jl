# The client side of the core protocol.
#
# The client listens on a localhost TCP port and starts the core with that
# address in CIQ_HOST/CIQ_PORT; the core connects back. Then, per generation:
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

One evaluated point of a search: `generation`, the core's `id` within that
generation, the decoded `params` (an [`ACF`](@ref), a `Dict`, or a `Vector`
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
# Core session

function _receive(sock::TCPSocket, proc::Base.Process)
    buf = UInt8[]
    while true
        if eof(sock)
            exited = process_exited(proc) ? " (core exit code $(proc.exitcode))" : ""
            error("CompileIQ core closed the connection" * (isempty(buf) ? "" : " mid-message") * exited)
        end
        append!(buf, readavailable(sock))
        msg = try
            JSON.parse(buf)
        catch
            nothing   # incomplete; keep reading
        end
        msg === nothing || return msg
    end
end

function _send(sock::TCPSocket, response)
    write(sock, JSON.json(response), "\n")
    flush(sock)
end

# Run `body(sock, proc)` against a freshly started core configured with `space`
# and `config`. Temporary files and the process are cleaned up afterwards.
function withcore(body, space, config::SearchConfig)
    dir = mktempdir()
    try
        dna = materialize(space, dir)
        config_path = joinpath(dir, "main_config.json")
        write(config_path, JSON.json(core_config(config, dna)))

        server = listen(ip"127.0.0.1", 0)
        port = getsockname(server)[2]
        proc = run(pipeline(core_cmd(config_path; host="127.0.0.1", port); stdout=devnull, stderr=stderr); wait=false)
        sock = nothing
        try
            accepting = @async accept(server)
            while !istaskdone(accepting)
                process_exited(proc) && error("CompileIQ core exited with code $(proc.exitcode) before connecting")
                sleep(0.02)
            end
            sock = fetch(accepting)
            return body(sock, proc)
        finally
            sock === nothing || close(sock)
            close(server)
            # Give the core a moment to exit on its own, then SIGKILL like the
            # Python client does: SIGTERM makes the Racket runtime dump a
            # "user break" trace to stderr.
            for _ in 1:50
                process_running(proc) || break
                sleep(0.01)
            end
            process_running(proc) && kill(proc, Base.SIGKILL)
        end
    finally
        rm(dir; recursive=true, force=true)
    end
end

# ---------------------------------------------------------------------------
# Scores

_wire_score(x::Real) = isfinite(x) ? Float64(x) : INVALID_SCORE
_wire_score(::Missing) = INVALID_SCORE
_wire_score(::Nothing) = INVALID_SCORE
_wire_score(x) = throw(ArgumentError("objective must return a Real, missing, or a tuple/vector of those; got $(typeof(x))"))

# Objective return value → the per-objective list sent to the core.
function _wire_scores(value, num_objectives::Int)
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
        catch_errors || rethrow()
        @warn "objective threw; treating candidate as invalid" exception = (err, catch_backtrace()) maxlog = 5
        missing
    end
    _wire_scores(value, config.num_objectives)
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

`objective` receives an [`ACF`](@ref) for compiler spaces, a `Dict{String,Any}`
for a [`ParamSpace`](@ref), or a `Vector` of those for a mixed space. It
returns a `Real` — or a tuple with one entry per objective — and `missing` for
an invalid candidate (failed compile, wrong answer, timeout). Non-finite values
count as invalid. With `catch_errors=true` an exception from the objective also
marks the candidate invalid instead of aborting the search.

Candidates of a generation are evaluated with `map(f, candidates)`; pass a
concurrent `map` (e.g. `asyncmap`, or one that dispatches to several GPUs) to
evaluate in parallel. The core is always driven sequentially.

Returns a [`SearchResult`](@ref).

    result = search(PtxasSearchSpace("13.3"); generations=8, pool_size=16) do acf
        cubin, log = ptxas(ptx; arch="sm_89", acf, timeout=60)
        run_and_time(cubin)          # your kernel launch, correctness check, timing
    end
    write("best.acf", best(result).params)
"""
function search(objective, space; config::Union{Nothing,SearchConfig}=nothing, map=Base.map,
                catch_errors::Bool=true, progress::Bool=true, kwargs...)
    if config === nothing
        config = SearchConfig(; kwargs...)
    elseif !isempty(kwargs)
        throw(ArgumentError("pass either config=SearchConfig(...) or SearchConfig keywords, not both"))
    end
    search(objective, space, config; map, catch_errors, progress)
end

function search(objective, space, config::SearchConfig; map=Base.map, catch_errors::Bool=true, progress::Bool=true)
    candidates = Candidate[]
    withcore(space, config) do sock, proc
        while true
            msg = _receive(sock, proc)
            if haskey(msg, :complete)
                Bool(msg.complete) || error("CompileIQ core reported a failed search")
                break
            end
            generation = Int(msg.generation_num)
            params = [decode(space, String(c.knobs)) for c in msg.params]
            scores = map(p -> _evaluate(objective, p, config, catch_errors), params)
            evaluated = Any[]
            for (c, p, s) in zip(msg.params, params, scores)
                push!(candidates, Candidate(generation, Int(c.id), p, Union{Missing,Float64}[_recorded.(s)...]))
                push!(evaluated, (; id=Int(c.id), scores=s))
            end
            if progress
                result = SearchResult(config, space, candidates)
                b = best(result)
                @info "CompileIQ generation $generation" candidates = length(params) valid = count(isvalid, candidates[end-length(params)+1:end]) best = (b === nothing ? missing : b.scores[1])
            end
            _send(sock, (; evaluated_params=evaluated))
        end
    end
    SearchResult(config, space, candidates)
end

"""
    sample(space, n=1; config=SearchConfig()) -> Vector

Draw `n` candidates from `space` without searching — what the objective would
receive. Useful for a shape check of the objective before starting a search.
"""
function sample(space, n::Integer=1; config::SearchConfig=SearchConfig())
    n > 0 || throw(ArgumentError("n must be positive"))
    # Same trick as the Python client: ask for one generation with a pool of at
    # least n and stop after the first message.
    probe = SearchConfig(; generations=1, problem_type=config.problem_type, num_objectives=1,
                         pool_size=max(Int(n), 6), cull_size=2, mutate_rate=config.mutate_rate,
                         init_with_true_random_threshold=config.init_with_true_random_threshold,
                         enable_large_fail_pool=config.enable_large_fail_pool)
    withcore(space, probe) do sock, proc
        msg = _receive(sock, proc)
        haskey(msg, :complete) && error("CompileIQ core finished without producing samples")
        [decode(space, String(c.knobs)) for c in msg.params[1:min(n, end)]]
    end
end
