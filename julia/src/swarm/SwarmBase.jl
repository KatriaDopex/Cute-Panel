"""
SwarmBase.jl - Base module for Swarm Optimization in CutePanel

This module provides the fundamental abstract types and data structures
used by various swarm intelligence algorithms and the swarm management system.
"""
module SwarmBase

export AbstractSwarmAlgorithm, OptimizationProblem, MultiObjectiveProblem, ConstrainedOptimizationProblem, OptimizationResult
export SwarmParticle, SwarmSolution # Added basic particle/solution structs

"""
    AbstractSwarmAlgorithm

Abstract type for all swarm optimization algorithms.
Each concrete algorithm should subtype this and implement an `optimize` method.
"""
abstract type AbstractSwarmAlgorithm end

"""
    SwarmParticle

A generic structure for a particle or individual in a swarm.
Specific algorithms might extend this or use their own.

# Fields
- `position::Vector{Float64}`: Current position in the search space.
- `velocity::Vector{Float64}`: Current velocity (if applicable to the algorithm).
- `fitness::Float64`: Fitness value of the current position.
- `best_position::Vector{Float64}`: Personal best position found by this particle.
- `best_fitness::Float64`: Fitness value of the personal best position.
- `metadata::Dict{String, Any}`: Algorithm-specific or other metadata.
"""
mutable struct SwarmParticle
    position::Vector{Float64}
    velocity::Vector{Float64}
    fitness::Float64
    best_position::Vector{Float64}
    best_fitness::Float64
    metadata::Dict{String, Any}

    function SwarmParticle(dim::Int, initial_fitness_val::Float64)
        new(zeros(dim), zeros(dim), initial_fitness_val, zeros(dim), initial_fitness_val, Dict{String,Any}())
    end
end

"""
    SwarmSolution

Represents a solution found by a swarm algorithm.

# Fields
- `position::Vector{Float64}`: The solution position (parameters).
- `fitness::Union{Float64, Vector{Float64}}`: The fitness value(s) of the solution.
                                            Can be a single Float64 for single-objective
                                            or a Vector{Float64} for multi-objective.
- `is_feasible::Bool`: Indicates if the solution satisfies all constraints.
- `metadata::Dict{String, Any}`: Additional information about the solution.
"""
struct SwarmSolution
    position::Vector{Float64}
    fitness::Union{Float64, Vector{Float64}}
    is_feasible::Bool
    metadata::Dict{String, Any}

    function SwarmSolution(position::Vector{Float64}, fitness; is_feasible::Bool=true, metadata::Dict{String,Any}=Dict{String,Any}())
        new(position, fitness, is_feasible, metadata)
    end
end


"""
    OptimizationProblem

Structure representing a single-objective optimization problem.

# Fields
- `dimensions::Int`: Number of dimensions in the search space.
- `bounds::Vector{Tuple{Float64, Float64}}`: Bounds for each dimension (min, max).
- `objective_function::Function`: The function to optimize. Takes a `Vector{Float64}` (position) and returns a `Float64` (fitness).
- `is_minimization::Bool`: Whether the problem is a minimization (true) or maximization (false).
"""
struct OptimizationProblem
    dimensions::Int
    bounds::Vector{Tuple{Float64, Float64}}
    objective_function::Function
    is_minimization::Bool

    function OptimizationProblem(
        dimensions::Int,
        bounds::Vector{Tuple{Float64, Float64}},
        objective_function::Function;
        is_minimization::Bool = true
    )
        if length(bounds) != dimensions
            throw(ArgumentError("Number of bounds ($(length(bounds))) must match dimensions ($dimensions)"))
        end
        for (i, (min_val, max_val)) in enumerate(bounds)
            if min_val >= max_val
                throw(ArgumentError("Lower bound must be less than upper bound for dimension $i: ($min_val, $max_val)"))
            end
        end
        new(dimensions, bounds, objective_function, is_minimization)
    end
end

"""
    MultiObjectiveProblem

Structure representing a multi-objective optimization problem.

# Fields
- `dimensions::Int`: Number of dimensions in the search space.
- `bounds::Vector{Tuple{Float64, Float64}}`: Bounds for each dimension (min, max).
- `objective_functions::Vector{Function}`: Vector of functions to optimize. Each takes a position and returns a fitness.
- `is_minimization_objectives::Vector{Bool}`: For each objective, true if minimizing, false if maximizing.
"""
struct MultiObjectiveProblem
    dimensions::Int
    bounds::Vector{Tuple{Float64, Float64}}
    objective_functions::Vector{Function}
    is_minimization_objectives::Vector{Bool}

    function MultiObjectiveProblem(
        dimensions::Int,
        bounds::Vector{Tuple{Float64, Float64}},
        objective_functions::Vector{Function};
        is_minimization_objectives::Vector{Bool} = fill(true, length(objective_functions))
    )
        if length(bounds) != dimensions
            throw(ArgumentError("Number of bounds must match dimensions"))
        end
        if isempty(objective_functions)
            throw(ArgumentError("At least one objective function must be provided"))
        end
        if length(objective_functions) != length(is_minimization_objectives)
            throw(ArgumentError("Length of objective_functions must match length of is_minimization_objectives"))
        end
        new(dimensions, bounds, objective_functions, is_minimization_objectives)
    end
end

"""
    ConstrainedOptimizationProblem

Structure representing a constrained single-objective optimization problem.

# Fields
- `problem::OptimizationProblem`: The underlying optimization problem.
- `constraint_functions::Vector{Function}`: Vector of constraint functions.
                                           Each function takes a position `Vector{Float64}`.
                                           A feasible solution should make `g(x) <= 0` for each constraint `g`.
"""
struct ConstrainedOptimizationProblem
    problem::OptimizationProblem
    constraint_functions::Vector{Function} # g(x) <= 0

    function ConstrainedOptimizationProblem(
        problem::OptimizationProblem,
        constraint_functions::Vector{Function}
    )
        if isempty(constraint_functions)
            @warn "Creating ConstrainedOptimizationProblem with no constraint functions. Consider using OptimizationProblem directly."
        end
        new(problem, constraint_functions)
    end
end

"""
    OptimizationResult

Structure representing the result of an optimization process.

# Fields
- `best_solution::SwarmSolution`: The best solution found.
- `convergence_curve::Vector{Union{Float64, Vector{Float64}}}`: History of best fitness values (or a representation for multi-objective).
- `iterations_completed::Int`: Number of iterations performed.
- `function_evaluations::Int`: Total number of objective function evaluations.
- `algorithm_details::Dict{String, Any}`: Algorithm-specific results or metadata.
- `success_flag::Bool`: True if optimization terminated successfully.
- `termination_message::String`: Message describing why optimization terminated.
"""
struct OptimizationResult
    best_solution::SwarmSolution
    convergence_curve::Vector{Union{Float64, Vector{Float64}}} # Can store single fitness or Pareto front snapshots
    iterations_completed::Int
    function_evaluations::Int
    algorithm_details::Dict{String, Any}
    success_flag::Bool
    termination_message::String

    function OptimizationResult(
        best_solution::SwarmSolution,
        convergence_curve, # Keep flexible for now
        iterations_completed::Int,
        function_evaluations::Int;
        algorithm_details::Dict{String, Any} = Dict{String,Any}(),
        success_flag::Bool = true,
        termination_message::String = "Optimization completed."
    )
        new(best_solution, convergence_curve, iterations_completed, function_evaluations, algorithm_details, success_flag, termination_message)
    end
end

end # module SwarmBase
