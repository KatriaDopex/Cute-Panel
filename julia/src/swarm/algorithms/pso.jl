"""
PSO.jl - Placeholder for Particle Swarm Optimization Algorithm
"""
module PSOAlgorithmImpl # Using a more specific module name

using Logging
# This will need access to SwarmBase types.
# Assuming SwarmBase.jl is in the parent directory (../SwarmBase.jl)
# or that types are re-exported by a higher-level module.
# For direct relative import if SwarmBase is in `julia/src/swarm/`
try
    using ...swarm.SwarmBase # Relative path from algorithms/ to swarm/
    # Or if SwarmBase is directly in src: using ..SwarmBase
    # This depends on how Swarms.jl includes SwarmBase.jl
    # Let's assume SwarmBase is accessible via the framework or a common parent.
    # For now, to ensure it compiles if run standalone for testing:
    # include("../SwarmBase.jl") # This is not ideal for module structure
    # using .SwarmBase
    # Correct approach: Swarms.jl includes SwarmBase.jl, and this file is included by Swarms.jl
    # or SwarmBase is a registered package/module.
    # For now, assuming SwarmBase types are available in the scope where this module is used.
    # If this file is `include`d by `Swarms.jl`, and `Swarms.jl` does `using .SwarmBase`, then it's fine.
    # Let's assume the types are available via `Main.CutePanelFramework.SwarmBase` or similar.
    # For the purpose of this file, we'll assume SwarmBase is directly usable.
    # This will be resolved when _instantiate_algorithm loads it.
    # For now, to make it self-contained for thought:
    # This is a common issue with structuring Julia projects with sub-modules.
    # The `using ..SwarmBase` would be correct if `algorithms` is a sub-module of `swarm`.
    # If `Swarms.jl` does `include("algorithms/PSO.jl")`, then `SwarmBase` types are in its scope.
    # Let's write it assuming it's included by Swarms.jl which has `using .SwarmBase`.
    # So, SwarmBase.AbstractSwarmAlgorithm should be accessible.
    # No, this module will be `using`d by Swarms.jl, so it needs its own `using`.
    # The path from `julia/src/swarm/algorithms/PSO.jl` to `julia/src/swarm/SwarmBase.jl` is `../SwarmBase.jl`.
    # So, `using ..SwarmBase` if `algorithms` is a submodule of `swarm`.
    # If `algorithms` is a sibling of `swarm` under `src`, then `using ..swarm.SwarmBase`.
    # Given the current structure, `algorithms` will be a subdirectory of `swarm`.
    using ..SwarmBase # Correct if PSO.jl is in swarm/algorithms/ and SwarmBase.jl is in swarm/
    
catch e
    @warn "PSOAlgorithmImpl: Could not load SwarmBase. Using minimal stubs."
    abstract type AbstractSwarmAlgorithm end
    struct OptimizationProblem end
    struct SwarmSolution end
end


export PSOAlgorithm # Export the algorithm type

mutable struct Particle
    position::Vector{Float64}
    velocity::Vector{Float64}
    best_position::Vector{Float64}
    best_fitness::Float64
    current_fitness::Float64

    Particle(dims::Int) = new(zeros(dims), zeros(dims), zeros(dims), Inf, Inf)
end

mutable struct PSOAlgorithm <: AbstractSwarmAlgorithm
    num_particles::Int
    inertia_weight::Float64
    cognitive_coeff::Float64 # c1
    social_coeff::Float64    # c2
    particles::Vector{Particle}
    global_best_position::Vector{Float64}
    global_best_fitness::Float64
    problem_ref::Union{OptimizationProblem, Nothing} # Keep a reference
    velocity_clamping_factor::Float64 # Factor to determine max velocity based on dimensional range

    function PSOAlgorithm(; num_particles::Int=30, inertia::Float64=0.7, c1::Float64=1.5, c2::Float64=1.5, vel_clamp_factor::Float64=0.2)
        0.0 < vel_clamp_factor <= 1.0 || error("Velocity clamping factor must be between 0 (exclusive) and 1 (inclusive).")
        new(num_particles, inertia, c1, c2, [], [], [], Inf, nothing, vel_clamp_factor)
    end
end

function SwarmBase.initialize!(alg::PSOAlgorithm, problem::OptimizationProblem, agents::Vector{String}, config_params::Dict)
    alg.problem_ref = problem
    alg.particles = [Particle(problem.dimensions) for _ in 1:alg.num_particles]
    alg.global_best_position = zeros(problem.dimensions)
    alg.global_best_fitness = problem.is_minimization ? Inf : -Inf

    for p in alg.particles
        # Initialize position within bounds
        for d in 1:problem.dimensions
            p.position[d] = problem.bounds[d][1] + rand() * (problem.bounds[d][2] - problem.bounds[d][1])
        end
        p.velocity .= 0.0 # Initialize velocity (or small random)
        p.best_position = copy(p.position)
        # Initial fitness evaluation (conceptual - would involve agents if distributed)
        p.current_fitness = problem.objective_function(p.position)
        p.best_fitness = p.current_fitness

        if problem.is_minimization
            if p.best_fitness < alg.global_best_fitness
                alg.global_best_fitness = p.best_fitness
                alg.global_best_position = copy(p.best_position)
            end
        else # Maximization
            if p.best_fitness > alg.global_best_fitness
                alg.global_best_fitness = p.best_fitness
                alg.global_best_position = copy(p.best_position)
            end
        end
    end
    @info "PSOAlgorithm initialized with $(alg.num_particles) particles."
end

"""
    get_all_particle_positions(alg::PSOAlgorithm)::Vector{Vector{Float64}}

Returns a list of current positions for all particles. Used by Swarm Manager for evaluation.
"""
function SwarmBase.get_all_particle_positions(alg::PSOAlgorithm)::Vector{Vector{Float64}}
    return [copy(p.position) for p in alg.particles]
end

"""
    step!(alg::PSOAlgorithm, problem::OptimizationProblem, agents::Vector{String}, current_iter::Int, shared_data::Dict, config_params::Dict)

PSO step: Updates particle velocities and positions based on their current fitness (assumed to be updated externally).
Returns a list of the new particle positions that need to be evaluated.
"""
function SwarmBase.step!(alg::PSOAlgorithm, problem::OptimizationProblem, agents::Vector{String}, current_iter::Int, shared_data::Dict, config_params::Dict)::Vector{Vector{Float64}}
    @debug "PSOAlgorithm: Advancing to step $current_iter. Updating velocities and positions."
    
    new_positions_for_evaluation = Vector{Vector{Float64}}(undef, alg.num_particles)

    for (idx, p) in enumerate(alg.particles)
        # Update velocity using current best_position (personal) and global_best_position
        # These bests were updated based on fitnesses from the *previous* evaluation cycle.
        r1, r2 = rand(), rand()
        cognitive_component = alg.cognitive_coeff * r1 * (p.best_position - p.position)
        social_component = alg.social_coeff * r2 * (alg.global_best_position - p.position)
        p.velocity = alg.inertia_weight * p.velocity + cognitive_component + social_component

        # Velocity clamping
        for d in 1:problem.dimensions
            v_max_d = alg.velocity_clamping_factor * (problem.bounds[d][2] - problem.bounds[d][1])
            p.velocity[d] = clamp(p.velocity[d], -v_max_d, v_max_d)
        end

        # Update position
        p.position += p.velocity

        # Clamp position to bounds
        for d in 1:problem.dimensions
            p.position[d] = clamp(p.position[d], problem.bounds[d][1], problem.bounds[d][2])
        end
        
        new_positions_for_evaluation[idx] = copy(p.position)
    end
    
    # Fitness evaluation is now handled by the Swarm manager loop using agents.
    # This function returns the new positions that the Swarm manager will send for evaluation.
    return new_positions_for_evaluation
end

"""
    update_fitness_and_bests!(alg::PSOAlgorithm, problem::OptimizationProblem, evaluated_fitnesses::Vector{Float64})

Updates particle fitness, personal bests, and global best after external evaluation.
`evaluated_fitnesses` must be in the same order as `alg.particles`.
"""
function update_fitness_and_bests!(alg::PSOAlgorithm, problem::OptimizationProblem, evaluated_fitnesses::Vector{Float64})
    if length(evaluated_fitnesses) != alg.num_particles
        @error "PSO: Number of evaluated fitnesses does not match number of particles."
        return
    end

    for i in 1:alg.num_particles
        p = alg.particles[i]
        p.current_fitness = evaluated_fitnesses[i]

        if problem.is_minimization
            if p.current_fitness < p.best_fitness
                p.best_fitness = p.current_fitness
                p.best_position = copy(p.position)
            end
            if p.best_fitness < alg.global_best_fitness
                alg.global_best_fitness = p.best_fitness
                alg.global_best_position = copy(p.best_position)
            end
        else # Maximization
            if p.current_fitness > p.best_fitness
                p.best_fitness = p.current_fitness
                p.best_position = copy(p.position)
            end
            if p.best_fitness > alg.global_best_fitness
                alg.global_best_fitness = p.best_fitness
                alg.global_best_position = copy(p.best_position)
            end
        end
    end
    @debug "PSO: Updated fitnesses and bests. Global best fitness: $(alg.global_best_fitness)"
end


function SwarmBase.should_terminate(alg::PSOAlgorithm, current_iter::Int, max_iter::Int, best_solution::Union{SwarmSolution,Nothing}, target_fitness::Union{Float64,Nothing}, problem::OptimizationProblem)::Bool
    if !isnothing(best_solution) && !isnothing(target_fitness)
        if problem.is_minimization && best_solution.fitness <= target_fitness
            @info "PSO: Target fitness reached."
            return true
        elseif !problem.is_minimization && best_solution.fitness >= target_fitness
            @info "PSO: Target fitness reached."
            return true
        end
    end
    # TODO: Add other termination criteria (e.g., stagnation)
    return current_iter >= max_iter
end

end # module PSOAlgorithmImpl
