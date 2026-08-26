"""
    ACF(bytes::Vector{UInt8})
    ACF(hex::AbstractString)

An Advanced Controls File: an opaque blob of internal `ptxas`/`nvcc` compiler
controls produced by CompileIQ's core. The core hands candidates to the client
as hex strings; on disk (and on the `--apply-controls` command line) it is the
raw bytes.

    write("candidate.acf", acf)
    acf = read("candidate.acf", ACF)
    ptxas(ptx; arch="sm_89", acf)
"""
struct ACF
    bytes::Vector{UInt8}
end

ACF(hex::AbstractString) = ACF(hex2bytes(hex))

"""
    hex(acf::ACF) -> String

Hex encoding of the controls, the form the core exchanges over the wire.
"""
hex(acf::ACF) = bytes2hex(acf.bytes)

Base.write(io::IO, acf::ACF) = write(io, acf.bytes)
Base.write(path::AbstractString, acf::ACF) = write(path, acf.bytes)
Base.read(path::AbstractString, ::Type{ACF}) = ACF(read(path))

Base.:(==)(a::ACF, b::ACF) = a.bytes == b.bytes
Base.hash(a::ACF, h::UInt) = hash(a.bytes, hash(ACF, h))
Base.show(io::IO, a::ACF) = print(io, "ACF(", length(a.bytes), " bytes)")
