# Convenience wrapper around the `ptxas` from CUDA_Compiler_jll, the assembler
# that consumes ACFs. Loading the resulting cubin (CUDA.jl's `CuModule`) and
# launching it stay on the caller's side; this package has no GPU dependency.

"""
    ptxas_path() -> String

The `ptxas` executable from `CUDA_Compiler_jll`.
"""
function ptxas_path()
    CUDA_Compiler_jll.is_available() ||
        error("CUDA_Compiler_jll is not available on this platform; set the `ptxas` keyword to a ptxas executable")
    CUDA_Compiler_jll.ptxas_path
end

"""
    ptxas_version(ptxas=ptxas_path()) -> VersionNumber

Toolkit version of a `ptxas` executable, parsed from `ptxas --version`.
`--apply-controls` requires 13.3 or newer.
"""
function ptxas_version(exe::AbstractString=ptxas_path())
    out = read(`$exe --version`, String)
    m = match(r"release (\d+)\.(\d+)", out)
    m === nothing && error("could not parse ptxas version from:\n$out")
    VersionNumber(parse(Int, m[1]), parse(Int, m[2]))
end

"""
    PtxasError

Thrown by [`ptxas`](@ref) when assembly fails or times out. Carries the
command's combined output in `log` and the invocation in `cmd`.
"""
struct PtxasError <: Exception
    msg::String
    log::String
    cmd::Cmd
end
function Base.showerror(io::IO, e::PtxasError)
    print(io, "PtxasError: ", e.msg, "\n  command: ", e.cmd)
    isempty(e.log) || print(io, "\n", e.log)
end

"""
    ptxas(ptx::AbstractString; arch, acf=nothing, options=String[], verbose=true,
          timeout=nothing, ptxas=ptxas_path()) -> (cubin::Vector{UInt8}, log::String)

Assemble PTX source `ptx` for `arch` (e.g. `"sm_89"`), applying `acf` with
`--apply-controls` when given. Extra command-line `options` are appended.
`verbose=true` adds `--verbose`, which is what [`spill_bytes`](@ref) parses.

Some control combinations make `ptxas` hang; `timeout` (seconds) kills it and
throws a [`PtxasError`](@ref), as does a non-zero exit. In an objective, catch
`PtxasError` and return `missing`.
"""
function ptxas(ptx::AbstractString; arch::AbstractString, acf::Union{Nothing,ACF}=nothing,
               options=String[], verbose::Bool=true, timeout::Union{Nothing,Real}=nothing,
               ptxas::AbstractString=ptxas_path())
    mktempdir() do dir
        ptx_path = joinpath(dir, "kernel.ptx")
        cubin_path = joinpath(dir, "kernel.cubin")
        write(ptx_path, ptx)
        args = String[]
        verbose && push!(args, "--verbose")
        push!(args, "--gpu-name", String(arch))
        if acf !== nothing
            acf_path = joinpath(dir, "controls.acf")
            write(acf_path, acf)
            push!(args, "--apply-controls", acf_path)
        end
        append!(args, String.(options))
        push!(args, "--output-file", cubin_path, ptx_path)
        cmd = `$ptxas $args`

        out = Pipe()
        proc = run(pipeline(ignorestatus(cmd); stdout=out, stderr=out); wait=false)
        close(out.in)
        reader = @async read(out, String)
        if timeout === nothing
            wait(proc)
        else
            deadline = time() + timeout
            while process_running(proc) && time() < deadline
                sleep(0.01)
            end
            if process_running(proc)
                kill(proc)
                wait(proc)
                throw(PtxasError("timed out after $(timeout)s", fetch(reader), cmd))
            end
        end
        log = fetch(reader)
        success(proc) || throw(PtxasError("exited with code $(proc.exitcode)", log, cmd))
        return (read(cubin_path), log)
    end
end

"""
    spill_bytes(log::AbstractString) -> Int

Total spill traffic (stores + loads, in bytes) reported across all functions
in a `ptxas --verbose` log. A convenient compile-only objective: no GPU needed.
"""
function spill_bytes(log::AbstractString)
    total = 0
    for m in eachmatch(r"(\d+) bytes spill (?:stores|loads)", log)
        total += parse(Int, m[1])
    end
    total
end
