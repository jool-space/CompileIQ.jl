# Stand-in for NVIDIA's `_core` binary, so the protocol can be tested without
# the proprietary download. Implements the core's side of the conversation:
#
#   * started as `fakecore.jl -c main_config.json`
#   * connects to CIQ_HOST:CIQ_PORT
#   * per generation, streams a `params` message (no trailing newline, like the
#     real core), then reads one newline-terminated `evaluated_params` reply
#   * finally sends `{"complete":1}`
#
# Candidates are derived from the search-space file(s): a `compileiq-search-space-v1`
# JSON space yields a JSON object of values (honouring knockouts on odd ids); anything
# else is treated as an opaque compiler space and yields a hex "ACF". Mixed spaces
# yield a JSON array of base64 payloads.

using Sockets, JSON
using Base64: base64encode

const config_path = ARGS[findfirst(==("-c"), ARGS)+1]
const config = JSON.parse(read(config_path, String))
const dna = config.dna_config isa AbstractString ? [String(config.dna_config)] : String.(config.dna_config)
const pool = get(config, "pool_size", 6)
const num_objectives = get(config, "num_objectives", 1)

function payload(path, i)
    doc = try
        JSON.parse(read(path, String))
    catch
        nothing
    end
    if doc isa JSON.Object && get(doc, "format", "") == "compileiq-search-space-v1"
        obj = Dict{String,Any}()
        for key in doc.parameter_layout
            key in ("{", "}") && continue
            cls = doc.classes[key]
            haskey(cls, "knockout_threshold") && isodd(i) && continue
            obj[key] = if cls.type == "range"
                cls.low + (i % 3) * cls.step
            elseif cls.type == "enum"
                cls.vals[1+i%length(cls.vals)]
            else
                cls.value
            end
        end
        return JSON.json(obj)
    end
    # Deterministic pseudo-ACF: 16 bytes derived from the candidate index.
    return bytes2hex(UInt8[(i * 7 + k) % 256 for k in 1:16])
end

function fail(sock, why)
    write(sock, JSON.json((; complete=0)))
    close(sock)
    println(stderr, "fakecore: ", why)
    exit(1)
end

sock = connect(ENV["CIQ_HOST"], parse(Int, ENV["CIQ_PORT"]))
# The client closes the socket when it aborts a search; exit quietly then.
try
for gen in 0:config.generations-1
    params = map(0:pool-1) do i
        knobs = length(dna) == 1 ? payload(dna[1], i) :
                JSON.json([base64encode(payload(p, i)) for p in dna])
        (; id=i, knobs)
    end
    # Split the message across two writes to exercise the client's reassembly.
    msg = JSON.json((; params, invocation_id=gen, generation_num=gen))
    write(sock, msg[1:end÷2]); flush(sock); sleep(0.01); write(sock, msg[end÷2+1:end]); flush(sock)

    reply = JSON.parse(readline(sock))
    haskey(reply, "evaluated_params") || fail(sock, "missing evaluated_params")
    ids = sort(Int[e.id for e in reply.evaluated_params])
    ids == collect(0:pool-1) || fail(sock, "ids $ids != 0:$(pool-1)")
    for e in reply.evaluated_params
        length(e.scores) == num_objectives || fail(sock, "candidate $(e.id) returned $(length(e.scores)) scores")
        all(s -> s isa Number || s == "*", e.scores) || fail(sock, "candidate $(e.id) has a non-numeric score $(e.scores)")
    end
end
write(sock, JSON.json((; complete=1)))
close(sock)
catch err
    err isa Union{Base.IOError,EOFError,ArgumentError} || rethrow()
    exit(0)
end
