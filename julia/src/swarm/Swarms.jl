"""
Swarms.jl - Core Swarm Management for CutePanel

This module provides functionalities to create, manage, and interact with swarms
of agents, leveraging various optimization algorithms.
"""
module Swarms

using Dates, Random, UUIDs, Logging, Base.Threads
using JSON3
using Redis # Added for networked swarm backend

# Assuming SwarmBase.jl is in the same directory
using .SwarmBase 
# Assuming Agents.jl and its submodules are accessible from the parent scope 
# (e.g., if CutePanelFramework.jl includes both this and Agents)
try
    using ..agents.Agents 
    using ..agents.Config # Used for swarm.backend and swarm.connection_string
    using ..agents.AgentMetrics 
    @info "Swarms.jl: Successfully using main Agents module."
catch e
    @warn "Swarms.jl: Could not load main Agents module. Using internal stubs."
    module AgentsStub # Fallback if Agents module fails to load
        struct Agent end
        getAgent(id) = nothing
        module Swarm 
            subscribe_swarm!(agent_id, topic) = @warn "Agents.Swarm unavailable (stub): Cannot subscribe $agent_id to $topic"
            publish_to_swarm(sender_id, topic, msg) = @warn "Agents.Swarm unavailable (stub): Cannot publish to $topic"
            unsubscribe_swarm!(agent_id, topic) = @warn "Agents.Swarm unavailable (stub): Cannot unsubscribe $agent_id from $topic"
        end
    end
    using .AgentsStub
    get_config(key, default) = default # Dummy
    record_metric(args...; kwargs...) = nothing # Dummy
end


export Swarm, SwarmConfig, SwarmStatus, createSwarm, getSwarm, listSwarms, startSwarm, stopSwarm,
       getSwarmStatus, addAgentToSwarm, removeAgentFromSwarm, getSharedState, updateSharedState!,
       electLeader, allocateTask, claimTask, completeTask, getSwarmMetrics,
       AbstractSwarmAlgorithm, OptimizationProblem, SwarmSolution, OptimizationResult,
       register_objective_function! # Exporting this for TradingStrategy

@enum SwarmStatus begin
    SWARM_CREATED = 1
    SWARM_RUNNING = 2
    SWARM_STOPPED = 3
    SWARM_ERROR = 4
    SWARM_COMPLETED = 5 
end

# Global Redis connection cache: Dict{connection_string, Redis.Connection} (or appropriate type from Redis.jl)
const REDIS_CONNECTIONS_CACHE = Dict{String, Any}() # Using Any for now, replace with actual Redis.Connection type
const REDIS_CACHE_LOCK = ReentrantLock()

"""
_get_redis_connection(connection_string::String)::Union{Any, Nothing}

Helper to get or create a Redis connection from a cached pool.
Returns a Redis connection object or nothing on failure.
NOTE: This is a simplified connection manager. Production systems might use Redis.jl's built-in pooling
or a more robust connection management strategy.
"""
function _get_redis_connection(connection_string::String)::Union{Any, Nothing}
    lock(REDIS_CACHE_LOCK) do
        if haskey(REDIS_CONNECTIONS_CACHE, connection_string)
            conn = REDIS_CONNECTIONS_CACHE[connection_string]
            # Basic check if connection is still valid (e.g., Redis.ping)
            # This depends on the Redis.jl library's API.
            try
                # Assuming a `ping(conn)` function exists and returns "PONG" or throws on error
                # if Redis.ping(conn) == "PONG" # This is specific to some Redis clients
                #    return conn
                # end
                # For now, if it's in cache, assume it's good or re-establish if ping fails.
                # A simple check might be just to return it. If it fails later, it'll be caught.
                # More robust: if ping fails, delete from cache and fall through to create new.
                return conn # Simplified: return cached if exists
            catch e_ping
                @warn "Cached Redis connection for $connection_string failed ping. Attempting to reconnect." error=e_ping
                delete!(REDIS_CONNECTIONS_CACHE, connection_string) # Remove bad connection
            end
        end

        try
            @info "Attempting to establish new Redis connection to: $connection_string"
            # This needs to correctly parse the connection_string (e.g., "redis://host:port/db")
            # and use the Redis.jl library's connection function.
            
            # Example parsing for "redis://host:port" or "redis://host:port/db_num"
            uri = tryparse(HTTP.URI, connection_string) # HTTP.URI can parse generic URIs
            
            local conn_params = Dict()
            if !isnothing(uri) && lowercase(uri.scheme) == "redis"
                conn_params[:host] = string(uri.host)
                conn_params[:port] = Int(uri.port)
                if !isempty(uri.path) && uri.path != "/"
                    try conn_params[:db] = parse(Int, uri.path[2:end]) catch _ end
                end
            elseif occursin(":", connection_string) # Simple host:port
                 parts = split(connection_string, ':')
                 conn_params[:host] = parts[1]
                 conn_params[:port] = parse(Int, parts[2])
            else # Assume just host
                 conn_params[:host] = connection_string
            end

            # Actual connection using Redis.jl
            # This assumes `Redis.connect(; host, port, db)` is the way.
            # Adjust based on the specific Redis client library being used.
            # conn = Redis.connect(; conn_params...) # This is the actual call to Redis.jl
            
            # --- SIMULATION if Redis.jl `connect` is problematic without full setup ---
            # For now, to ensure this step doesn't break if Redis.jl isn't perfectly configured
            # in the test environment, we'll use a placeholder. Replace with actual Redis.connect.
            @warn "Redis connection logic in _get_redis_connection is using a SIMULATED connection. Replace with actual Redis.connect call."
            conn = Dict("uri" => connection_string, "status" => "simulated_redis_connection", "params_used" => conn_params) # Placeholder
            # --- END SIMULATION ---


            REDIS_CONNECTIONS_CACHE[connection_string] = conn
            @info "Successfully established and cached Redis connection to: $connection_string"
            return conn
        catch e
            @error "Failed to create Redis connection for string: $connection_string" exception=(e, catch_backtrace())
            return nothing
        end
    end
end


mutable struct SwarmConfig
    name::String
    algorithm_type::String 
    algorithm_params::Dict{String, Any} 
    objective_description::String 
    max_iterations::Int
    target_fitness::Union{Float64, Nothing} 
    problem_definition::OptimizationProblem 

    function SwarmConfig(name::String, algorithm_type::String, problem_def::OptimizationProblem;
                         algorithm_params::Dict{String,Any}=Dict{String,Any}(),
                         objective_desc::String="Default Objective",
                         max_iter::Int=100, target_fit=nothing)
        new(name, algorithm_type, algorithm_params, objective_desc, max_iter, target_fit, problem_def)
    end
end

mutable struct Swarm
    id::String; name::String; status::SwarmStatus; created_at::DateTime; updated_at::DateTime
    config::SwarmConfig; agents::Vector{String}    
    current_iteration::Int; best_solution_found::Union{SwarmSolution, Nothing}
    algorithm_instance::Union{AbstractSwarmAlgorithm, Nothing} 
    swarm_task_handle::Union{Task, Nothing} 
    shared_data::Dict{String, Any} 
    task_queue::Vector{Dict{String,Any}} 

    function Swarm(id, name, config)
        new(id, name, SWARM_CREATED, now(UTC), now(UTC), config, String[],
            0, nothing, nothing, nothing, Dict{String,Any}(), Vector{Dict{String,Any}}())
    end
end

const SWARMS_REGISTRY = Dict{String, Swarm}()
const SWARMS_LOCK = ReentrantLock() 
const DEFAULT_SWARM_STORE_PATH = joinpath(@__DIR__, "..", "..", "db", "swarms_state.json") 
const SWARM_STORE_PATH = Ref(get_config("storage.swarm_path", DEFAULT_SWARM_STORE_PATH))
const SWARM_AUTO_PERSIST = Ref(get_config("storage.auto_persist_swarms", true)) 

function _ensure_storage_dir()
    try store_dir = dirname(SWARM_STORE_PATH[]); ispath(store_dir) || mkpath(store_dir)
    catch e @error "Failed to ensure swarm storage directory" error=e end
end

function _serialize_optimization_problem(prob::OptimizationProblem)
    return Dict("dimensions" => prob.dimensions, "bounds" => prob.bounds,
                "objective_function_name" => string(prob.objective_function), 
                "is_minimization" => prob.is_minimization)
end

function _deserialize_optimization_problem(data::Dict)::Union{OptimizationProblem, Nothing}
    try
        obj_func_name = get(data, "objective_function_name", "default_sum_objective")
        resolved_obj_func = get_objective_function_by_name(obj_func_name)
        return OptimizationProblem(data["dimensions"], [tuple(b...) for b in data["bounds"]], 
                                   resolved_obj_func; is_minimization=data["is_minimization"])
    catch e @error "Error deserializing OptimizationProblem" data=data error=e; return nothing end
end

function _save_swarms_state()
    SWARM_AUTO_PERSIST[] || return; _ensure_storage_dir()
    data_to_save = Dict{String, Any}()
    lock(SWARMS_LOCK) do
        for (id, swarm) in SWARMS_REGISTRY
            cfg = swarm.config; sol = swarm.best_solution_found
            data_to_save[id] = Dict(
                "id"=>swarm.id, "name"=>swarm.name, "status"=>Int(swarm.status),
                "created_at"=>string(swarm.created_at), "updated_at"=>string(swarm.updated_at),
                "config"=>Dict("name"=>cfg.name, "algorithm_type"=>cfg.algorithm_type, 
                               "algorithm_params"=>cfg.algorithm_params, "objective_description"=>cfg.objective_description,
                               "max_iterations"=>cfg.max_iterations, "target_fitness"=>cfg.target_fitness,
                               "problem_definition"=>_serialize_optimization_problem(cfg.problem_definition)),
                "agents"=>swarm.agents, "current_iteration"=>swarm.current_iteration,
                "best_solution_found"=>isnothing(sol) ? nothing : 
                    Dict("position"=>sol.position, "fitness"=>sol.fitness, "is_feasible"=>sol.is_feasible, "metadata"=>sol.metadata),
                "shared_data"=>swarm.shared_data, "task_queue"=>swarm.task_queue)
        end
    end
    temp_file_path = SWARM_STORE_PATH[] * ".tmp." * string(uuid4())
    try open(temp_file_path, "w") do io JSON3.write(io, data_to_save) end
        mv(temp_file_path, SWARM_STORE_PATH[]; force=true)
        @debug "Swarm state saved" path=SWARM_STORE_PATH[]
    catch e @error "Failed to save swarm state" error=e; isfile(temp_file_path) && try rm(temp_file_path) catch _ end end
end

function _load_swarms_state()
    _ensure_storage_dir(); isfile(SWARM_STORE_PATH[]) || return
    try raw_data = JSON3.read(read(SWARM_STORE_PATH[], String))
        loaded_count = 0
        lock(SWARMS_LOCK) do; empty!(SWARMS_REGISTRY)
            for (id_str, sd) in raw_data; try
                cfg_data = sd["config"]; prob_def_data = cfg_data["problem_definition"]
                deser_prob = _deserialize_optimization_problem(prob_def_data)
                isnothing(deser_prob) && (@warn "Skipping swarm $id_str: problem deserialization error."; continue)
                config = SwarmConfig(cfg_data["name"], cfg_data["algorithm_type"], deser_prob; 
                                     algorithm_params=cfg_data["algorithm_params"], objective_desc=cfg_data["objective_description"],
                                     max_iter=cfg_data["max_iterations"], target_fit=cfg_data["target_fitness"])
                swarm = Swarm(sd["id"], sd["name"], config)
                swarm.status = SwarmStatus(sd["status"]); swarm.created_at = DateTime(sd["created_at"]); swarm.updated_at = DateTime(sd["updated_at"])
                swarm.agents = get(sd, "agents", String[]); swarm.current_iteration = get(sd, "current_iteration", 0)
                bs_data = get(sd, "best_solution_found", nothing)
                if !isnothing(bs_data) swarm.best_solution_found = SwarmSolution(convert(Vector{Float64}, bs_data["position"]), bs_data["fitness"], bs_data["is_feasible"], bs_data["metadata"]) end
                swarm.shared_data = get(sd, "shared_data", Dict{String,Any}()); swarm.task_queue = get(sd, "task_queue", Vector{Dict{String,Any}}())
                SWARMS_REGISTRY[id_str] = swarm; loaded_count += 1
            catch e @error "Error loading swarm $id_str" error=e end end
        end; @info "Loaded $loaded_count swarms."
    catch e @error "Fatal error reading swarm state file" error=e end
end

const OBJECTIVE_FUNCTION_REGISTRY = Dict{String, Function}()
function register_objective_function!(name::String, func::Function) OBJECTIVE_FUNCTION_REGISTRY[name] = func; @info "Registered objective: $name" end
function get_objective_function_by_name(name::String)::Function
    get(OBJECTIVE_FUNCTION_REGISTRY, name) do
        @warn "Objective '$name' not found. Falling back to default."
        (pos_vec::Vector{Float64}) -> sum(pos_vec) 
    end
end
function sphere_objective(pos::Vector{Float64})::Float64 sum(x^2 for x in pos) end
function rastrigin_objective(pos::Vector{Float64})::Float64 10.0*length(pos) + sum(x^2 - 10.0*cos(2*π*x) for x in pos) end
function _register_default_objectives() register_objective_function!("sphere", sphere_objective); register_objective_function!("rastrigin", rastrigin_objective); register_objective_function!("default_sum_objective", (p->sum(p))) end

createSwarm(config::SwarmConfig) = lock(SWARMS_LOCK) do SWARMS_REGISTRY["swarm-"*string(uuid4())[1:8]] = Swarm("swarm-"*string(uuid4())[1:8], config.name, config); @info "Created swarm $(config.name)"; _save_swarms_state(); SWARMS_REGISTRY[collect(keys(SWARMS_REGISTRY))[end]] end
getSwarm(id::String) = lock(SWARMS_LOCK) do get(SWARMS_REGISTRY, id, nothing) end
listSwarms(; st=nothing) = lock(SWARMS_LOCK) do isnothing(st) ? collect(values(SWARMS_REGISTRY)) : filter(s->s.status==st, collect(values(SWARMS_REGISTRY))) end
function addAgentToSwarm(swarm_id::String, agent_id::String) lock(SWARMS_LOCK) do s=getSwarm(swarm_id); isnothing(s) && return false; !(agent_id in s.agents) && (push!(s.agents, agent_id); s.updated_at=now(UTC); _save_swarms_state()); true end end
function removeAgentFromSwarm(swarm_id::String, agent_id::String) lock(SWARMS_LOCK) do s=getSwarm(swarm_id); isnothing(s) && return false; agent_id in s.agents && (filter!(id->id!=agent_id, s.agents); s.updated_at=now(UTC); _save_swarms_state(); true) end end

function _instantiate_algorithm(swarm::Swarm)
    algo_type = swarm.config.algorithm_type; params = swarm.config.algorithm_params
    try
        if algo_type == "PSO" include("algorithms/PSO.jl"); return PSOAlgorithmImpl.PSOAlgorithm(;get(params,"pso_specific_params",Dict())...) end
        if algo_type == "DE" include("algorithms/DE.jl"); return DEAlgorithmImpl.DEAlgorithm(;get(params,"de_specific_params",Dict())...) end
        if algo_type == "GA" include("algorithms/GA.jl"); return GAAlgorithmImpl.GAAlgorithm(;get(params,"ga_specific_params",Dict())...) end
        @error "Unknown algorithm type: $algo_type"
    catch e @error "Error instantiating $algo_type" error=e end
    struct MockAlg <: AbstractSwarmAlgorithm end; SwarmBase.initialize!(::MockAlg,::Any,::Any,::Any)=(); SwarmBase.step!(::MockAlg,::Any,::Any,::Any,::Any,::Any)=SwarmSolution([0.0],0.0); SwarmBase.should_terminate(::MockAlg,::Any,::Any,::Any,::Any,::Any)=true; return MockAlg()
end

function _swarm_algorithm_loop(swarm::Swarm)
    @info "Algorithm loop started for swarm $(swarm.name) (ID: $(swarm.id)) using $(swarm.config.algorithm_type)."
    swarm.algorithm_instance = _instantiate_algorithm(swarm)
    isnothing(swarm.algorithm_instance) && (swarm.status = SWARM_ERROR; swarm.updated_at = now(UTC); @error "Failed to init algo for swarm $(swarm.id)"; _save_swarms_state(); return)
    
    try
        # Initialize the algorithm (includes initial local fitness evaluations)
        SwarmBase.initialize!(swarm.algorithm_instance, swarm.config.problem_definition, swarm.agents, swarm.config.algorithm_params)
        @info "Swarm $(swarm.id): Algorithm initialized. Initial global best fitness: $(isnothing(swarm.algorithm_instance.global_best_fitness) ? "N/A" : swarm.algorithm_instance.global_best_fitness)"
        
        # Update swarm's record of best solution from initialization
        if hasproperty(swarm.algorithm_instance, :global_best_position) && hasproperty(swarm.algorithm_instance, :global_best_fitness)
             # Assuming is_feasible is true for initial solutions, metadata can be empty
            swarm.best_solution_found = SwarmSolution(
                copy(swarm.algorithm_instance.global_best_position),
                swarm.algorithm_instance.global_best_fitness,
                true, # is_feasible
                Dict{String,Any}() # metadata
            )
        end

        max_iter = swarm.config.max_iterations
        
        # Get initial set of positions to evaluate (these are the positions after initialization)
        # This function needs to be part of SwarmBase and implemented by each algorithm type.
        # e.g., for PSO, it returns all particle.position
        current_positions_to_evaluate = SwarmBase.get_all_particle_positions(swarm.algorithm_instance)

        for iter in 1:max_iter
            if swarm.status != SWARM_RUNNING 
                @info "Swarm $(swarm.id) stopping: status $(swarm.status)."
                break 
            end
            swarm.current_iteration = iter
            @debug "Swarm $(swarm.id) iter $iter/$max_iter"

            # (A) Evaluate Fitnesses for current_positions_to_evaluate
            # This is where real agent distribution would happen.
            # For now, _distribute_and_collect_evaluations simulates it locally.
            @debug "Swarm $(swarm.id) iter $iter: Evaluating $(length(current_positions_to_evaluate)) current population members."
            evaluated_fitnesses_current_pop = _distribute_and_collect_evaluations(swarm, current_positions_to_evaluate)
            if length(evaluated_fitnesses_current_pop) != length(current_positions_to_evaluate)
                @error "Swarm $(swarm.id) iter $iter: Mismatch in number of evaluated fitnesses for current pop. Halting."
                swarm.status = SWARM_ERROR; break
            end
            @debug "Swarm $(swarm.id) iter $iter: Fitnesses for current pop collected."

            # (B) Update Algorithm State with new fitnesses for the current population
            # For DE/GA, this updates the fitness of the main population. For PSO, it updates particle fitness & pbest/gbest.
            SwarmBase.update_fitness_and_bests!(swarm.algorithm_instance, swarm.config.problem_definition, evaluated_fitnesses_current_pop)
            
            # (D) Algorithm Advances (Generates Next Candidate Positions/Trial Vectors)
            # For DE/GA, this generates trial vectors. For PSO, this updates velocities and generates new particle positions.
            @debug "Swarm $(swarm.id) iter $iter: Advancing algorithm to generate next candidates."
            next_candidate_positions = SwarmBase.step!( # For DE, this returns trial vectors; for PSO, new particle positions
                swarm.algorithm_instance, swarm.config.problem_definition, swarm.agents, 
                iter, swarm.shared_data, swarm.config.algorithm_params
            )
            if isempty(next_candidate_positions)
                 @warn "Swarm $(swarm.id) iter $iter: Algorithm step returned no new candidate positions to evaluate."
            end

            # --- Algorithm-Specific Post-Step Processing ---
            if swarm.config.algorithm_type == "DE" && !isempty(next_candidate_positions)
                # For DE, `next_candidate_positions` are trial vectors. They need to be evaluated.
                @debug "Swarm $(swarm.id) iter $iter (DE): Evaluating $(length(next_candidate_positions)) trial vectors."
                evaluated_trial_fitnesses = _distribute_and_collect_evaluations(swarm, next_candidate_positions)
                if length(evaluated_trial_fitnesses) != length(next_candidate_positions)
                    @error "Swarm $(swarm.id) iter $iter (DE): Mismatch in trial fitnesses. Halting."
                    swarm.status = SWARM_ERROR; break
                end
                # Then, perform selection to update the main population
                SwarmBase.select_next_generation!(swarm.algorithm_instance, swarm.config.problem_definition, next_candidate_positions, evaluated_trial_fitnesses)
                # After selection, the `current_positions_to_evaluate` for the *next* iteration will be the new main population.
                current_positions_to_evaluate = SwarmBase.get_all_particle_positions(swarm.algorithm_instance) # Get updated main population
            elseif swarm.config.algorithm_type == "GA" && !isempty(next_candidate_positions)
                # For GA, `next_candidate_positions` are offspring genes. They need to be evaluated.
                @debug "Swarm $(swarm.id) iter $iter (GA): Evaluating $(length(next_candidate_positions)) offspring."
                evaluated_offspring_fitnesses = _distribute_and_collect_evaluations(swarm, next_candidate_positions)
                if length(evaluated_offspring_fitnesses) != length(next_candidate_positions)
                    @error "Swarm $(swarm.id) iter $iter (GA): Mismatch in offspring fitnesses. Halting."
                    swarm.status = SWARM_ERROR; break
                end
                # Then, form the next generation using elites and these evaluated offspring
                SwarmBase.select_next_generation!(swarm.algorithm_instance, swarm.config.problem_definition, next_candidate_positions, evaluated_offspring_fitnesses)
                # The `current_positions_to_evaluate` for the *next* iteration will be the new main population.
                # (GA's `update_fitness_and_bests!` is mainly for the initial population's fitness values if needed,
                #  or if the main population itself is re-evaluated, which is not typical for this generational GA flow).
                current_positions_to_evaluate = SwarmBase.get_all_particle_positions(swarm.algorithm_instance) # Get new main population for next iter
            else # For PSO and other single-stage evaluation algorithms (or if GA step returned no candidates)
                # `next_candidate_positions` are the new positions for the next iteration's evaluation.
                current_positions_to_evaluate = next_candidate_positions
            end
            
            # (E) Update Swarm's Best Solution Record from algorithm's internal global best
            # This should reflect the state *after* all evaluations and selections for the current iteration are done.
            if hasproperty(swarm.algorithm_instance, :global_best_position) && hasproperty(swarm.algorithm_instance, :global_best_fitness)
                algo_global_best_fitness = swarm.algorithm_instance.global_best_fitness
                if isnothing(swarm.best_solution_found) ||
                   (swarm.config.problem_definition.is_minimization && algo_global_best_fitness < swarm.best_solution_found.fitness) ||
                   (!swarm.config.problem_definition.is_minimization && algo_global_best_fitness > swarm.best_solution_found.fitness)
                    
                    swarm.best_solution_found = SwarmSolution(
                        copy(swarm.algorithm_instance.global_best_position),
                        algo_global_best_fitness,
                        true, # Assuming feasibility
                        Dict("updated_at_iter" => iter)
                    )
                    @info "Swarm $(swarm.id) new global best at iter $iter: Fitness=$(swarm.best_solution_found.fitness)"
                    _save_swarms_state() 
                end
            else
                @warn "Swarm $(swarm.id) iter $iter: Algorithm instance missing global_best_position/fitness."
            end

            # (C & F) Check for Termination (combined)
            if SwarmBase.should_terminate(swarm.algorithm_instance, iter, max_iter, swarm.best_solution_found, swarm.config.target_fitness, swarm.config.problem_definition)
                @info "Swarm $(swarm.id) met termination criteria at iter $iter."
                swarm.status = SWARM_COMPLETED; break 
            end
            
            sleep(get(swarm.config.algorithm_params, "iteration_delay_seconds", 0.01)) 
        end # End of iteration loop

        if swarm.status == SWARM_RUNNING # If loop finished due to max_iter without other termination
            swarm.status = SWARM_COMPLETED
            @info "Swarm $(swarm.id) completed max iterations."
        end

    catch e
        if isa(e, InterruptException) @info "Swarm $(swarm.id) loop interrupted."; swarm.status = SWARM_STOPPED
        else @error "Error in swarm $(swarm.id) loop!" error=e stack=catch_backtrace(); swarm.status = SWARM_ERROR end
    finally
        swarm.updated_at = now(UTC); swarm.swarm_task_handle = nothing # Clear task handle
        @info "Swarm $(swarm.id) algorithm loop finished. Final status: $(swarm.status)."
        _save_swarms_state() # Save final state
    end
end


"""
_distribute_and_collect_evaluations(swarm::Swarm, positions_to_evaluate::Vector{Vector{Float64}})::Vector{Float64}

Handles distributing candidate solutions to agents for fitness evaluation and collecting results.
This version attempts to use `Agents.executeAgentTask` and polls for results.
"""
function _distribute_and_collect_evaluations(swarm::Swarm, positions_to_evaluate::Vector{Vector{Float64}})::Vector{Float64}
    num_positions = length(positions_to_evaluate)
    evaluated_fitnesses = Vector{Float64}(undef, num_positions)
    fill!(evaluated_fitnesses, swarm.config.problem_definition.is_minimization ? Inf : -Inf) # Default to worst fitness

    if num_positions == 0
        return evaluated_fitnesses
    end

    # Get registered name of the objective function.
    # string(swarm.config.problem_definition.objective_function) might give "anonymous" if it's a lambda.
    # We need a reliable way to get the registered name.
    # Assuming problem_definition stores the name, or we find it by matching the function object.
    # For now, let's assume objective_function_name is correctly resolvable by agents.
    # This was handled in _serialize_optimization_problem and _deserialize_optimization_problem.
    # The SwarmConfig.problem_definition.objective_function is the actual function object.
    # We need its registered string name.
    
    # Find the registered name for the objective function
    obj_func_callable = swarm.config.problem_definition.objective_function
    objective_func_name_str = "unknown_objective_function" # Default
    for (name, func) in OBJECTIVE_FUNCTION_REGISTRY
        if func === obj_func_callable
            objective_func_name_str = name
            break
        end
    end
    if objective_func_name_str == "unknown_objective_function"
        # This should not happen if objective functions are always from the registry.
        # If it's a custom lambda not from registry, it cannot be called by remote agent by name.
        @error "Swarm $(swarm.id): Objective function is not a registered function. Cannot use networked backend. Falling back."
        # Fallback to local evaluation or agent polling
    end


    # --- Networked Backend Logic (e.g., Redis) ---
    swarm_backend_type = get_config("swarm.backend", "none") # From agents.Config
    redis_conn_str = get_config("swarm.connection_string", "") # From agents.Config
    
    # TODO: Implement Redis connection caching and management
    # local redis_conn = nothing
    # if swarm_backend_type == "redis" && !isempty(redis_conn_str)
    #     try
    #         # redis_conn = RedisConnection(redis_conn_str) # Example
    #         @info "Swarm $(swarm.id): Connected to Redis backend at $redis_conn_str for task distribution."
    #     catch e
    #         @error "Swarm $(swarm.id): Failed to connect to Redis backend at $redis_conn_str. Falling back." error=e
    #         redis_conn = nothing
    #     end
    # end

    # if !isnothing(redis_conn) && objective_func_name_str != "unknown_objective_function"
    #     @info "Swarm $(swarm.id): Using Redis backend for $(num_positions) evaluations."
    #     # ... (Implementation for Redis task dispatch and result collection) ...
    #     # This part is complex and involves:
    #     # 1. Serializing tasks (position, objective_func_name_str, reply_to_key)
    #     # 2. LPUSH to a work queue (e.g., "swarm_eval_tasks")
    #     # 3. For each task, BRPOP on a unique reply_to_key with timeout
    #     # 4. Deserialize result, handle errors/timeouts
    #     # This is a placeholder for that logic.
    #     @warn "Redis-based distributed evaluation for Swarm $(swarm.id) is a STUB/TODO."
    #     # Fallback to current agent polling if Redis logic is not fully implemented yet.
    # end
    # --- Networked Backend Logic (e.g., Redis) ---
    swarm_backend_type = lowercase(get_config("swarm.backend", "none")) # From agents.Config
    
    if swarm_backend_type == "redis" && objective_func_name_str != "unknown_objective_function"
        redis_conn_str = get_config("swarm.connection_string", "") # From agents.Config
        if isempty(redis_conn_str)
            @warn "Swarm $(swarm.id): Redis backend configured but connection string is empty. Falling back."
        else
            redis_conn = _get_redis_connection(redis_conn_str)
            if !isnothing(redis_conn)
                @info "Swarm $(swarm.id): Using Redis backend at $redis_conn_str for $(num_positions) evaluations."
                
                dispatched_redis_tasks = Vector{Tuple{String, String, Int}}() # eval_task_id, reply_to_list, original_pos_idx
                # Use a general task queue for all swarms, or swarm-specific if preferred
                task_queue_list_name = get_config("swarm.default_topic_prefix", "cutepanel.swarm") * ".evaluation_tasks"

                for i in 1:num_positions
                    eval_task_id = "eval-" * string(uuid4())
                    # Unique reply list for each task to ensure result goes to the right place
                    reply_to_list_name = get_config("swarm.default_topic_prefix", "cutepanel.swarm") * ".results:" * eval_task_id 
                    
                    task_payload = Dict(
                        "eval_task_id" => eval_task_id,
                        "swarm_id" => swarm.id, # For agent logging/context
                        "position_data" => positions_to_evaluate[i],
                        "objective_function_name" => objective_func_name_str,
                        "reply_to_list" => reply_to_list_name
                    )
                    json_task = JSON3.write(task_payload)
                    
                    try
                        # This is where the actual Redis.lpush would happen.
                        # Example: Redis.lpush(redis_conn, task_queue_list_name, json_task)
                        @debug "Swarm $(swarm.id) [SIMULATED REDIS]: LPUSH task $eval_task_id to $task_queue_list_name" task_data=json_task
                        # For simulation, we'll assume it's pushed.
                        push!(dispatched_redis_tasks, (eval_task_id, reply_to_list_name, i))
                    catch e_redis_push
                        @error "Swarm $(swarm.id): Failed to LPUSH task to Redis queue $task_queue_list_name" exception=e_redis_push
                        # Penalty fitness already set for this position, will not be collected via Redis
                    end
                end

                # --- Collect Results from Redis (Blocking with Timeout) ---
                collection_timeout_seconds = get(swarm.config.algorithm_params, "evaluation_timeout_seconds", 60.0) 
                
                num_collected_redis = 0
                for (eval_task_id, reply_list, original_pos_idx) in dispatched_redis_tasks
                    @debug "Swarm $(swarm.id) [SIMULATED REDIS]: Waiting for result on Redis list $reply_list for task $eval_task_id (original index $original_pos_idx)"
                    try
                        task_timeout_per_item = max(1, floor(Int, collection_timeout_seconds / length(dispatched_redis_tasks)))
                        
                        # Example: result_tuple = Redis.brpop(redis_conn, [reply_list], task_timeout_per_item) 
                        # --- SIMULATION of BRPOP and agent processing ---
                        # In a real system, an external agent worker would:
                        # 1. BRPOP from `task_queue_list_name`
                        # 2. Process it (call evaluate_fitness_ability)
                        # 3. LPUSH result to `reply_list`
                        # Here, we simulate this by directly evaluating and "pretending" it came from Redis.
                        @warn "Swarm $(swarm.id) [SIMULATED REDIS]: Simulating agent processing for task $eval_task_id. This should be done by external agent worker."
                        simulated_fitness_val = swarm.config.problem_definition.objective_function(positions_to_evaluate[original_pos_idx])
                        simulated_json_result = JSON3.write(Dict("eval_task_id"=>eval_task_id, "fitness"=>simulated_fitness_val, "worker_id"=>"simulated_worker"))
                        result_tuple = (reply_list, simulated_json_result) # Simulate a successful BRPOP
                        # --- END SIMULATION ---

                        if !isnothing(result_tuple) && length(result_tuple) == 2
                            _, json_result = result_tuple
                            result_payload = JSON3.read(json_result)
                            fitness_val = get(result_payload, "fitness", nothing)
                            
                            if !isnothing(fitness_val) && isa(fitness_val, Real)
                                evaluated_fitnesses[original_pos_idx] = Float64(fitness_val)
                                num_collected_redis += 1
                            else
                                @warn "Swarm $(swarm.id): Invalid fitness value in Redis result for task $eval_task_id." result=result_payload
                            end
                        else
                            @warn "Swarm $(swarm.id): Timeout or error receiving result from Redis for task $eval_task_id on list $reply_list."
                        end
                    catch e_redis_pop
                        @error "Swarm $(swarm.id): Error during BRPOP from Redis list $reply_list for task $eval_task_id" exception=e_redis_pop
                    end
                end
                @info "Swarm $(swarm.id): Collected $num_collected_redis/$(length(dispatched_redis_tasks)) results via Redis (simulation)."
                return evaluated_fitnesses # Return results collected via Redis
            end
        end
    end
    # --- End Redis Backend Logic ---

    # Fallback to agent polling or local evaluation if Redis not used or failed
    @debug "Swarm $(swarm.id): Falling back from Redis to local agent polling or direct local evaluation."
    if isempty(swarm.agents)
        @warn "Swarm $(swarm.id) has no agents (and Redis backend failed/disabled). Performing direct local evaluation for $(num_positions) positions."
        objective_func_actual = swarm.config.problem_definition.objective_function
        for i in 1:num_positions
            try
                evaluated_fitnesses[i] = objective_func_actual(positions_to_evaluate[i])
            catch ex
                @error "Local eval error for swarm $(swarm.id), pos $i" exception=(ex, catch_backtrace())
                # Penalty already set
            end
        end
        return evaluated_fitnesses
    end

    @info "Distributing $(num_positions) evaluations to $(length(swarm.agents)) agents for swarm $(swarm.id) via HTTP API."
    
    # Store futures for asynchronous HTTP calls
    # Each future will resolve to a Tuple{Int, Union{Float64, Nothing}} (original_pos_idx, fitness_value_or_nothing)
    evaluation_futures = []
    agent_idx_round_robin = 1
    # Define the base URL for the agent API - this should ideally come from config or service discovery
    # Assuming agents run on the same host/port as the main API for now.
    # This needs to be configurable if agents are on different hosts/ports.
    agent_api_base_url = get_config("agent.api_base_url", "http://localhost:8080/api/v1") # Example

    for i in 1:num_positions
        target_agent_id = swarm.agents[agent_idx_round_robin]
        agent_idx_round_robin = mod1(agent_idx_round_robin + 1, length(swarm.agents))

        payload = Dict(
            "objective_function_id" => objective_func_name_str,
            "candidate_solution" => positions_to_evaluate[i],
            "problem_context" => Dict{String,Any}() # Add context if needed by obj_fn via agent
        )
        json_payload = JSON3.write(payload)
        request_url = "$agent_api_base_url/agents/$target_agent_id/evaluate_fitness"
        
        # Asynchronous HTTP POST request
        future = @async begin
            try
                # Note: HTTP.request is synchronous. For true async, one might use lower-level libraries
                # or structure this with a pool of workers making HTTP requests.
                # For simplicity here, @async makes the block run concurrently.
                # Timeout for the HTTP request itself
                http_timeout = get(swarm.config.algorithm_params, "http_evaluation_timeout_seconds", 10.0)

                response = HTTP.request("POST", request_url, 
                                        ["Content-Type" => "application/json"], 
                                        json_payload; 
                                        readtimeout=http_timeout, connect_timeout=5) # Added connect_timeout
                
                if response.status == 200
                    response_body = JSON3.read(String(response.body))
                    fitness_val = get(response_body, "fitness_value", nothing)
                    if !isnothing(fitness_val) && isa(fitness_val, Real)
                        return (i, Float64(fitness_val)) # original_pos_idx, fitness
                    else
                        @warn "Swarm $(swarm.id): Agent $target_agent_id returned invalid fitness via API for pos $i." response_body=response_body
                        return (i, nothing)
                    end
                else
                    @warn "Swarm $(swarm.id): Agent $target_agent_id returned error status $(response.status) for fitness eval of pos $i." url=request_url body=String(response.body)
                    return (i, nothing)
                end
            catch e
                @error "Swarm $(swarm.id): HTTP request error during fitness evaluation for pos $i to agent $target_agent_id." exception=(e,catch_backtrace()) url=request_url
                return (i, nothing) # original_pos_idx, error indicator
            end
        end
        push!(evaluation_futures, future)
    end

    # Collect results from futures
    # This part will block until all async tasks complete or timeout (if futures had timeouts, which @async doesn't directly)
    # A more robust implementation might use fetch(future) with a global timeout for all evaluations.
    num_collected_http = 0
    for future in evaluation_futures
        try
            # Wait for each future to complete.
            # A global timeout for all evaluations might be better than waiting indefinitely for each.
            # For now, assuming futures complete reasonably.
            # `fetch` will rethrow errors from the @async block.
            result_tuple = fetch(future) # This blocks until this specific future is done
            if !isnothing(result_tuple)
                original_pos_idx, fitness_value = result_tuple
                if !isnothing(fitness_value)
                    evaluated_fitnesses[original_pos_idx] = fitness_value
                    num_collected_http +=1
                else
                    # Error already logged inside @async block, penalty fitness remains
                end
            else
                 # Should not happen if @async block always returns a tuple
                 @warn "Swarm $(swarm.id): Unexpected null result from evaluation future."
            end
        catch e_fetch
            # Error from fetching the future (e.g., task failed in @async block)
            # The error was already logged inside the @async block. Penalty fitness remains.
            @error "Swarm $(swarm.id): Error fetching result from an evaluation future." exception=(e_fetch, catch_backtrace())
        end
    end
    
    @info "Swarm $(swarm.id): Finished collecting $num_collected_http/$(num_positions) evaluations via HTTP API."
    return evaluated_fitnesses
end


function startSwarm(id::String)::Bool
    s=getSwarm(id); isnothing(s) && return false
    (s.status==SWARM_RUNNING && !isnothing(s.swarm_task_handle) && !istaskdone(s.swarm_task_handle)) && return true
    s.status==SWARM_ERROR && (@warn "Swarm $id in ERROR state."; return false)
    # isempty(s.agents) && s.config.algorithm_type != "SingleAgentDebug" && (@warn "Swarm $id has no agents."; return false) # Allow agentless for now
    s.status = SWARM_RUNNING; s.updated_at = now(UTC); s.current_iteration = 0
    s.swarm_task_handle = @task _swarm_algorithm_loop(s); schedule(s.swarm_task_handle)
    @info "Swarm $id started."; _save_swarms_state(); true
end

function stopSwarm(id::String)::Bool
    s=getSwarm(id); isnothing(s) && return false
    s.status != SWARM_RUNNING && return s.status != SWARM_ERROR
    s.status = SWARM_STOPPED; s.updated_at = now(UTC); @info "Signaled swarm $id to stop."
    _save_swarms_state(); true
end

getSwarmStatus(id::String) = (s=getSwarm(id); isnothing(s) ? nothing : Dict("id"=>s.id, "name"=>s.name, "status"=>string(s.status), "algo"=>s.config.algorithm_type, "agents"=>length(s.agents), "iter"=>s.current_iteration, "best_fit"=>isnothing(s.best_solution_found) ? nothing : s.best_solution_found.fitness, "created"=>string(s.created_at), "updated"=>string(s.updated_at)))
getSharedState(swarm_id::String, key::String, default=nothing) = (s=getSwarm(swarm_id); isnothing(s) ? default : get(s.shared_data, key, default))
function updateSharedState!(swarm_id::String, key::String, value) s=getSwarm(swarm_id); isnothing(s) ? false : (s.shared_data[key]=value; s.updated_at=now(UTC); true) end
function electLeader(swarm_id::String; kw...) s=getSwarm(swarm_id); (isnothing(s) || isempty(s.agents)) && return nothing; leader_id=first(s.agents); updateSharedState!(swarm_id, "leader_id", leader_id); @info "Agent $leader_id elected leader for swarm $swarm_id."; leader_id end
function allocateTask(swarm_id::String, task_details::Dict) s=getSwarm(swarm_id); isnothing(s) && return nothing; task_id="task-"*string(uuid4())[1:8]; task_details["id"]=task_id; task_details["status"]="pending"; push!(s.task_queue,task_details); s.updated_at=now(UTC); @info "Task $task_id allocated to swarm $swarm_id."; task_id end
claimTask(swarm_id,task_id,agent_id) = (@info "Agent $agent_id claimed task $task_id in swarm $swarm_id (placeholder)."; true) # Placeholder
completeTask(swarm_id,task_id,agent_id,result) = (@info "Agent $agent_id completed task $task_id in swarm $swarm_id (placeholder)."; true) # Placeholder
getSwarmMetrics(id) = (s=getSwarmStatus(id); isnothing(s) ? Dict("error"=>"Swarm not found") : Dict("status_summary"=>s, "queue_len"=>length(getSwarm(id).task_queue)))

function __init__()
    try SWARM_STORE_PATH[]=get_config("storage.swarm_path",DEFAULT_SWARM_STORE_PATH); SWARM_AUTO_PERSIST[]=get_config("storage.auto_persist_swarms",true); _ensure_storage_dir()
    catch e @warn "Swarms __init__: Error updating config constants." error=e end
    _register_default_objectives(); _load_swarms_state()
    @info "Swarms module initialized. $(length(SWARMS_REGISTRY)) swarms loaded. $(length(OBJECTIVE_FUNCTION_REGISTRY)) objectives registered."
end

end # module Swarms
