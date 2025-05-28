"""
DE.jl - Placeholder for Differential Evolution Algorithm
"""
module DEAlgorithmImpl

using Logging
try
    using ..SwarmBase
catch e
    @warn "DEAlgorithmImpl: Could not load SwarmBase. Using minimal stubs."
    abstract type AbstractSwarmAlgorithm end
    struct OptimizationProblem end
    struct SwarmSolution end
end

export DEAlgorithm

mutable struct DEAlgorithm <: AbstractSwarmAlgorithm
    population_size::Int
    crossover_rate::Float64 # CR
    mutation_factor::Float64 # F (often denoted as F)
    
    # Internal state
    population::Vector{Vector{Float64}}
    fitness_values::Vector{Float64}
    best_solution_position::Vector{Float64}
    best_solution_fitness::Float64
    problem_ref::Union{OptimizationProblem, Nothing}

    function DEAlgorithm(; pop_size::Int=50, cr::Float64=0.9, f_factor::Float64=0.8)
        # Ensure parameters are valid
        pop_size < 4 && error("Population size for DE must be at least 4.")
        0.0 <= cr <= 1.0 || error("Crossover rate (CR) must be between 0 and 1.")
        0.0 < f_factor <= 2.0 || error("Mutation factor (F) must be between 0 and 2 (typically).") # Common range
        new(pop_size, cr, f_factor, [], [], [], Inf, nothing)
    end
end

function SwarmBase.initialize!(alg::DEAlgorithm, problem::OptimizationProblem, agents::Vector{String}, config_params::Dict)
    @info "DEAlgorithm: Initializing population of size $(alg.population_size) for $(problem.dimensions) dimensions."
    alg.problem_ref = problem
    alg.population = Vector{Vector{Float64}}(undef, alg.population_size)
    alg.fitness_values = Vector{Float64}(undef, alg.population_size)
    
    initial_best_fitness = problem.is_minimization ? Inf : -Inf
    alg.best_solution_fitness = initial_best_fitness
    alg.best_solution_position = zeros(problem.dimensions)

    # Initial population and their fitness values need to be evaluated.
    # This can be done here directly or by returning candidates for the Swarm manager.
    # For simplicity in initialize!, direct evaluation:
    for i in 1:alg.population_size
        individual = [problem.bounds[d][1] + rand() * (problem.bounds[d][2] - problem.bounds[d][1]) for d in 1:problem.dimensions]
        alg.population[i] = individual
        alg.fitness_values[i] = problem.objective_function(individual)

        if (problem.is_minimization && alg.fitness_values[i] < alg.best_solution_fitness) ||
           (!problem.is_minimization && alg.fitness_values[i] > alg.best_solution_fitness)
            alg.best_solution_fitness = alg.fitness_values[i]
            alg.best_solution_position = copy(individual)
        end
    end
    @info "DEAlgorithm initialized. Initial best fitness: $(alg.best_solution_fitness)"
end

"""
    get_all_population_members_positions(alg::DEAlgorithm)::Vector{Vector{Float64}}

Returns the current positions of all individuals in the population.
Used by Swarm Manager for evaluating the current generation.
"""
function SwarmBase.get_all_particle_positions(alg::DEAlgorithm)::Vector{Vector{Float64}} # Renamed to match SwarmBase expectation
    return [copy(individual) for individual in alg.population]
end


"""
    generate_trial_vectors!(alg::DEAlgorithm, problem::OptimizationProblem)::Vector{Vector{Float64}}

Generates trial vectors for the current population. These vectors need to be evaluated.
This is an internal helper, called by `step!`.
"""
function _generate_trial_vectors(alg::DEAlgorithm, problem::OptimizationProblem)::Vector{Vector{Float64}}
    trial_vectors = Vector{Vector{Float64}}(undef, alg.population_size)
    for i in 1:alg.population_size
        indices = collect(1:alg.population_size)
        filter!(x -> x != i, indices)
        if length(indices) < 3
            @warn "Not enough distinct individuals for DE mutation (target index $i, pop size $(alg.population_size)). Using target as trial."
            trial_vectors[i] = copy(alg.population[i]) # Fallback: re-evaluate current
            continue
        end
        r1, r2, r3 = indices[randperm(length(indices))[1:3]]

        x_target = alg.population[i]
        x_r1 = alg.population[r1]
        x_r2 = alg.population[r2]
        x_r3 = alg.population[r3]

        mutant_vector = x_r1 + alg.mutation_factor * (x_r2 - x_r3)
        for d in 1:problem.dimensions
            mutant_vector[d] = clamp(mutant_vector[d], problem.bounds[d][1], problem.bounds[d][2])
        end

        current_trial_vector = copy(x_target)
        j_rand = rand(1:problem.dimensions)
        for d in 1:problem.dimensions
            if rand() < alg.crossover_rate || d == j_rand
                current_trial_vector[d] = mutant_vector[d]
            end
        end
        trial_vectors[i] = current_trial_vector
    end
    return trial_vectors
end

"""
    update_fitness_and_bests!(alg::DEAlgorithm, problem::OptimizationProblem, evaluated_fitnesses::Vector{Float64})

DE specific: This function is called by the Swarm Manager after the *current population* (not trial vectors yet)
has been evaluated. It updates `alg.fitness_values` for the main population and the global best if needed.
The `evaluated_fitnesses` correspond to `alg.population`.
"""
function SwarmBase.update_fitness_and_bests!(alg::DEAlgorithm, problem::OptimizationProblem, evaluated_fitnesses::Vector{Float64})
    if length(evaluated_fitnesses) != alg.population_size
        @error "DE: Number of evaluated fitnesses ($(length(evaluated_fitnesses))) does not match population size ($(alg.population_size))."
        return
    end

    for i in 1:alg.population_size
        alg.fitness_values[i] = evaluated_fitnesses[i] # Update fitness of current population member
        # Update global best based on this current population member
        if (problem.is_minimization && alg.fitness_values[i] < alg.best_solution_fitness) ||
           (!problem.is_minimization && alg.fitness_values[i] > alg.best_solution_fitness)
            alg.best_solution_fitness = alg.fitness_values[i]
            alg.best_solution_position = copy(alg.population[i])
        end
    end
    @debug "DE: Updated fitnesses for current population. Global best fitness: $(alg.best_solution_fitness)"
end


"""
    step!(alg::DEAlgorithm, problem::OptimizationProblem, ...)::Vector{Vector{Float64}}

DE step: Generates a new set of *trial vectors* based on the current population.
These trial vectors are then returned to the Swarm Manager for evaluation.
The fitness values in `alg.fitness_values` are for the *current main population*,
assumed to have been updated by `update_fitness_and_bests!` prior to this call.
"""
function SwarmBase.step!(alg::DEAlgorithm, problem::OptimizationProblem, agents::Vector{String}, current_iter::Int, shared_data::Dict, config_params::Dict)::Vector{Vector{Float64}}
    @debug "DEAlgorithm: Step $current_iter - Generating trial vectors."
    # This function now only generates trial vectors.
    # The Swarm manager will evaluate these and then call a selection function.
    trial_vectors_to_eval = _generate_trial_vectors(alg, problem)
    return trial_vectors_to_eval # These are the candidates for the next generation
end

"""
    select_next_generation!(alg::DEAlgorithm, problem::OptimizationProblem, trial_vectors::Vector{Vector{Float64}}, trial_fitnesses::Vector{Float64})

DE selection: Compares trial vectors (and their fitnesses) with the current population
and selects individuals for the next generation. Updates `alg.population`, 
`alg.fitness_values`, and the global best solution if improved.
This is called by the Swarm Manager *after* trial vectors from `step!` have been evaluated.
"""
function SwarmBase.select_next_generation!(alg::DEAlgorithm, problem::OptimizationProblem, trial_vectors::Vector{Vector{Float64}}, trial_fitnesses::Vector{Float64})
    if length(trial_fitnesses) != alg.population_size || length(trial_vectors) != alg.population_size
        @error "DE Selection: Mismatch in lengths of trial_fitnesses/trial_vectors ($(length(trial_fitnesses))/$(length(trial_vectors))) and population size ($(alg.population_size))."
        return
    end

    for i in 1:alg.population_size
        trial_fitness = trial_fitnesses[i]
        
        # Compare trial vector with the corresponding target vector in the current population
        if (problem.is_minimization && trial_fitness <= alg.fitness_values[i]) ||
           (!problem.is_minimization && trial_fitness >= alg.fitness_values[i])
            # Trial vector is better or equal, replaces the target vector
            alg.population[i] = copy(trial_vectors[i]) # trial_vectors[i] is the one whose fitness is trial_fitness
            alg.fitness_values[i] = trial_fitness

            # Check if this newly accepted individual is also a new global best
            if (problem.is_minimization && trial_fitness < alg.best_solution_fitness) ||
               (!problem.is_minimization && trial_fitness > alg.best_solution_fitness)
                alg.best_solution_fitness = trial_fitness
                alg.best_solution_position = copy(trial_vectors[i])
                # Swarm manager will log this global best update.
            end
        end
        # If trial is not better, the individual in alg.population[i] (and its fitness in alg.fitness_values[i]) remains unchanged.
    end
    @debug "DE: Selection complete for iteration. New global best fitness: $(alg.best_solution_fitness)"
end


function SwarmBase.should_terminate(alg::DEAlgorithm, current_iter::Int, max_iter::Int, best_solution_from_swarm::Union{SwarmSolution,Nothing}, target_fitness::Union{Float64,Nothing}, problem::OptimizationProblem)::Bool
    # `best_solution_from_swarm` is the one maintained by the Swarm manager, reflecting the algorithm's `alg.best_solution_fitness`
    if !isnothing(best_solution_from_swarm) && !isnothing(target_fitness)
        if problem.is_minimization && best_solution_from_swarm.fitness <= target_fitness return true end
        if !problem.is_minimization && best_solution_from_swarm.fitness >= target_fitness return true end
    end
    return current_iter >= max_iter
end

end # module DEAlgorithmImpl
