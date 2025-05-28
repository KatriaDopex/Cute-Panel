# src/Agents.jl

"""
Agents.jl - Core Agent Runtime

This module provides the fundamental structures and logic for managing autonomous agents,
including their lifecycle, execution loop, memory, and interaction with abilities/skills.
It orchestrates components from other specialized modules like Config, Persistence,
Metrics, Monitor, Swarm, and LLM Integration.
"""
module Agents

# ----------------------------------------------------------------------
# DEPENDENCIES
# ----------------------------------------------------------------------
using Dates, Random, UUIDs, Logging, Base.Threads
using DataStructures # OrderedDict + PriorityQueue + CircularBuffer (CircularBuffer used in Metrics)
# JSON3 and Atomic are used by Persistence, but might be needed here if
# Agent struct serialization/deserialization logic was directly in this file.
# For now, Persistence handles it.
# using Cron # Added for cron scheduling

# ----------------------------------------------------------------------
# IMPORT OTHER MODULES
# ----------------------------------------------------------------------
# Assuming these are sibling modules in the same package (e.g., in src/)
using ..Config
using ..AgentCore: Agent, AgentConfig, AgentStatus,
        AbstractAgentMemory, AbstractAgentQueue, AbstractLLMIntegration,
        CREATED, INITIALIZING, RUNNING, PAUSED, STOPPED, ERROR,
        Skill, Schedule, SkillState,
        register_ability,
        AGENTS, AGENT_THREADS, ABILITY_REGISTRY, AGENTS_LOCK,
        TaskStatus, TaskResult,
        TASK_PENDING, TASK_RUNNING, TASK_COMPLETED, TASK_FAILED, TASK_CANCELLED, TASK_UNKNOWN,
        OrderedDictAgentMemory, PriorityAgentQueue
using ..Persistence
using ..AgentMetrics
# using ..AgentMonitor
using ..LLMIntegration
# Assuming Swarm is a separate module, potentially in another directory/package
# If Swarm is in a different package, you'd need `using Swarm` in your Project.toml
# and `using Swarm` here. If it's a submodule of CutePanel, `using CutePanel.Swarm`.
# For now, we'll assume it's a sibling module in the same package for simplicity.
# import .Swarm # Use import to bring in specific functions/types

# Re-export functions/types from other modules that are part of the public API
export createAgent, getAgent, listAgents, updateAgent, deleteAgent,
       startAgent, stopAgent, pauseAgent, resumeAgent, getAgentStatus,
       executeAgentTask, getAgentMemory, setAgentMemory, clearAgentMemory,
       register_ability, register_skill,
       # Export Task Tracking functions/types (NEW)
       getTaskStatus, getTaskResult, listAgentTasks, cancelTask,
       # Export Agent Cloning function (NEW)
       cloneAgent,
       # Export Swarm functions (imported from Swarm module)
       # Swarm.publish_to_swarm, Swarm.subscribe_swarm!,
       # Export metrics functions
       get_metrics, get_agent_metrics, reset_metrics, AgentMetrics, MetricType,
       # Export monitor functions
       start_monitor, stop_monitor, get_health_status, AgentMonitor, HealthStatus,
       # Export Default Pluggable Implementations (for users to reference concrete types)
       DefaultLLMIntegration,
       # Export event triggering function
       trigger_agent_event,
       # Export fitness evaluation function
       evaluateAgentFitness


# ----------------------------------------------------------------------
# CONFIGURATION CONSTANTS (Derived from Config module)
# ----------------------------------------------------------------------
# These are constants used within this core module
const MAX_TASK_HISTORY = Config.get_config("agent.max_task_history", 100)
const XP_DECAY_RATE = Config.get_config("agent.xp_decay_rate", 0.999)
const DEFAULT_SLEEP_MS = Config.get_config("agent.default_sleep_ms", 1000) # Kept for fallback
const PAUSED_SLEEP_MS = Config.get_config("agent.paused_sleep_ms", 500)   # Kept for fallback
const AUTO_RESTART = Config.get_config("agent.auto_restart", false)


const SKILL_REGISTRY = Dict{String,Skill}()

"""
    register_skill(name::String, fn::Function; schedule::Union{Real, Schedule, Nothing}=nothing)

Registers a skill with the global skill registry.

# Arguments
- `name::String`: The name of the skill.
- `fn::Function`: The Julia function implementing the skill logic.
- `schedule::Union{Real, Schedule, Nothing}`: The scheduling definition. Can be a number (seconds for periodic), a Schedule object, or nothing for on-demand.
"""
function register_skill(name::String, fn::Function; schedule::Union{Real, Schedule, Nothing}=nothing)
    # Convert Real schedule to Periodic Schedule struct if needed
    if isa(schedule, Real) && schedule > 0
        schedule = Schedule(:periodic, schedule)
    elseif isa(schedule, Real) && schedule == 0
        schedule = nothing # 0 schedule means on-demand only (handled by ability)
    end
    SKILL_REGISTRY[name] = Skill(name, fn, schedule)
    @info "Registered skill '$name' (schedule = $(isnothing(schedule) ? "on-demand" : schedule))"
end

# Example Default LLM Integration (Uses LLMIntegration module)
struct DefaultLLMIntegration <: AbstractLLMIntegration
    # Could store config or other state here if needed
end
# Implement AbstractLLMIntegration interface
LLMIntegration.chat(llm::DefaultLLMIntegration, prompt::String; cfg::Dict) = LLMIntegration.chat(prompt; cfg=cfg)


# Helper to create pluggable components based on config (This logic would be in createAgent)
function _create_memory_component(config::Dict{String, Any})
    mem_type = get(config, "type", "ordered_dict")
    max_size = get(config, "max_size", 1000)
    if mem_type == "ordered_dict"
        return OrderedDictAgentMemory(OrderedDict{String, Any}(), max_size)
    # Add cases for other memory types
    # elseif mem_type == "database_memory"
    #    return DatabaseAgentMemory(...)
    else
        @warn "Unknown memory type '$mem_type'. Using default OrderedDictAgentMemory."
        return OrderedDictAgentMemory(OrderedDict{String, Any}(), max_size)
    end
end

function _create_queue_component(config::Dict{String, Any})
    queue_type = get(config, "type", "priority_queue")
    if queue_type == "priority_queue"
        return PriorityAgentQueue(PriorityQueue{Any, Float64}())
    # Add cases for other queue types
    # elseif queue_type == "fifo_queue"
    #    return FifoAgentQueue(...)
    else
        @warn "Unknown queue type '$queue_type'. Using default PriorityAgentQueue."
        return PriorityAgentQueue(PriorityQueue{Any, Float64}())
    end
end

function _create_llm_component(config::Dict{String, Any})
    provider = lowercase(get(config, "provider", "none"))
    if provider == "openai"
        # For now, we only have DefaultLLMIntegration which wraps LLMIntegration module
        # If you had other LLM integration concrete types, you'd choose here based on provider
        return LLMIntegration.OpenAILLMIntegration()
    else
        return nothing # No LLM integration needed
    end
end

# Swarm connection logic would ideally be in Swarm.jl, returning an AbstractSwarmBackend
# For now, the Agent struct holds `swarm_connection::Any`


# ----------------------------------------------------------------------
# CRUD (with locking for AGENTS dict and agent state) -------------------
# ----------------------------------------------------------------------
"""
    createAgent(cfg::AgentConfig)

Creates a new agent instance with a unique ID and the given configuration.
Initializes agent state including memory, queue, skills, task tracking, and locks.
Initializes pluggable components based on config.

# Arguments
- `cfg::AgentConfig`: The configuration for the new agent.

# Returns
- `Agent`: The newly created agent instance.
"""
function createAgent(cfg::AgentConfig)
    id = "agent-" * randstring(8)
    skills = Dict{String,SkillState}()
    # Initialize skills based on config's abilities (which are used to find skills)
    for ability_name in cfg.abilities
        sk = get(SKILL_REGISTRY, ability_name, nothing)
        # Only add if a skill with the same name as the ability exists
        sk === nothing && continue
        # Initialize with 0 XP and current time as last exec
        # Note: If skill has a :once schedule, last_exec should be in the past to run immediately
        initial_last_exec = now()
        if sk.schedule !== nothing && sk.schedule.type == :once
             initial_last_exec = DateTime(0) # Set to epoch to ensure it runs on first check
        end
        skills[ability_name] = SkillState(sk, 0.0, initial_last_exec)
    end

    # NEW: Create pluggable components based on config
    memory_component = _create_memory_component(cfg.memory_config)
    queue_component = _create_queue_component(cfg.queue_config)
    llm_component = _create_llm_component(cfg.llm_config)
    # Swarm connection is typically made when needed or during agent start

    ag = Agent(id, cfg.name, cfg.type, CREATED, now(), now(), cfg,
               memory_component, # NEW: Use pluggable memory
               Dict{String,Any}[],        # Start with empty task history
               skills,                    # Initialized skills
               queue_component, # NEW: Use pluggable queue
               Dict{String, TaskResult}(), # NEW: Initialize task_results
               llm_component, # NEW: Initialize LLM integration instance
               nothing, # Swarm connection starts as nothing
               ReentrantLock(),           # NEW: Initialize agent-specific lock
               Condition(),               # NEW: Initialize agent-specific condition
               nothing,                   # NEW: No error initially
               nothing,                   # NEW: No error timestamp initially
               now()                      # NEW: Initial activity timestamp
              )

    lock(AGENTS_LOCK) do # Lock the global AGENTS dict to add the new agent
        AGENTS[id] = ag
    end

    # Initialize metrics for the new agent using the AgentMetrics module
    AgentMetrics.init_agent_metrics(id)

    # State is saved periodically by the persistence task, or on stop/delete.
    # Explicit save here is optional but ensures newly created agents are persisted immediately.
    # Persistence._save_state() # Avoid saving on every creation if frequent

    @info "Created agent $(cfg.name) ($id)"
    return ag
end

"""
    getAgent(id::String)::Union{Agent, Nothing}

Retrieves an agent instance by its ID.

# Arguments
- `id::String`: The ID of the agent to retrieve.

# Returns
- `Agent` if found, otherwise `nothing`.
"""
function getAgent(id::String)::Union{Agent, Nothing}
    lock(AGENTS_LOCK) do # Lock the global AGENTS dict for lookup
        return get(AGENTS, id, nothing)
    end
end

"""
    listAgents(; filter_type=nothing, filter_status=nothing)

Lists all agents, optionally filtered by type or status.

# Arguments
- `filter_type::Union{AgentType, Nothing}`: Optional filter by agent type.
- `filter_status::Union{AgentStatus, Nothing}`: Optional filter by agent status.

# Returns
- `Vector{Agent}`: A list of matching agent instances.
"""
function listAgents(;filter_type=nothing, filter_status=nothing)
    agents_list = Agent[]
    lock(AGENTS_LOCK) do # Lock the global AGENTS dict to get a snapshot
        # Create a copy of values to avoid holding lock during filtering
        agents_list = collect(values(AGENTS))
    end

    # Apply filters outside the global lock
    if filter_type !== nothing
        filter!(a -> a.type == filter_type, agents_list)
    end
    if filter_status !== nothing
        filter!(a -> a.status == filter_status, agents_list)
    end
    return agents_list
end

"""
    updateAgent(id::String, upd::Dict{String,Any})

Updates the configuration parameters of an agent.
Note: This function does NOT change agent status. Use life-cycle functions for that.
Only 'name' and 'config.parameters' can be updated directly.

# Arguments
- `id::String`: The ID of the agent to update.
- `upd::Dict{String,Any}`: Dictionary containing fields to update.

# Returns
- `Agent` if updated, otherwise `nothing`.
"""
function updateAgent(id::String, upd::Dict{String,Any})
    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return nothing

    # Basic input validation for update payload
    if !isa(upd, Dict)
         @warn "updateAgent received invalid update payload for agent $id. Expected Dict." upd
         return nothing
    end

    updated = false
    # Acquire agent-specific lock before modifying its state/config
    lock(ag.lock) do
        if haskey(upd,"name")
            new_name = upd["name"]
            if isa(new_name, AbstractString) && !isempty(new_name) && ag.name != new_name
                 ag.name = new_name; updated = true
                 @info "Agent $id name updated to $(ag.name)"
            elseif !isa(new_name, AbstractString) || isempty(new_name)
                 @warn "Invalid or empty name provided for agent $id update." new_name
            end
        end
        # Removed direct status update capability - use start/stop/pause/resume

        if haskey(upd,"config")
            config_upd = upd["config"]
            if isa(config_upd, Dict) && haskey(config_upd,"parameters")
                # Only merge parameters for now, AgentConfig struct is immutable
                params_to_merge = get(config_upd,"parameters", Dict())
                if !isempty(params_to_merge)
                    # Basic validation: ensure params_to_merge is a Dict
                    if isa(params_to_merge, Dict)
                        merge!(ag.config.parameters, params_to_merge); updated = true
                        @info "Updated parameters for agent $id"
                    else
                        @warn "Invalid format for config.parameters update for agent $id. Expected Dict."
                    end
                end
            elseif isa(config_upd, Dict)
                 # Handle other potential config updates here if AgentConfig were mutable
                 # For now, log warning if 'config' key is present but not 'parameters'
                 @warn "Agent $id update included 'config' key but no 'parameters' sub-key or invalid format." config_upd
            else
                 @warn "Invalid format for 'config' update for agent $id. Expected Dict." config_upd
            end
        end

        if updated
            ag.updated = now()
            ag.last_activity = now() # Update activity timestamp on config change
            # State is saved periodically or on stop/delete.
            # Explicit save here is optional depending on how critical immediate persistence is.
            # Persistence._save_state()
        end
    end # Release agent-specific lock

    # Return the agent object regardless if updated or not (if found)
    return ag
end

"""
    deleteAgent(id::String)::Bool

Deletes an agent by its ID, stopping its task if running.

# Arguments
- `id::String`: The ID of the agent to delete.

# Returns
- `true` if the agent was found and deleted, `false` otherwise.
"""
function deleteAgent(id::String)::Bool
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "deleteAgent received invalid or empty ID." id
        return false
    end

    lock(AGENTS_LOCK) do # Lock the global AGENTS dict for deletion
        haskey(AGENTS, id) || return false
        ag = AGENTS[id] # Get reference before deleting from dict

        # Stop the agent task *before* removing from dict
        # stopAgent needs to handle the case where agent doesn't exist in AGENT_THREADS
        # It also needs to handle its own locking.
        stopAgent(id) # stopAgent handles missing agent/thread gracefully and saves state

        # Clean up metrics for the deleted agent using the AgentMetrics module
        AgentMetrics.reset_metrics(id)
        # Monitor module handles removing from its cache
        # AgentMonitor.get_health_status(id) # Monitor handles this

        delete!(AGENTS, id)
        # Also clean up thread entry if it exists (stopAgent should handle this too)
        haskey(AGENT_THREADS, id) && delete!(AGENT_THREADS, id)

        # State is saved by stopAgent. If agent was already stopped, save here.
        # Persistence._save_state() # Redundant if stopAgent always saves

        @info "Deleted agent $id"
        return true
    end
end

"""
    cloneAgent(id::String, new_name::String; parameter_overrides::Dict{String, Any}=Dict())

Creates a new agent by cloning the configuration of an existing agent.

# Arguments
- `id::String`: The ID of the agent to clone the configuration from.
- `new_name::String`: The name for the new agent.
- `parameter_overrides::Dict{String, Any}`: Optional parameters to override in the new agent's configuration.

# Returns
- The newly created Agent instance or nothing if the source agent is not found.
"""
function cloneAgent(id::String, new_name::String; parameter_overrides::Dict{String, Any}=Dict())
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "cloneAgent received invalid or empty source ID." id
        return nothing
    end
     if !isa(new_name, AbstractString) || isempty(new_name)
        @warn "cloneAgent received invalid or empty new name." new_name
        return nothing
    end
     if !isa(parameter_overrides, Dict)
         @warn "cloneAgent received invalid parameter_overrides payload. Expected Dict." parameter_overrides
         return nothing
     end


    source_agent = getAgent(id) # Uses global lock internally
    source_agent === nothing && (@warn "cloneAgent: Source agent $id not found"; return nothing)

    # Acquire source agent lock to get a consistent config snapshot (config is immutable, but good practice)
    lock(source_agent.lock) do
        # Create a new config based on the source agent's config
        new_params = deepcopy(source_agent.config.parameters)
        merge!(new_params, parameter_overrides) # Apply overrides

        new_config = AgentConfig(
            new_name,
            source_agent.config.type;
            abilities = deepcopy(source_agent.config.abilities), # Deepcopy mutable fields
            chains = deepcopy(source_agent.config.chains),
            parameters = new_params,
            llm_config = deepcopy(source_agent.config.llm_config),
            memory_config = deepcopy(source_agent.config.memory_config),
            queue_config = deepcopy(source_agent.config.queue_config), # NEW: Clone queue config
            max_task_history = source_agent.config.max_task_history # Max history is usually per type/config
        )

        # Create the new agent using the new config
        return createAgent(new_config)
    end # Release source agent lock
end


# ----------------------------------------------------------------------
# INTERNAL LOOP (Handles PAUSED state and uses Condition) --------------
# ----------------------------------------------------------------------
# Internal function, assumes agent lock is held by the calling context (_agent_loop)
function _process_skill!(ag::Agent, sstate::SkillState)
    # Skill processing logic (called from _agent_loop)
    # This function assumes the agent.lock is held by the caller (_agent_loop)
    # Any modifications to agent state within skill functions called by _process_skill!
    # would also need to acquire the agent.lock, or the skill function itself
    # could be designed to receive the locked agent.

    # XP decay using configurable decay factor
    sstate.xp *= Config.get_config("agent.xp_decay_rate", 0.999)
    sk = sstate.skill # Access skill definition

    if sk.schedule !== nothing # Only process scheduled skills
        should_run = false
        current_time = now()

        if sk.schedule.type == :periodic
             diff = current_time - sstate.last_exec
             # Check if schedule time has passed, allowing for small floating point inaccuracies
             if diff >= Millisecond(round(Int, sk.schedule.value * 1000)) - Millisecond(10)
                 should_run = true
             end
        elseif sk.schedule.type == :once
             # Run if last_exec is epoch time (indicating it hasn't run) and the scheduled time is past
             if sstate.last_exec == DateTime(0) && current_time >= sk.schedule.value
                 should_run = true
             end
        elseif sk.schedule.type == :cron
             # Placeholder for cron scheduling logic
             # Requires a cron parsing/checking library (e.g. Cron.jl)
            # Cron scheduling logic using Cron.jl
            # sk.schedule.value is expected to be the cron string e.g. "0 * * * *"
            if isa(sk.schedule.value, String)
                try
                    # Cron.isdue checks if the cron expression is due between last_exec and current_time
                    # If last_exec is very old, it might trigger multiple times if not handled carefully by skill logic
                    # or by ensuring last_exec is updated promptly.
                    # Cron.jl's isdue typically checks if *any* scheduled time falls in (last_exec, current_time].
                    if Cron.isdue(sk.schedule.value, sstate.last_exec) # Check against last_exec time
                        should_run = true
                    end
                catch e
                    @error "Error parsing or checking cron schedule string '$(sk.schedule.value)' for skill '$(sk.name)'" exception=(e, catch_backtrace())
                    # Consider setting agent to ERROR or disabling this skill if cron string is persistently bad.
                    should_run = false 
                end
            else
                @warn "Cron schedule value for skill '$(sk.name)' is not a string. Cron scheduling skipped."
                should_run = false
            end
        elseif sk.schedule.type == :event
             # Event-based skills are not run by the scheduler loop,
             # they would be triggered by an external event handler (e.g., in Swarm module)
             should_run = false
        else
             @warn "Unknown schedule type for skill '$(sk.name)': $(sk.schedule.type)"
             should_run = false
        end


        if should_run
            try
                @debug "Running scheduled skill '$(sk.name)' for agent $(ag.name) ($ag.id)"

                # --- Execute the skill function ---
                # Pass the agent. Ability function should acquire ag.lock if needed.
                # Skills typically don't take a task dict, but can access agent state.
                sk.fn(ag)
                # ------------------------------------

                sstate.xp += 1 # Increase XP on success
                ag.last_activity = now() # Update activity on successful skill execution
                AgentMetrics.record_metric(ag.id, "skills_executed", 1; type=AgentMetrics.COUNTER, tags=Dict("skill_name" => sk.name))

            catch e
                sstate.xp -= 2 # Decrease XP on error (consider magnitude)
                @error "Skill $(sk.name) error in agent $(ag.name) ($ag.id)" exception=(e, catch_backtrace())
                # Optionally set agent status to ERROR on critical skill failure
                # if should_set_error(e) # Define a helper function for critical errors
                #     ag.status = ERROR
                #     ag.updated = now()
                #     ag.last_error = e
                #     ag.last_error_timestamp = now()
                #     @error "Agent $(ag.name) ($ag.id) set to ERROR due to skill failure."
                # end
                AgentMetrics.record_metric(ag.id, "skill_errors", 1; type=AgentMetrics.COUNTER, tags=Dict("skill_name" => sk.name))
            end
            sstate.last_exec = current_time # Update last execution time regardless of success/failure
        end
    end
end

# Internal function: The main execution loop for an agent. Runs in its own task.
function _agent_loop(ag::Agent)
    @info "Agent loop started for $(ag.name) ($ag.id)"
    try
        # The loop runs as long as the status is not STOPPED or ERROR
        while true
            lock(ag.lock)

            try
                if ag.status == STOPPED || ag.status == ERROR
                    break  # Exit loop
                end
            finally
                unlock(ag.lock)
            end

            work_done_this_iteration = false

            # Acquire lock for this iteration's processing
            lock(ag.lock) do
                # --- Check for PAUSED status ---
                if ag.status == PAUSED
                    # Agent is paused, wait on the condition. Will be notified by resumeAgent.
                    @debug "Agent $(ag.name) ($ag.id) is paused. Waiting..."
                    ag.last_activity = now() # Update activity before waiting
                    # Release the lock while waiting on the condition
                    unlock(ag.lock)   # manually release the ReentrantLock
                    wait(ag.condition) # wait (condition internally uses SpinLock)
                    lock(ag.lock)
                    # Lock is re-acquired upon waking
                    @debug "Agent $(ag.name) ($ag.id) woke up."
                    # After waking, the loop condition `ag.status != STOPPED && ag.status != ERROR` is checked again.
                    return # Skip the rest of this iteration if paused
                end
                # -------------------------------

                # 1) Scheduled skills
                # Iterate over a copy of keys in case skills are modified (less likely here)
                current_skill_keys = collect(keys(ag.skills))
                for skill_name in current_skill_keys
                     sstate = get(ag.skills, skill_name, nothing) # Re-fetch in case deleted
                     sstate === nothing && continue
                     # _process_skill! assumes agent.lock is held
                     _process_skill!(ag, sstate)
                     # Note: _process_skill! only runs if its schedule is due
                end

                # 2) Queued messages (now processing task_ids)
                # Use isempty and length from the AbstractAgentQueue interface
                if !isempty(ag.queue)
                    work_done_this_iteration = true # Work found
                    @debug "Agent $(ag.name) ($ag.id) processing queue. Queue size: $(length(ag.queue))"

                    # Dequeue task_id using the AbstractAgentQueue interface
                    task_id = dequeue!(ag.queue)

                    # Retrieve TaskResult using task_id
                    task_result = get(ag.task_results, task_id, nothing)
                    if task_result === nothing
                        @warn "Dequeued unknown or missing task result for ID $task_id for agent $(ag.name) ($ag.id). Skipping."
                        # Record a metric for invalid queue items
                        AgentMetrics.record_metric(ag.id, "queue_invalid_items", 1; type=AgentMetrics.COUNTER)
                        AgentMetrics.record_metric(ag.id, "queue_size", length(ag.queue); type=AgentMetrics.GAUGE) # Update queue size metric
                        return # Continue to the next iteration
                    end

                    # If task was cancelled externally, skip execution
                    if task_result.status == TASK_CANCELLED
                        @debug "Task $task_id for agent $(ag.name) ($ag.id) was cancelled. Skipping execution."
                        AgentMetrics.record_metric(ag.id, "tasks_cancelled", 1; type=AgentMetrics.COUNTER)
                        AgentMetrics.record_metric(ag.id, "queue_size", length(ag.queue); type=AgentMetrics.GAUGE) # Update queue size metric
                        return # Continue to the next iteration
                    end

                    # Update TaskResult status to RUNNING
                    task_result.status = TASK_RUNNING
                    task_result.start_time = now()

                    task = task_result.input_task # Get the original task payload

                    ability_name = get(task, "ability", "")
                    if !isempty(ability_name)
                        f = get(ABILITY_REGISTRY, ability_name, nothing)
                        if f !== nothing
                            try
                                @debug "Executing queued ability '$ability_name' ($task_id) for agent $(ag.name) ($ag.id)"
                                # --- Execute the ability function ---
                                # Pass the agent and task. Ability function should acquire ag.lock if needed.
                                output = f(ag, task)
                                # ------------------------------------

                                # Update TaskResult on success
                                task_result.status = TASK_COMPLETED
                                task_result.end_time = now()
                                task_result.output_result = output

                                ag.last_activity = now() # Update activity

                                # --- Add to Task History (with capping) ---
                                max_hist = ag.config.max_task_history
                                if max_hist > 0
                                    # Store task_id in history entry for traceability
                                    history_entry = Dict("timestamp"=>now(), "task_id"=>task_id, "input"=>task, "output"=>output)
                                    push!(ag.task_history, history_entry)
                                    while length(ag.task_history) > max_hist
                                        popfirst!(ag.task_history)
                                    end
                                end
                                # ------------------------------------------

                                AgentMetrics.record_metric(ag.id, "tasks_executed_queued", 1; type=AgentMetrics.COUNTER, tags=Dict("ability_name" => ability_name))
                                AgentMetrics.record_metric(ag.id, "queue_size", length(ag.queue); type=AgentMetrics.GAUGE) # Update queue size metric

                            catch e
                                @error "Error executing queued ability '$ability_name' ($task_id) for agent $(ag.name) ($ag.id)" exception=(e, catch_backtrace())
                                # Update TaskResult on failure
                                task_result.status = TASK_FAILED
                                task_result.end_time = now()
                                task_result.error_details = e

                                # Set agent status to ERROR on ability failure
                                ag.status = ERROR
                                ag.updated = now()
                                ag.last_error = e
                                ag.last_error_timestamp = now()
                                @error "Agent $(ag.name) ($ag.id) set to ERROR due to queued task failure."
                                # The loop will exit in the next iteration check

                                AgentMetrics.record_metric(ag.id, "task_errors_queued", 1; type=AgentMetrics.COUNTER, tags=Dict("ability_name" => ability_name))
                            end
                        else
                            @warn "Unknown ability '$ability_name' in queued task $task_id for agent $(ag.name) ($ag.id)"
                            # Update TaskResult for invalid ability
                            task_result.status = TASK_FAILED
                            task_result.end_time = now()
                            task_result.error_details = ErrorException("Unknown ability: '$ability_name'")
                             AgentMetrics.record_metric(ag.id, "task_errors_queued", 1; type=AgentMetrics.COUNTER, tags=Dict("ability_name" => ability_name, "error_type" => "unknown_ability"))
                        end
                    else
                        @warn "Queued task $task_id has no 'ability' key for agent $(ag.name) ($ag.id)"
                         # Update TaskResult for invalid task payload
                        task_result.status = TASK_FAILED
                        task_result.end_time = now()
                        task_result.error_details = ErrorException("Task has no 'ability' key")
                        AgentMetrics.record_metric(ag.id, "task_errors_queued", 1; type=AgentMetrics.COUNTER, tags=Dict("error_type" => "missing_ability_key"))
                    end
                end # end queue processing

                # --- Intelligent Waiting ---
                # If no work was done, wait on the condition.
                # This task will be woken by new queue items or status changes (like resume).
                if !work_done_this_iteration
                    @debug "Agent $(ag.name) ($ag.id) idle. Waiting..."
                    ag.last_activity = now() # Update activity before waiting
                    # Release the lock while waiting on the condition
                    unlock(ag.lock)   # manually release the ReentrantLock
                    wait(ag.condition) # wait (condition internally uses SpinLock)
                    lock(ag.lock)
                    # Lock is re-acquired upon waking
                    @debug "Agent $(ag.name) ($ag.id) woke up."
                else
                    # If work was done, yield to allow other tasks to run, then continue loop
                    yield()
                end

            end # Release agent.lock

            # The loop condition is checked again at the start of the next iteration.

        end # End while loop (exits if status is STOPPED or ERROR)

    catch e
        # This catch block handles errors that escape the inner processing (less likely with inner try/catch)
        lock(ag.lock) do # Acquire lock to update status on crash
            ag.status = ERROR
            ag.updated = now()
            ag.last_error = e
            ag.last_error_timestamp = now()
            @error "Agent $(ag.name) ($ag.id) loop crashed unexpectedly!" exception=(e, catch_backtrace())
        end # Release lock
        # Rethrow? Or just log and let the status indicate error?
        # rethrow(e)
    finally
        # This block runs when the task finishes (either normally or via error)
        lock(ag.lock) do # Acquire lock to ensure final status update is safe
            # Ensure status is updated if loop terminates normally (e.g., by stopAgent setting status)
            # If loop exited due to status change (STOPPED/ERROR), keep that status
            if ag.status != STOPPED && ag.status != ERROR
                ag.status = STOPPED
                ag.updated = now()
                @info "Agent loop finished for $(ag.name) ($ag.id). Setting status to STOPPED."
            else
                 @info "Agent loop finished for $(ag.name) ($ag.id). Final status: $(ag.status)."
            end
            ag.last_activity = now() # Final activity timestamp
        end # Release lock

        # Clean up thread entry from global dict (under global lock)
        lock(AGENTS_LOCK) do
            haskey(AGENT_THREADS, ag.id) && delete!(AGENT_THREADS, ag.id) # Use 'ag.id' here
        end

        # Save state after an agent task finishes (especially if it ended in STOPPED/ERROR)
        # Persistence._save_state() # Call the Persistence module's save function
        lock(AGENTS_LOCK) do # _save_state requires AGENTS_LOCK
            Persistence._save_state()
        end

        # Call the separate auto-restart handler function
        _handle_auto_restart(ag)
    end
end


# ----------------------------------------------------------------------
# LIFE-CYCLE (Pause/Resume now works with Condition) -------------------
# ----------------------------------------------------------------------
"""
    startAgent(id::String)::Bool

Starts the execution loop for an agent.

# Arguments
- `id::String`: The ID of the agent to start.

# Returns
- `true` if the agent was started or is already running/initializing/paused, `false` otherwise.
"""
function startAgent(id::String)::Bool
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "startAgent received invalid or empty ID." id
        return false
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && (@warn "startAgent: Agent $id not found"; return false)

    # Acquire agent-specific lock to check/update status and thread
    lock(ag.lock) do
        # Get the task reference safely under global lock if needed, but status check is primary
        # current_task = lock(AGENTS_LOCK) do get(AGENT_THREADS, id, nothing) end

        if ag.status == RUNNING
             @warn "Agent $id ($(ag.name)) is already running."
             return true # Indicate it's effectively running
        elseif ag.status == PAUSED
             @warn "Agent $id ($(ag.name)) is paused. Use resumeAgent() to resume."
             return false # Indicate failure to start because it's paused
        elseif ag.status == INITIALIZING
             @warn "Agent $id ($(ag.name)) is already initializing."
             return true # Indicate it's effectively starting
        elseif ag.status == ERROR
             @warn "Agent $id ($(ag.name)) is in ERROR state. Cannot start directly. Reset agent status first."
             return false # Cannot start from ERROR without reset/recreate
        end

        # If status is CREATED or STOPPED, it's okay to start
        @info "Starting agent $(ag.name) ($id)..."
        ag.status = INITIALIZING # Set status under lock
        ag.updated = now()
        ag.last_activity = now() # Reset activity timestamp

        # Create and schedule the new task
        # This task needs to update AGENT_THREADS under the global lock
        task = @task begin
            try
                # Set status to RUNNING *inside* the task, after initialization phase (if any)
                # Acquire agent lock for status change
                lock(ag.lock) do
                    ag.status = RUNNING
                    ag.updated = now()
                    ag.last_activity = now() # Reset activity on entering RUNNING
                    @info "Agent $(ag.name) ($ag.id) status set to RUNNING."
                    # Notify the condition in case the loop was waiting while status was INITIALIZING
                    notify(ag.condition)
                end # Release agent lock

                _agent_loop(ag) # Run the main loop

            catch task_err
                # This catch block handles errors that escape _agent_loop's try/finally
                lock(ag.lock) do # Acquire agent lock for status change
                    ag.status = ERROR # Ensure status reflects error
                    ag.updated = now()
                    ag.last_error = task_err
                    ag.last_error_timestamp = now()
                    @error "Unhandled error in agent task for $id ($(ag.name))" exception=(task_err, catch_backtrace())
                end # Release agent lock
            finally
                # The _agent_loop's finally block handles final status and AGENT_THREADS cleanup
                @info "Agent task finished for $(ag.name) ($id)."
            end
        end

        # Store the task reference under global lock
        lock(AGENTS_LOCK) do
             AGENT_THREADS[id] = task
        end

        schedule(task) # Schedule the task
        return true
    end # Release agent-specific lock
end

"""
    stopAgent(id::String)::Bool

Signals an agent's execution loop to stop and waits for it to finish.

# Arguments
- `id::String`: The ID of the agent to stop.

# Returns
- `true` if the agent was stopped or is already stopped/errored/not found, `false` otherwise (e.g., if waiting failed).
"""
function stopAgent(id::String)::Bool
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "stopAgent received invalid or empty ID." id
        return false
    end

    ag = getAgent(id) # Uses global lock internally
    # No agent found, nothing to stop - goal is achieved
    ag === nothing && return true

    # Acquire agent-specific lock to check/update status and signal
    lock(ag.lock) do
        if ag.status == STOPPED || ag.status == ERROR
            @warn "Agent $id ($(ag.name)) is already in status $(ag.status). No action needed."
            return true # Already achieved
        end

        @info "Stopping agent $(ag.name) ($id)..."
        ag.status = STOPPED # Signal the loop to exit (under lock)
        ag.updated = now()
        ag.last_activity = now() # Update activity timestamp

        # Notify the condition to wake up the agent loop if it's waiting
        notify(ag.condition)

        # Get the task reference (requires global lock access)
        current_task = lock(AGENTS_LOCK) do
            get(AGENT_THREADS, id, nothing)
        end

        if current_task === nothing || istaskdone(current_task)
            @warn "Agent $id ($(ag.name)) status was $(ag.status), but no active task found. Setting status to STOPPED."
            # Status is already set to STOPPED under ag.lock above.
            # Ensure thread entry is clean (done in task finally block, but defensive check)
             lock(AGENTS_LOCK) do
                haskey(AGENT_THREADS, id) && delete!(AGENT_THREADS, id)
             end
            # Save state immediately as the task won't do it
            lock(AGENTS_LOCK) do # _save_state requires AGENTS_LOCK
                Persistence._save_state()
            end
            return true # Agent is effectively stopped
        end

        # Task exists and is not done, wait for it to finish
        # Release agent lock while waiting to avoid deadlocks if the task needs the lock
        unlock(ag.lock)
        try
            # TODO: Add a timeout to the wait to prevent hanging indefinitely
            wait(current_task)
            @info "Agent $(ag.name) ($id) task finished after stop signal."
            return true
        catch e
            @error "Error occurred while waiting for agent $id ($(ag.name)) task to stop." exception=(e, catch_backtrace())
            # Re-acquire lock to update status if wait failed
            lock(ag.lock) do
                 ag.status = ERROR # Indicate stopping failed or task ended in error
                 ag.updated = now()
                 ag.last_error = e
                 ag.last_error_timestamp = now()
            end
            return false # Indicate stopping process failed
        finally
             # Ensure lock is re-acquired if an error occurred in wait
             islocked(ag.lock) || lock(ag.lock)
             # The task's finally block should handle AGENT_THREADS cleanup and state saving.
             # If wait failed, the task might still be running or in a bad state.
        end
    end # Release agent-specific lock (or re-acquired in finally)
end

"""
    pauseAgent(id::String)::Bool

Pauses a running agent's execution loop.

# Arguments
- `id::String`: The ID of the agent to pause.

# Returns
- `true` if the agent was paused or is already paused, `false` otherwise.
"""
function pauseAgent(id::String)::Bool
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "pauseAgent received invalid or empty ID." id
        return false
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && (@warn "pauseAgent: Agent $id not found"; return false)

    lock(ag.lock) do # Acquire agent-specific lock
        if ag.status == RUNNING
            ag.status = PAUSED
            ag.updated = now()
            ag.last_activity = now() # Update activity timestamp
            @info "Agent $(ag.name) ($id) paused."
            # No need to notify the condition here, the loop checks status at the start
            # and will enter the `wait` block if status is PAUSED.
            # Persistence._save_state() # Save status change
            return true
        elseif ag.status == PAUSED
            @warn "Agent $(ag.name) ($id) is already paused."
            return true # Already achieved
        else
            state = string(ag.status) # Get status under lock
            @warn "Cannot pause agent $(ag.name) ($id). State: $state. Must be RUNNING."
            return false
        end
    end # Release agent-specific lock
end

"""
    resumeAgent(id::String)::Bool

Resumes a paused agent's execution loop.

# Arguments
- `id::String`: The ID of the agent to resume.

# Returns
- `true` if the agent was resumed or is already running, `false` otherwise.
"""
function resumeAgent(id::String)::Bool
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "resumeAgent received invalid or empty ID." id
        return false
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && (@warn "resumeAgent: Agent $id not found"; return false)

    lock(ag.lock) do # Acquire agent-specific lock
        if ag.status == PAUSED
            ag.status = RUNNING
            ag.updated = now()
            ag.last_activity = now() # Update activity timestamp
            @info "Agent $(ag.name) ($id) resumed."
            # Notify the condition to wake up the agent loop from the wait state
            notify(ag.condition)
            # Persistence._save_state() # Save status change
            return true
        elseif ag.status == RUNNING
            @warn "Agent $(ag.name) ($id) is already running."
            return true # Already achieved
        else
            state = string(ag.status) # Get status under lock
            @warn "Cannot resume agent $(ag.name) ($id). State: $state. Must be PAUSED."
            return false
        end
    end # Release agent-specific lock
end

# ----------------------------------------------------------------------
# STATUS ---------------------------------------------------------------
# ----------------------------------------------------------------------
"""
    getAgentStatus(id::String)::Dict{String, Any}

Retrieves the current status and relevant metrics for an agent.

# Arguments
- `id::String`: The ID of the agent.

# Returns
- `Dict` containing status information, or an error dictionary if the agent is not found.
"""
function getAgentStatus(id::String)::Dict{String, Any}
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "getAgentStatus received invalid or empty ID." id
        return Dict("status"=>"error", "error"=>"Invalid agent ID")
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return Dict("status"=>"not_found", "error"=>"Agent $id not found")

    # Acquire agent-specific lock to get a consistent snapshot of its state
    lock(ag.lock) do
        # Calculate uptime if running/paused (based on last status change to RUNNING/PAUSED/INITIALIZING)
        uptime_sec = 0
        if ag.status in (RUNNING, PAUSED, INITIALIZING)
            try
                # Uptime from the moment it entered a running/paused/initializing state
                # Using 'updated' is a proxy, ideally we'd track 'last_started_or_resumed'
                uptime_sec = round(Int, (now() - ag.updated).value / 1000)
            catch e
                @warn "Error calculating uptime for agent $id" exception=e
                uptime_sec = -1 # Indicate error
            end
        end

        # Calculate time since last activity
        time_since_activity_sec = round(Int, (now() - ag.last_activity).value / 1000)

        # Use length from AbstractAgentQueue interface
        queue_len = length(ag.queue)

        # Use length from AbstractAgentMemory interface
        memory_size = length(ag.memory)


        return Dict(
            "id" => ag.id,
            "name" => ag.name,
            "type" => string(ag.type),
            "status" => string(ag.status),
            "uptime_seconds" => uptime_sec,
            "time_since_last_activity_seconds" => time_since_activity_sec, # NEW
            "tasks_completed" => length(ag.task_history), # Note: History might be capped
            "queue_len" => queue_len, # Use interface
            "memory_size" => memory_size, # Use interface
            "last_updated" => string(ag.updated),
            "last_activity" => string(ag.last_activity), # NEW
            "last_error" => isnothing(ag.last_error) ? nothing : string(ag.last_error), # NEW
            "last_error_timestamp" => isnothing(ag.last_error_timestamp) ? nothing : string(ag.last_error_timestamp) # NEW
        )
    end # Release agent-specific lock
end

# ----------------------------------------------------------------------
# TASK EXECUTION (with history capping and queueing) ------------------
# ----------------------------------------------------------------------
"""
    executeAgentTask(id::String, task::Dict{String,Any})::Dict{String, Any}

Submits a task for an agent to execute.
Tasks can be executed directly or added to the agent's queue based on the 'mode' field.

# Arguments
- `id::String`: The ID of the target agent.
- `task::Dict{String,Any}`: The task definition. Must include an 'ability' key for execution.
                            Optional 'mode' ("direct" or "queue", default "direct").
                            Optional 'priority' (Number, lower is higher priority) for queue mode.

# Returns
- `Dict` containing the result of direct execution or confirmation of queueing, or an error.
         Includes a `task_id` for tracking asynchronous tasks.
"""
function executeAgentTask(id::String, task::Dict{String,Any})::Dict{String, Any}
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "executeAgentTask received invalid or empty agent ID." id
        return Dict("success"=>false, "error"=>"Invalid agent ID")
    end
    if !isa(task, Dict)
         @warn "executeAgentTask received invalid task payload for agent $id. Expected Dict." task
         return Dict("success"=>false, "error"=>"Invalid task payload format. Expected Dict.", "agent_id"=>id)
    end
    if !haskey(task, "ability") || !isa(task["ability"], AbstractString) || isempty(task["ability"])
         @warn "executeAgentTask received task without 'ability' key for agent $id." task
         return Dict("success"=>false, "error"=>"Task must include a non-empty 'ability' key.", "agent_id"=>id)
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return Dict("success"=>false, "error"=>"Agent $id not found")

    task_id = string(uuid4()) # Generate unique task ID
    submitted_time = now()

    # Create the initial TaskResult
    task_result = TaskResult(task_id;
                         status=TASK_PENDING,
                         submitted=submitted_time,
                         start_time=nothing,
                         end_time=nothing,
                         output_result=nothing,
                         error_details=nothing)

    lock(ag.lock) do
        # Check if agent is in a state that can receive tasks (RUNNING or PAUSED)
        # Allowing tasks while PAUSED means they will be processed when resumed.
        if ag.status != RUNNING && ag.status != PAUSED
            # Update TaskResult status to FAILED before returning
            task_result.status = TASK_FAILED
            task_result.end_time = now()
            task_result.error_details = ErrorException("Agent not in RUNNING or PAUSED state (status: $(ag.status))")
            ag.task_results[task_id] = task_result # Store the failed task result
            return Dict("success"=>false, "error"=>"Agent $(ag.name) is not RUNNING or PAUSED (status: $(ag.status))", "agent_id"=>id, "task_id"=>task_id)
        end

        ag.task_results[task_id] = task_result # Store the task result

        # --- QUEUE MODE ---
        # Check for "mode" key, default to "direct" if not present
        mode = get(task, "mode", "direct")
        if mode == "queue"
            # Add task_id to the agent's priority queue
            # Lower number = higher priority. Negate user priority for Min-Heap behavior.
            prio = -float(get(task, "priority", 0.0)) # Basic validation for priority type?
            try
                # Use enqueue! from the AbstractAgentQueue interface
                enqueue!(ag.queue, task_id, prio) # Enqueue task_id instead of task dict
                ag.last_activity = now()
                @info "Task $task_id queued for agent $(ag.name) ($id) with priority $(abs(prio)). Queue size: $(length(ag.queue))"
                # Notify the agent's condition to wake it up if it's waiting
                notify(ag.condition) # Notify the agent's loop that there's new work
                AgentMetrics.record_metric(id, "tasks_queued", 1; type=AgentMetrics.COUNTER)
                AgentMetrics.record_metric(id, "queue_size", length(ag.queue); type=AgentMetrics.GAUGE)
                return Dict("success"=>true, "queued"=>true, "agent_id"=>id, "task_id"=>task_id, "queue_length"=>length(ag.queue))
            catch e
                @error "Failed to enqueue task $task_id for agent $id" exception=(e, catch_backtrace())
                # Update TaskResult status to FAILED before returning
                task_result.status = TASK_FAILED
                task_result.end_time = now()
                task_result.error_details = e
                AgentMetrics.record_metric(id, "task_errors_enqueue", 1; type=AgentMetrics.COUNTER)
                return Dict("success"=>false, "error"=>"Failed to enqueue task: $(string(e))", "agent_id"=>id, "task_id"=>task_id)
            end
        end

        # --- DIRECT EXECUTION MODE ---
        # Only allow direct execution if the agent is RUNNING
        if ag.status != RUNNING
             # Update TaskResult status to FAILED before returning
            task_result.status = TASK_FAILED
            task_result.end_time = now()
            task_result.error_details = ErrorException("Agent is PAUSED. Direct execution is only allowed when RUNNING. Use mode='queue'.")
             return Dict("success"=>false, "error"=>"Agent $(ag.name) is PAUSED. Direct execution is only allowed when RUNNING. Use mode='queue'.", "agent_id"=>id, "task_id"=>task_id)
        end

        ability_name = get(task, "ability", "")
        f = get(ABILITY_REGISTRY, ability_name, nothing)
        if f === nothing
             # Update TaskResult status to FAILED before returning
            task_result.status = TASK_FAILED
            task_result.end_time = now()
            task_result.error_details = ErrorException("Unknown ability: '$ability_name'")
            return Dict("success"=>false, "error"=>"Unknown ability: '$ability_name'", "agent_id"=>id, "task_id"=>task_id)
        end

        try
            @debug "Executing direct task '$ability_name' ($task_id) for agent $(ag.name) ($id)"
            # Update TaskResult status to RUNNING
            task_result.status = TASK_RUNNING
            task_result.start_time = now()

            # --- Execute the ability function ---
            # Pass the agent and task. Ability function should acquire ag.lock if needed.
            output = f(ag, task)
            # ------------------------------------
            ag.last_activity = now()

            # Update TaskResult on success
            task_result.status = TASK_COMPLETED
            task_result.end_time = now()
            task_result.output_result = output

            # --- Add to Task History (with capping) ---
            max_hist = ag.config.max_task_history
            if max_hist > 0
                # Store task_id in history entry for traceability
                history_entry = Dict("timestamp"=>now(), "task_id"=>task_id, "input"=>task, "output"=>output)
                push!(ag.task_history, history_entry)
                while length(ag.task_history) > max_hist
                    popfirst!(ag.task_history)
                end
            end
            # ------------------------------------------

            AgentMetrics.record_metric(id, "tasks_executed_direct", 1; type=AgentMetrics.COUNTER, tags=Dict("ability_name" => ability_name))


            # Return success merged with the output from the ability
            # Ensure output is a Dict or handle other types
            result_data = isa(output, Dict) ? output : Dict("result" => output)
            return merge(Dict("success"=>true, "queued"=>false, "agent_id"=>id, "task_id"=>task_id), result_data)

        catch e
            @error "Error executing task '$ability_name' ($task_id) for agent $id" exception=(e, catch_backtrace())
            # Update TaskResult on failure
            task_result.status = TASK_FAILED
            task_result.end_time = now()
            task_result.error_details = e

            # Set agent status to ERROR on direct execution failure
            ag.status = ERROR
            ag.updated = now()
            ag.last_error = e
            ag.last_error_timestamp = now()
            @error "Agent $(ag.name) ($id) set to ERROR due to direct task failure."

            AgentMetrics.record_metric(id, "task_errors_direct", 1; type=AgentMetrics.COUNTER, tags=Dict("ability_name" => ability_name))
            return Dict("success"=>false, "error"=>"Execution error: $(string(e))", "queued"=>false, "agent_id"=>id, "task_id"=>task_id)
        end
    end # Release agent-specific lock
end


# ----------------------------------------------------------------------
# TASK TRACKING API (NEW)
# ----------------------------------------------------------------------
"""
    getTaskStatus(id::String, task_id::String)::Dict{String, Any}

Retrieves the current status of a specific task for an agent.

# Arguments
- `id::String`: The ID of the agent.
- `task_id::String`: The ID of the task.

# Returns
- `Dict` containing the task status and metadata, or an error dictionary if the agent or task is not found.
"""
function getTaskStatus(id::String, task_id::String)::Dict{String, Any}
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "getTaskStatus received invalid or empty agent ID." id
        return Dict("status"=>"error", "error"=>"Invalid agent ID")
    end
     if !isa(task_id, AbstractString) || isempty(task_id)
        @warn "getTaskStatus received invalid or empty task ID." task_id
        return Dict("status"=>"error", "error"=>"Invalid task ID")
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return Dict("status"=>"error", "error"=>"Agent $id not found")
    lock(ag.lock) do # Acquire agent-specific lock
        task_result = get(ag.task_results, task_id, nothing)
        if task_result === nothing
            return Dict("status"=>"error", "error"=>"Task $task_id not found for agent $id")
        end
        return Dict(
            "task_id" => task_result.task_id,
            "status" => string(task_result.status),
            "submitted_time" => string(task_result.submitted_time),
            "start_time" => isnothing(task_result.start_time) ? nothing : string(task_result.start_time),
            "end_time" => isnothing(task_result.end_time) ? nothing : string(task_result.end_time),
            "ability" => get(task_result.input_task, "ability", "N/A")
        )
    end # Release agent-specific lock
end

"""
    getTaskResult(id::String, task_id::String)::Dict{String, Any}

Retrieves the result or error details of a completed or failed task.

# Arguments
- `id::String`: The ID of the agent.
- `task_id::String`: The ID of the task.

# Returns
- `Dict` containing the task status and result/error, or an error dictionary.
"""
function getTaskResult(id::String, task_id::String)::Dict{String, Any}
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "getTaskResult received invalid or empty agent ID." id
        return Dict("status"=>"error", "error"=>"Invalid agent ID")
    end
     if !isa(task_id, AbstractString) || isempty(task_id)
        @warn "getTaskResult received invalid or empty task ID." task_id
        return Dict("status"=>"error", "error"=>"Invalid task ID")
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return Dict("status"=>"error", "error"=>"Agent $id not found")
    lock(ag.lock) do # Acquire agent-specific lock
        task_result = get(ag.task_results, task_id, nothing)
        if task_result === nothing
            return Dict("status"=>"error", "error"=>"Task $task_id not found for agent $id")
        end
        if task_result.status in (TASK_PENDING, TASK_RUNNING)
            return Dict("status"=>string(task_result.status), "message"=>"Task is not yet completed or failed.", "task_id"=>task_id)
        end
        result_dict = Dict(
            "task_id" => task_result.task_id,
            "status" => string(task_result.status),
            "submitted_time" => string(task_result.submitted_time),
            "start_time" => isnothing(task_result.start_time) ? nothing : string(task_result.start_time),
            "end_time" => string(task_result.end_time),
            "input" => task_result.input_task # May want to filter sensitive info here in a real API layer
        )
        if task_result.status == TASK_COMPLETED
            result_dict["result"] = task_result.output_result
        elseif task_result.status == TASK_FAILED || task_result.status == TASK_CANCELLED
            result_dict["error"] = isnothing(task_result.error_details) ? "Unknown error" : string(task_result.error_details)
        end
        return result_dict
    end # Release agent-specific lock
end

"""
    listAgentTasks(id::String; status_filter::Union{TaskStatus, Nothing}=nothing, limit::Int=100)::Dict{String, Any}

Lists tasks submitted to an agent, optionally filtered by status and limited by count.
Returns the most recent tasks first.

# Arguments
- `id::String`: The ID of the agent.
- `status_filter::Union{TaskStatus, Nothing}`: Optional filter by task status.
- `limit::Int`: Maximum number of tasks to return.

# Returns
- `Dict` containing a list of task status summaries, or an error dictionary.
"""
function listAgentTasks(id::String; status_filter::Union{TaskStatus, Nothing}=nothing, limit::Int=100)::Dict{String, Any}
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "listAgentTasks received invalid or empty agent ID." id
        return Dict("status"=>"error", "error"=>"Invalid agent ID")
    end
     if !isa(limit, Integer) || limit < 0
         @warn "listAgentTasks received invalid limit. Using default 100." limit
         limit = 100
     end
     if status_filter !== nothing && !isa(status_filter, TaskStatus)
         @warn "listAgentTasks received invalid status_filter type." status_filter
         status_filter = nothing # Ignore invalid filter
     end


    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return Dict("status"=>"error", "error"=>"Agent $id not found")

    lock(ag.lock) do # Acquire agent-specific lock
        tasks = collect(values(ag.task_results)) # Get all task results
        # Sort by submitted time, most recent first
        sort!(tasks, by = t -> t.submitted_time, rev=true)

        # Apply status filter
        if status_filter !== nothing
            filter!(t -> t.status == status_filter, tasks)
        end

        # Apply limit
        if length(tasks) > limit
            tasks = tasks[1:limit]
        end

        # Format results (return summary, not full input/output/error)
        formatted_tasks = [
            Dict(
                "task_id" => t.task_id,
                "status" => string(t.status),
                "submitted_time" => string(t.submitted_time),
                "start_time" => isnothing(t.start_time) ? nothing : string(t.start_time),
                "end_time" => isnothing(t.end_time) ? nothing : string(t.end_time),
                "ability" => get(t.input_task, "ability", "N/A")
            ) for t in tasks
        ]

        return Dict("success"=>true, "agent_id"=>id, "tasks"=>formatted_tasks, "count"=>length(formatted_tasks))
    end # Release agent-specific lock
end

"""
    cancelTask(id::String, task_id::String)::Dict{String, Any}

Attempts to cancel a pending or running task for an agent.
Note: Running tasks may not be immediately interruptible depending on the ability implementation.

# Arguments
- `id::String`: The ID of the agent.
- `task_id::String`: The ID of the task to cancel.

# Returns
- `Dict` indicating success or failure of the cancellation request.
"""
function cancelTask(id::String, task_id::String)::Dict{String, Any}
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "cancelTask received invalid or empty agent ID." id
        return Dict("success"=>false, "error"=>"Invalid agent ID")
    end
     if !isa(task_id, AbstractString) || isempty(task_id)
        @warn "cancelTask received invalid or empty task ID." task_id
        return Dict("success"=>false, "error"=>"Invalid task ID")
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return Dict("success"=>false, "error"=>"Agent $id not found")

    lock(ag.lock) do # Acquire agent-specific lock
        task_result = get(ag.task_results, task_id, nothing)
        if task_result === nothing
            return Dict("success"=>false, "error"=>"Task $task_id not found for agent $id")
        end

        if task_result.status in (TASK_PENDING, TASK_RUNNING)
            @info "Attempting to cancel task $task_id for agent $(ag.name) ($id). Current status: $(task_result.status)"
            task_result.status = TASK_CANCELLED # Set status to CANCELLED
            task_result.end_time = now()
            task_result.error_details = ErrorException("Task cancelled by user.")
            ag.last_activity = now() # Update activity
            # Notify the agent's loop in case it's waiting or about to pick up the task
            notify(ag.condition)
            AgentMetrics.record_metric(id, "tasks_cancel_requested", 1; type=AgentMetrics.COUNTER)
            return Dict("success"=>true, "task_id"=>task_id, "message"=>"Cancellation requested. Task status set to CANCELLED.")
        else
            @warn "Cannot cancel task $task_id for agent $id. Task is already in status: $(task_result.status)"
            return Dict("success"=>false, "task_id"=>task_id, "error"=>"Task is not pending or running. Current status: $(task_result.status)")
        end
    end # Release agent-specific lock
end


# ----------------------------------------------------------------------
# MEMORY ACCESS (LRU handled with locking) -----------------------------
# ----------------------------------------------------------------------
# These functions now dispatch to the methods of the AbstractAgentMemory instance

"""
    getAgentMemory(id::String, key::String)

Retrieves a value from an agent's memory by key, updating its LRU status.

# Arguments
- `id::String`: The ID of the agent.
- `key::String`: The memory key.

# Returns
- The value associated with the key, or `nothing` if the agent or key is not found.
"""
function getAgentMemory(id::String, key::String)
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "getAgentMemory received invalid or empty agent ID." id
        return nothing
    end
     if !isa(key, AbstractString) || isempty(key)
        @warn "getAgentMemory received invalid or empty key." key
        return nothing
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return nothing # Agent not found

    # Acquire agent-specific lock for memory access
    lock(ag.lock) do
        # Use the interface method
        val = get_value(ag.memory, key)
        if val !== nothing # get_value should handle LRU touch internally
             ag.last_activity = now() # Update activity on memory access
        end
        return val
    end # Release agent-specific lock
end

"""
    setAgentMemory(id::String, key::String, val)::Bool

Sets a value in an agent's memory, updating LRU status and enforcing size limits.

# Arguments
- `id::String`: The ID of the agent.
- `key::String`: The memory key.
- `val`: The value to store.

# Returns
- `true` if the memory was set, `false` if the agent was not found.
"""
function setAgentMemory(id::String, key::String, val)::Bool
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "setAgentMemory received invalid or empty agent ID." id
        return false
    end
     if !isa(key, AbstractString) || isempty(key)
        @warn "setAgentMemory received invalid or empty key." key
        return false
    end
    # Note: val can be Any, so no type validation needed for val itself

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return false

    # Acquire agent-specific lock for memory modification
    lock(ag.lock) do
        # Use the interface method
        set_value!(ag.memory, key, val) # set_value! should handle LRU touch and size limit internally
        ag.last_activity = now() # Update activity on memory modification

        # State is saved periodically or on stop/delete.
        # Persistence._save_state() # Avoid saving on every memory set if frequent

        return true
    end # Release agent-specific lock
end

"""
    clearAgentMemory(id::String)::Bool

Clears all memory for a specific agent.

# Arguments
- `id::String`: The ID of the agent.

# Returns
- `true` if the memory was cleared or was already empty, `false` if the agent was not found.
"""
function clearAgentMemory(id::String)::Bool
    # Basic input validation
    if !isa(id, AbstractString) || isempty(id)
        @warn "clearAgentMemory received invalid or empty ID." id
        return false
    end

    ag = getAgent(id) # Uses global lock internally
    ag === nothing && return false

    lock(ag.lock) do # Acquire agent-specific lock for memory modification
        # Use the interface method
        if length(ag.memory) > 0 # Check length using interface
            clear!(ag.memory) # Clear using interface
            ag.last_activity = now() # Update activity on memory clear
            @info "Cleared memory for agent $(ag.name) ($id)"
            # Persistence._save_state() # Save after significant change
        end
        return true
    end # Release agent-specific lock
end

# ----------------------------------------------------------------------
# DEFAULT ABILITIES
# ----------------------------------------------------------------------
# Define default abilities here. These should be registered in __init__.

"""
    ping_ability(agent::Agent, task::Dict)

A simple ability that responds with "pong".
"""
function ping_ability(ag::Agent, task::Dict)
    # Ability functions receive the agent and task dictionary.
    # If they modify agent state, they should acquire ag.lock.
    # This ping ability doesn't modify state, so no lock needed here.
    @info "'ping' received by agent $(ag.name) ($(ag.id))"
    # No need to update last_activity here, executeAgentTask already does it for direct execution.
    return Dict("msg"=>"pong", "agent_id"=>ag.id, "agent_name"=>ag.name)
end

"""
    llm_chat_ability(agent::Agent, task::Dict)

An ability that sends a prompt to the configured LLM provider.
Requires LLMIntegration module (or a pluggable LLM implementation).
"""
function llm_chat_ability(ag::Agent, task::Dict)
    # This ability function needs access to the agent's config, which is immutable.
    # It doesn't modify agent state directly, so no ag.lock acquisition needed here.
    prompt = get(task, "prompt", "Hi!")
    # Basic validation for prompt
    if !isa(prompt, AbstractString) || isempty(prompt)
         @warn "llm_chat_ability received invalid or empty prompt for agent $(ag.id)." task
         # Return an error result
         return Dict("error" => "Invalid or empty prompt provided.")
    end

    if ag.llm_integration === nothing
         @warn "Agent $(ag.id) has no LLM integration configured."
         return Dict("error" => "LLM integration not configured for this agent.")
    end

    @info "Agent $(ag.name) ($(ag.id)) performing LLM chat with prompt: $(first(prompt, 50))..."
    # Call the chat function using the AbstractLLMIntegration interface
    answer = chat(ag.llm_integration, prompt; cfg=ag.config.llm_config) # Pass agent's LLM config
    return Dict("answer" => answer)
end

"""
    evaluate_fitness_ability(agent::Agent, task::Dict)

An ability for agents to evaluate a fitness/objective function for a given position (candidate solution).
This is intended to be called by the Swarm module for distributed optimization.

Task dictionary should contain:
- `position_data::Vector{Float64}`: The candidate solution to evaluate.
- `objective_function_name::String`: The name of the objective function (registered in Swarms.jl).
- `swarm_id::String` (optional, for context/logging)
- `task_id_original::String` (optional, for context/logging, the ID of the swarm's evaluation task)
"""
function evaluate_fitness_ability(ag::Agent, task::Dict)
    position_data = get(task, "position_data", nothing)
    obj_func_name = get(task, "objective_function_name", nothing)
    swarm_id_context = get(task, "swarm_id", "N/A")

    if isnothing(position_data) || !isa(position_data, Vector{Float64})
        @error "Agent $(ag.id) evaluate_fitness: Missing or invalid 'position_data'."
        return Dict("error" => "Missing or invalid 'position_data'", "fitness" => nothing)
    end
    if isnothing(obj_func_name) || !isa(obj_func_name, String)
        @error "Agent $(ag.id) evaluate_fitness: Missing or invalid 'objective_function_name'."
        return Dict("error" => "Missing or invalid 'objective_function_name'", "fitness" => nothing)
    end

    # Get the actual objective function. This relies on Swarms.jl having registered it.
    # This creates a dependency: Agents.jl needs to be able to call a function from Swarms.jl
    # or the objective function registry needs to be accessible globally or passed around.
    # For now, assume Swarms.get_objective_function_by_name is callable.
    # This might require `using ..Swarms` or `import ..Swarms: get_objective_function_by_name`
    # at the top of Agents.jl, or making the registry globally accessible.
    # Let's assume `Swarm.get_objective_function_by_name` is available via the `import .Swarm`
    
    # Ensure Swarm module and its function are accessible
    obj_fn = Swarm.get_objective_function_by_name(obj_func_name) # Using Swarm.
    if obj_fn === nothing || !isa(obj_fn, Function) # Check if it's a real function
        @error "Agent $(ag.id) evaluate_fitness: Objective function '$obj_func_name' not found or not a function."
        return Dict("error" => "Objective function '$obj_func_name' not found.", "fitness" => nothing)
    end

    @debug "Agent $(ag.id) evaluating fitness for swarm $swarm_id_context, objective '$obj_func_name'."
    try
        fitness_value = obj_fn(position_data)
        # No need to update last_activity here, executeAgentTask handles it.
        return Dict("fitness" => fitness_value, "position_evaluated" => position_data)
    catch e
        @error "Agent $(ag.id) error during fitness evaluation for objective '$obj_func_name'" exception=(e, catch_backtrace())
        return Dict("error" => "Error during fitness evaluation: $(string(e))", "fitness" => nothing)
    end
end


# ----------------------------------------------------------------------
# Module Initialization
# ----------------------------------------------------------------------
function __init__()
    # Configuration is loaded by Config.__init__ (implicitly when Config module is loaded)

    # Load state from persistence
    # Persistence.__init__ handles loading state and starting the persistence task

    # Initialize metrics for any agents loaded from state (handled in Persistence._load_state)
    # Start the agent monitor if enabled (AgentMonitor.__init__ handles starting its task)

    # Register default abilities and skills
    register_ability("ping", ping_ability)
    register_ability("llm_chat", llm_chat_ability)
    register_ability("evaluate_fitness", evaluate_fitness_ability) # Register the new ability

    # Register other default skills if any (e.g., periodic cleanup)
    # register_skill("periodic_cleanup", periodic_cleanup_skill; schedule=Schedule(:periodic, 3600)) # Example periodic skill

    @info "Agents.jl core module initialized."
end


# ----------------------------------------------------------------------
# EVENT TRIGGERING (NEW)
# ----------------------------------------------------------------------
"""
    trigger_agent_event(agent_id::String, event_name::String, event_data::Dict=Dict())

Triggers event-based skills for a specific agent.

# Arguments
- `agent_id::String`: The ID of the agent to trigger the event for.
- `event_name::String`: The name of the event.
- `event_data::Dict`: Optional data associated with the event, passed to the skill function.

# Returns
- `Vector{Dict}`: A list of results from executed skills, or an error dict if agent not found.
                  Each skill result dict contains `skill_name` and `result` or `error`.
"""
function trigger_agent_event(agent_id::String, event_name::String, event_data::Dict=Dict())
    ag = getAgent(agent_id)
    if isnothing(ag)
        @warn "trigger_agent_event: Agent $agent_id not found."
        return [Dict("error" => "Agent $agent_id not found")]
    end

    # Check if agent is in a runnable state (e.g., RUNNING)
    # Event-driven skills might still be processed if PAUSED, depending on design.
    # For now, let's allow triggering even if PAUSED, as the skill execution itself
    # might be quick or the event important. If agent is STOPPED or ERROR, skip.
    if ag.status == STOPPED || ag.status == ERROR
        @warn "trigger_agent_event: Agent $agent_id is in status $(ag.status). Event '$event_name' not processed."
        return [Dict("error" => "Agent $agent_id is in status $(ag.status), event '$event_name' not processed.")]
    end

    results = []
    executed_skills_for_event = 0

    lock(ag.lock) do # Ensure thread-safe access to agent's skills and state
        current_time = now()
        for (skill_name, sstate) in ag.skills
            sk = sstate.skill
            if sk.schedule !== nothing && sk.schedule.type == :event && sk.schedule.value == event_name
                @info "Agent $(ag.id): Triggering event skill '$(sk.name)' for event '$event_name'."
                skill_result = Dict("skill_name" => sk.name)
                try
                    # Event-driven skills receive the agent and event_data
                    # The skill function `sk.fn` should be defined as `fn(agent::Agent, event_payload::Dict)`
                    output = sk.fn(ag, event_data) 
                    skill_result["result"] = output
                    sstate.xp += 0.5 # Smaller XP gain for event-driven, or make configurable
                    sstate.last_exec = current_time
                    ag.last_activity = current_time
                    AgentMetrics.record_metric(ag.id, "skills_executed_event", 1; type=AgentMetrics.COUNTER, tags=Dict("skill_name" => sk.name, "event_name" => event_name))
                    executed_skills_for_event += 1
                catch e
                    @error "Error executing event skill '$(sk.name)' for agent $(ag.id) on event '$event_name'" exception=(e, catch_backtrace())
                    skill_result["error"] = string(e)
                    sstate.xp -= 1 
                    AgentMetrics.record_metric(ag.id, "skill_errors_event", 1; type=AgentMetrics.COUNTER, tags=Dict("skill_name" => sk.name, "event_name" => event_name))
                    # Optionally, set agent to ERROR state if event skill fails critically
                    # ag.status = ERROR; ag.last_error = e; ag.last_error_timestamp = now();
                end
                push!(results, skill_result)
            end
        end
    end # Release agent lock

    if executed_skills_for_event == 0
        @debug "Agent $(ag.id): No skills registered for event '$event_name'."
        # Return an empty list or a message indicating no skills were triggered
        # For consistency, if agent was found but no skills, return empty list of results.
    end
    
    return results
end

# --- Auto-restart logic (called from _agent_loop's finally block) ---
function _handle_auto_restart(ag::Agent)
    # This function is called from the finally block of _agent_loop.
    # The AGENTS_LOCK is NOT held here, but the agent's specific lock (ag.lock) might be,
    # or might have been released if the loop exited cleanly.
    # We need to re-acquire ag.lock to safely check and modify its status for restart.

    should_attempt_restart = false
    lock(ag.lock) do # Safely read status
        if AUTO_RESTART[] && ag.status == ERROR
            should_attempt_restart = true
        end
    end

    if should_attempt_restart
        @warn "Agent $(ag.name) ($(ag.id)) ended in ERROR state. Attempting auto-restart as per configuration (AUTO_RESTART = $(AUTO_RESTART[]))."
        
        # Add a small delay before restarting
        sleep(get_config("agent.auto_restart_delay_seconds", 5)) # New config or hardcode

        # Reset error state and attempt to restart
        # The startAgent function handles its own locking and sets status to INITIALIZING/RUNNING.
        # It also prevents starting if already in ERROR state, so we must clear the error first.
        lock(ag.lock) do
            ag.last_error = nothing
            ag.last_error_timestamp = nothing
            # We don't change ag.status here; startAgent will handle it.
            # If startAgent fails, the agent might re-enter ERROR state.
            # A more robust system would have max restart attempts.
        end
        
        # Run startAgent asynchronously to avoid blocking the finally block of the original task,
        # especially if startAgent itself involves waiting or complex operations.
        @async begin
            try
                success = startAgent(ag.id) # startAgent handles its own locking
                if success
                    @info "Agent $(ag.name) ($(ag.id)) auto-restarted successfully."
                else
                    @error "Agent $(ag.name) ($(ag.id)) auto-restart attempt failed. Agent may remain in ERROR or STOPPED state."
                    # If startAgent fails, it might set status to ERROR again.
                    # The agent's loop will not run again unless startAgent succeeds.
                    # We might need to log this failure more persistently or alert.
                end
            catch restart_ex
                @error "Exception during asynchronous auto-restart attempt for agent $(ag.name) ($ag.id)" exception=(restart_ex, catch_backtrace())
                # Ensure agent status reflects this new error if restart itself fails badly
                lock(ag.lock) do
                    ag.status = ERROR
                    ag.last_error = restart_ex
                    ag.last_error_timestamp = now()
                end
                # Persist this critical failure state
                lock(AGENTS_LOCK) do
                    Persistence._save_state()
                end
            end
        end
    end
end
# --- End auto-restart logic ---

# ----------------------------------------------------------------------
# AGENT FITNESS EVALUATION (NEW - for Swarm integration)
# ----------------------------------------------------------------------
"""
    evaluateAgentFitness(agent_id::String, objective_function_id::String, candidate_solution::Any, problem_context::Dict{String,Any})::Dict{String, Any}

Allows an agent to evaluate the fitness of a given candidate solution using a specified objective function.
This is intended to be called by a Swarm Manager or other coordinating entity.

# Arguments
- `agent_id::String`: The ID of the agent to perform the evaluation.
- `objective_function_id::String`: Identifier for the objective function (must be registered, e.g., in Swarm module).
- `candidate_solution::Any`: The solution to evaluate (e.g., `Vector{Float64}`). Type checking/conversion might be needed.
- `problem_context::Dict{String,Any}`: Additional context required by the objective function.

# Returns
- `Dict` with `success::Bool` and `fitness_value::Float64` or `error::String`.
"""
function evaluateAgentFitness(agent_id::String, objective_function_id::String, candidate_solution::Any, problem_context::Dict{String,Any})::Dict{String, Any}
    ag = getAgent(agent_id)
    if isnothing(ag)
        return Dict("success" => false, "error" => "Agent $agent_id not found")
    end

    # Lock the agent to check status and prevent interference if it were to run other tasks concurrently (though this is direct call)
    lock(ag.lock) do
        # Agent should ideally be RUNNING or IDLE (if IDLE is a state where it can accept direct work)
        # For now, let's assume RUNNING is the primary state for such direct evaluations.
        # If an agent is PAUSED, it shouldn't actively compute. If STOPPED or ERROR, it definitely can't.
        if ag.status != RUNNING
            return Dict("success" => false, "error" => "Agent $agent_id is not in RUNNING state (current: $(ag.status)). Cannot evaluate fitness.")
        end

        # Retrieve the objective function (e.g., from Swarm module's registry)
        # This relies on Swarm.jl providing such a function.
        obj_fn = Swarm.get_objective_function_by_name(objective_function_id)
        if obj_fn === nothing || !isa(obj_fn, Function)
            return Dict("success" => false, "error" => "Objective function '$objective_function_id' not found or is not a callable function.")
        end

        @debug "Agent $(ag.id) evaluating fitness for objective '$objective_function_id'."
        try
            # Type assertion/conversion for candidate_solution might be needed here
            # For now, assume obj_fn can handle `candidate_solution::Any` or it's already correct type.
            # Objective functions might also need the problem_context.
            # The signature of registered objective functions should be `fn(solution, context)`
            # or simply `fn(solution)` if context is not always needed or handled differently.
            # Let's assume for now that objective functions registered via Swarm.get_objective_function_by_name
            # expect `fn(solution_vector)` and potentially use `problem_context` if passed.
            # A more robust system would have a clear contract for objective function signatures.

            # Example: If objective functions always expect Vector{Float64} and a context Dict:
            # if !isa(candidate_solution, Vector{Float64})
            #     return Dict("success" => false, "error" => "Invalid candidate_solution format. Expected Vector{Float64}.")
            # end
            # fitness_value = obj_fn(candidate_solution, problem_context)

            # Simpler: assume obj_fn takes the candidate_solution directly.
            # If it needs context, it must be designed to fetch it or be partially applied with it.
            # The current SwarmBase.OptimizationProblem's obj_func takes only the solution vector.
            # So, we should adhere to that for functions retrieved via Swarm module.
            if !isa(candidate_solution, Vector{Float64}) && !isa(candidate_solution, Vector{<:Number}) # Allow Vector of any Number subtype
                 @warn "Candidate solution for '$objective_function_id' is not Vector{<:Number}. Type: $(typeof(candidate_solution)). Attempting conversion or direct pass."
                 # Attempt conversion if it's a generic vector of numbers
                 try
                     candidate_solution = convert(Vector{Float64}, candidate_solution)
                 catch conv_err
                     return Dict("success" => false, "error" => "Invalid candidate_solution format. Expected Vector{<:Number}. Conversion failed: $conv_err")
                 end
            end

            fitness_value = obj_fn(candidate_solution) # Pass only solution as per current Swarm obj_fn signature

            ag.last_activity = now() # Mark activity
            AgentMetrics.record_metric(ag.id, "fitness_evaluations", 1; type=AgentMetrics.COUNTER, tags=Dict("objective_function" => objective_function_id))
            
            return Dict("success" => true, "fitness_value" => fitness_value)
        catch e
            @error "Agent $(ag.id) error during fitness evaluation for objective '$objective_function_id'" exception=(e, catch_backtrace())
            AgentMetrics.record_metric(ag.id, "fitness_evaluation_errors", 1; type=AgentMetrics.COUNTER, tags=Dict("objective_function" => objective_function_id))
            return Dict("success" => false, "error" => "Error during fitness evaluation: $(string(e))")
        end
    end # Release agent lock
end


end # module Agents
