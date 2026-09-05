"""
    Proposal

An unevaluated candidate: the core's batch-local `id` and decoded `params`.
Parameters have the same shape as the argument to a [`search`](@ref) objective.
Different IDs may carry equal parameters; they still require separate scores.
"""
struct Proposal
    id::Int
    params::Any
end

"""
    Batch

A batch received from a [`Session`](@ref). Contains a local `sequence` starting
at 1, the core's `generation` and `invocation_id`, and a vector of `candidates`
([`Proposal`](@ref)s). Iteration yields those proposals. A generation may span
multiple batches. Treat the candidate vector as read-only.

Pass the original batch to [`submit!`](@ref); a batch belongs to one session
and can only be submitted once.
"""
struct Batch
    sequence::Int
    generation::Int
    invocation_id::Int
    candidates::Vector{Proposal}
end

Base.length(b::Batch) = length(b.candidates)
Base.iterate(b::Batch, state...) = iterate(b.candidates, state...)
Base.eltype(::Type{Batch}) = Proposal
Base.show(io::IO, b::Batch) = print(io, "Batch(", b.sequence, ", generation ", b.generation,
                                   ", ", length(b), " candidates)")

"""
    CoreTimeoutError

A core connection or socket operation exceeded its time limit. Fields are
`operation` (`:connect`, `:receive`, or `:submit`) and `seconds`. The session
is closed when this exception is raised.
"""
struct CoreTimeoutError <: Exception
    operation::Symbol
    seconds::Float64
end
Base.showerror(io::IO, e::CoreTimeoutError) =
    print(io, "CompileIQ core ", e.operation, " timed out after ", e.seconds, " seconds")

"""
    Session(space; config=nothing, connect_timeout=30, io_timeout=60, kwargs...)
    Session(space, config::SearchConfig; connect_timeout=30, io_timeout=60)
    Session(f, space, [config]; kwargs...)

Start the core and accept its connection. `space` is any space accepted by
[`search`](@ref), including mixed spaces. Remaining keywords build a
[`SearchConfig`](@ref) when `config` is omitted.

[`receive`](@ref) returns one [`Batch`](@ref); [`submit!`](@ref) supplies its
scores. Only one batch may be outstanding. Call operations sequentially; the
session does not schedule evaluations or retain their history.

`connect_timeout` bounds the wait for the launched core to connect, excluding
installation. `io_timeout` bounds each receive or submission. Both are seconds;
`nothing` disables a limit. No timer runs while the caller evaluates a batch.

Use a do block, or `try`/`finally` with `close(session)`, to release resources
when stopping early. Normal completion and transport/protocol errors also
close the session. Closing abandons an outstanding batch without scoring it.

    Session(space; generations=2) do session
        while (batch = receive(session)) !== nothing
            scores = map(p -> objective(p.params), batch.candidates)
            submit!(session, batch, scores)
        end
    end
"""
mutable struct Session
    space::Any
    config::SearchConfig
    dir::String
    server::Union{Nothing,Sockets.TCPServer}
    process::Union{Nothing,Base.Process}
    socket::Union{Nothing,TCPSocket}
    io_timeout::Union{Nothing,Float64}
    state::Symbol
    sequence::Int
    pending::Union{Nothing,Batch}
    pending_ids::Vector{Int}
end

function _resolve_search_config(config, kwargs)
    config === nothing && return SearchConfig(; kwargs...)
    isempty(kwargs) || throw(ArgumentError("pass either config=SearchConfig(...) or SearchConfig keywords, not both"))
    return config
end

function _session_timeout(value, name)
    value === nothing && return nothing
    value isa Real || throw(ArgumentError("$name must be a positive number of seconds or nothing"))
    seconds = Float64(value)
    isfinite(seconds) && seconds > 0 || throw(ArgumentError("$name must be finite and positive"))
    return seconds
end

function Session(space; config::Union{Nothing,SearchConfig}=nothing,
                 connect_timeout=30, io_timeout=60, kwargs...)
    return Session(space, _resolve_search_config(config, kwargs); connect_timeout, io_timeout)
end

function Session(space, config::SearchConfig; connect_timeout=30, io_timeout=60)
    connect_timeout = _session_timeout(connect_timeout, "connect_timeout")
    io_timeout = _session_timeout(io_timeout, "io_timeout")
    session = Session(space, config, mktempdir(), nothing, nothing, nothing,
                      io_timeout, :starting, 0, nothing, Int[])
    try
        dna = materialize(space, session.dir)
        path = joinpath(session.dir, "main_config.json")
        write(path, JSON.json(core_config(config, dna)))
        session.server = listen(ip"127.0.0.1", 0)
        port = getsockname(session.server)[2]
        session.process = run(pipeline(core_cmd(path; host="127.0.0.1", port);
                                       stdout=devnull, stderr=stderr); wait=false)
        session.socket = _accept_core(session.server, session.process, connect_timeout)
        close(session.server)
        session.state = :ready
        return session
    catch
        close(session)
        rethrow()
    end
end

function Session(f::Function, space; kwargs...)
    session = Session(space; kwargs...)
    try
        return f(session)
    finally
        close(session)
    end
end
function Session(f::Function, space, config::SearchConfig; kwargs...)
    session = Session(space, config; kwargs...)
    try
        return f(session)
    finally
        close(session)
    end
end

Base.isopen(s::Session) = !(s.state in (:closed, :complete))
Base.show(io::IO, s::Session) = print(io, "Session(", s.state, ", ", s.sequence, " batches)")

# Timers only unblock socket operations; they do not bridge an objective loop.
function _accept_core(server, proc, timeout)
    started = time_ns()
    timed_out = Ref(false)
    watcher = Timer(0.01; interval=0.01) do _
        if process_exited(proc)
            close(server)
        elseif timeout !== nothing && (time_ns() - started) / 1e9 >= timeout
            timed_out[] = true
            close(server)
        end
    end
    try
        return accept(server)
    catch
        timed_out[] && throw(CoreTimeoutError(:connect, timeout))
        process_exited(proc) && error("CompileIQ core exited with code $(proc.exitcode) before connecting")
        rethrow()
    finally
        close(watcher)
    end
end

function _socket_operation(f, s::Session, operation::Symbol)
    expired = Ref(false)
    timer = s.io_timeout === nothing ? nothing : Timer(s.io_timeout) do _
        expired[] = true
        close(s.socket)
    end
    try
        result = f()
        expired[] && throw(CoreTimeoutError(operation, s.io_timeout))
        return result
    catch
        expired[] && throw(CoreTimeoutError(operation, s.io_timeout))
        rethrow()
    finally
        timer === nothing || close(timer)
    end
end

# Core messages have no delimiter. Track JSON containers and strings until a
# whole object arrives, then parse once. Malformed complete objects fail promptly.
function _receive(sock::TCPSocket, proc::Base.Process)
    buf = UInt8[]
    started, quoted, escaped = false, false, false
    depth = 0
    while true
        if eof(sock)
            exited = process_exited(proc) ? " (core exit code $(proc.exitcode))" : ""
            error("CompileIQ core closed the connection" * (isempty(buf) ? "" : " mid-message") * exited)
        end
        chunk = readavailable(sock)
        append!(buf, chunk)
        for byte in chunk
            if !started
                byte in (0x20, 0x09, 0x0a, 0x0d) && continue
                byte == 0x7b || error("CompileIQ core message must be a JSON object")
                started = true
            end
            if quoted
                if escaped
                    escaped = false
                elseif byte == 0x5c
                    escaped = true
                elseif byte == 0x22
                    quoted = false
                end
            elseif byte == 0x22
                quoted = true
            elseif byte in (0x7b, 0x5b)
                depth += 1
            elseif byte in (0x7d, 0x5d)
                depth -= 1
                depth == 0 && return JSON.parse(buf)
            end
        end
    end
end

function _send(sock::TCPSocket, response)
    write(sock, JSON.json(response), "\n")
    flush(sock)
end

"""
    receive(session) -> Union{Batch,Nothing}

Receive the next batch, or `nothing` after successful completion. Completion
releases the core and temporary files; subsequent receives also return `nothing`.
Calling before the pending batch is submitted, or after early close, is an error.
"""
function receive(s::Session)
    s.state === :complete && return nothing
    s.state === :pending && throw(ArgumentError("submit the pending batch before receiving another"))
    s.state === :ready || throw(ArgumentError("cannot receive from a $(s.state) session"))
    s.state = :receiving
    try
        msg = _socket_operation(s, :receive) do
            _receive(s.socket, s.process)
        end
        if haskey(msg, :complete)
            msg.complete == 1 || error("CompileIQ core reported a failed search")
            close(s)
            s.state = :complete
            return nothing
        end
        proposals = Proposal[Proposal(Int(p.id), decode(s.space, String(p.knobs))) for p in msg.params]
        isempty(proposals) && error("CompileIQ core returned an empty candidate batch")
        ids = Int[p.id for p in proposals]
        allunique(ids) || error("CompileIQ core returned duplicate candidate IDs within a batch")
        batch = Batch(s.sequence + 1, Int(msg.generation_num), Int(msg.invocation_id), proposals)
        s.sequence = batch.sequence
        s.pending = batch
        s.pending_ids = ids
        s.state = :pending
        return batch
    catch
        close(s)
        rethrow()
    end
end

"""
    submit!(session, batch, scores) -> Nothing

Submit one score per proposal in batch order. Each score is a `Real`, a
tuple/vector with one value per objective, or `missing`/`nothing` to invalidate
the entire candidate. Non-finite values invalidate their objective.

The original pending batch and exactly one score per ID are required. Validation
errors send nothing and leave the batch pending so the caller can correct the
submission. Socket errors close the session. Reordered or resized candidate
vectors are rejected. To stop without completing a batch, close the session.
"""
function submit!(s::Session, batch::Batch, scores)
    s.state === :pending && s.pending === batch ||
        throw(ArgumentError("batch is not the outstanding batch of this session"))
    Int[p.id for p in batch] == s.pending_ids || throw(ArgumentError("batch candidate order or IDs were modified"))
    values = collect(scores)
    length(values) == length(batch) || throw(ArgumentError("expected $(length(batch)) candidate scores, got $(length(values))"))
    evaluated = [(; id, scores=_wire_scores(value, s.config.num_objectives)) for (id, value) in zip(s.pending_ids, values)]
    s.state = :submitting
    try
        _socket_operation(s, :submit) do
            _send(s.socket, (; evaluated_params=evaluated))
        end
        s.pending = nothing
        empty!(s.pending_ids)
        s.state = :ready
        return nothing
    catch
        close(s)
        rethrow()
    end
end

"""
    close(session::Session)

Release sockets, terminate and wait for the core, and remove temporary files.
May be called repeatedly, including with an unsubmitted batch. It does not send
scores or wait for further proposals. Prefer the [`Session`](@ref) do-block form.
"""
function Base.close(s::Session)
    isopen(s) || return nothing
    s.state = :closed
    s.pending = nothing
    empty!(s.pending_ids)
    try
        s.socket === nothing || close(s.socket)
    finally
        try
            s.server === nothing || close(s.server)
        finally
            try
                if s.process !== nothing
                    # Let a completed core exit normally. SIGTERM makes Racket
                    # print a "user break" trace, so use SIGKILL if still alive.
                    timedwait(() -> process_exited(s.process), 0.2; pollint=0.01)
                    process_running(s.process) && kill(s.process, Base.SIGKILL)
                    wait(s.process)
                end
            finally
                rm(s.dir; recursive=true, force=true)
            end
        end
    end
    return nothing
end
