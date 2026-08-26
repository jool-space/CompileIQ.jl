"""
    SearchConfig(; generations=5, problem_type=:min, num_objectives=1, pool_size=32,
                   cull_size=24, mutate_rate=0.25, objective_weights=nothing,
                   init_with_true_random_threshold=0.9, enable_large_fail_pool=true)

Settings of the core's genetic search.

- `generations`: number of search iterations.
- `problem_type`: `:min` or `:max`.
- `num_objectives`: how many values the objective returns.
- `pool_size`: candidates evaluated per generation (> 5). Defaults to 32
  (more for many objectives), following the Python client.
- `cull_size`: even number (> 1) of candidates culled each generation, less
  than `pool_size` and leaving at least `1 + 2num_objectives` survivors.
  Defaults to 75% of `pool_size`, rounded down to even.
- `mutate_rate`: probability in (0, 1) that a candidate is perturbed.
- `objective_weights`: per-objective weights for multi-objective search.
- `init_with_true_random_threshold`: fraction of initial samples drawn from a
  [`Range`](@ref)'s `seed` sub-range rather than its full range.
- `enable_large_fail_pool`: grow the pool when fewer than 20% of a generation
  passes.

Score normalization (`normalize=True` in the Python client) is not supported;
scores are sent to the core as returned by the objective.
"""
Base.@kwdef struct SearchConfig
    generations::Int = 5
    problem_type::Symbol = :min
    num_objectives::Int = 1
    pool_size::Int = 0          # 0 → derived, see below
    cull_size::Int = 0
    mutate_rate::Float64 = 0.25
    objective_weights::Union{Nothing,Vector{Float64}} = nothing
    init_with_true_random_threshold::Float64 = 0.9
    enable_large_fail_pool::Bool = true

    function SearchConfig(generations, problem_type, num_objectives, pool_size, cull_size, mutate_rate,
                          objective_weights, init_with_true_random_threshold, enable_large_fail_pool)
        generations > 0 || throw(ArgumentError("generations must be positive"))
        problem_type in (:min, :max) || throw(ArgumentError("problem_type must be :min or :max"))
        num_objectives > 0 || throw(ArgumentError("num_objectives must be positive"))
        # The core asserts on these rather than defaulting them; this mirrors
        # the Python client's `set_pool_and_cull_sizes`.
        cull_pct = 0.75
        min_survivors = 1 + 2 * num_objectives
        if pool_size == 0
            pool_size = max(ceil(Int, min_survivors / (1 - cull_pct)), 32)
            pool_size += pool_size % 2
        end
        pool_size > 5 || throw(ArgumentError("pool_size must be greater than 5"))
        if cull_size == 0
            cull_size = floor(Int, pool_size * cull_pct)
            cull_size -= cull_size % 2
            max_cull = pool_size - min_survivors
            max_cull -= max_cull % 2
            cull_size = max(2, min(cull_size, max_cull))
        end
        (cull_size > 1 && iseven(cull_size)) ||
            throw(ArgumentError("cull_size must be an even number greater than 1"))
        cull_size < pool_size || throw(ArgumentError("cull_size ($cull_size) must be less than pool_size ($pool_size)"))
        pool_size - cull_size >= min_survivors ||
            throw(ArgumentError("pool_size - cull_size must leave at least $min_survivors survivors for $num_objectives objective(s)"))
        0 < mutate_rate < 1 || throw(ArgumentError("mutate_rate must be in (0, 1)"))
        objective_weights === nothing || length(objective_weights) == num_objectives ||
            throw(ArgumentError("objective_weights must have one entry per objective"))
        0 <= init_with_true_random_threshold <= 1 ||
            throw(ArgumentError("init_with_true_random_threshold must be in [0, 1]"))
        new(generations, problem_type, num_objectives, pool_size, cull_size, mutate_rate,
            objective_weights, init_with_true_random_threshold, enable_large_fail_pool)
    end
end

"""
    core_config(config::SearchConfig, dna_config) -> Dict{String,Any}

The `main_config.json` document handed to the core. `dna_config` is the
search-space path (or vector of paths) from [`materialize`](@ref).
"""
function core_config(config::SearchConfig, dna_config)
    d = Dict{String,Any}(
        "problem_type" => String(config.problem_type),
        "normalize" => false,
        "num_objectives" => config.num_objectives,
        "generations" => config.generations,
        "pool_size" => config.pool_size,
        "cull_size" => config.cull_size,
        "mutate_rate" => config.mutate_rate,
        "init_with_true_random_threshold" => config.init_with_true_random_threshold,
        "enable_large_fail_pool" => config.enable_large_fail_pool,
        "dna_config" => dna_config,
        "enable_result_file" => false,
    )
    config.objective_weights === nothing || (d["objective_weights"] = config.objective_weights)
    d
end
