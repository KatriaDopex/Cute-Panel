# backend-julia/src/agents/Persistence.jl

"""
Persistence Module for Agent System

Handles saving and loading agent state to/from disk, including periodic auto-saving.
"""
module Persistence

using Dates, UUIDs, JSON3, Logging, Base.Threads
using DataStructures # For OrderedDict used in Agent memory
# using Atomic # Not directly used, mv is atomic on POSIX, consider alternatives for Windows if needed

# Import necessary types and global structures from sibling modules
import ..Config: get_config # For configuration values
import ..AgentMetrics: init_agent_metrics # To initialize metrics for loaded agents
using ..AgentCore: Agent, AgentConfig, AgentStatus, AgentType, CUSTOM,
        AbstractAgentMemory, AbstractAgentQueue, AbstractLLMIntegration,
        OrderedDictAgentMemory,
        AGENTS_LOCK, AGENTS,
        TaskResult

# Export internal functions for use by other modules (like Agents.jl or main startup)
export _save_state, _load_state, start_persistence_task, stop_persistence_task

# Configuration constants
const DEFAULT_STORE_PATH = joinpath(@__DIR__, "..", "..", "data", "agents_state.json") # Aligned with Config.jl's data/ dir
const STORE_PATH = Ref(get_config("storage.path", DEFAULT_STORE_PATH)) # Use Ref for mutable global constant
const PERSIST_INTERVAL_SECONDS = Ref(get_config("storage.persist_interval_seconds", 60))

# Periodic persistence task state
const PERSIST_TASK = Ref{Union{Task, Nothing}}(nothing)
const PERSIST_RUNNING = Ref{Bool}(false)
const PERSIST_LOCK = ReentrantLock() # Lock for PERSIST_RUNNING and PERSIST_TASK ref

"""
    _update_config_dependent_constants!()

Updates constants that depend on the loaded configuration.
Called after initial config load or if config can be reloaded.
"""
function _update_config_dependent_constants!()
    STORE_PATH[] = get_config("storage.path", DEFAULT_STORE_PATH)
    PERSIST_INTERVAL_SECONDS[] = get_config("storage.persist_interval_seconds", 60)
    # Ensure the directory for STORE_PATH[] exists
    try
        store_dir = dirname(STORE_PATH[])
        if !ispath(store_dir)
            mkpath(store_dir)
            @info "Created storage directory: $store_dir"
        end
    catch e
        @error "Failed to create storage directory: $(dirname(STORE_PATH[]))" exception=(e, catch_backtrace())
    end
end


"""
    _save_state()

Atomically saves the current state of all agents to the configured storage path.
Assumes AGENTS_LOCK is acquired by the caller before iterating AGENTS.
Acquires agent-specific locks (`a.lock`) for serializing each agent's state.
"""
function _save_state()
    # Ensure STORE_PATH directory exists, in case it was created after module load
    # This is a bit defensive, as _update_config_dependent_constants! should handle it.
    try
        store_dir = dirname(STORE_PATH[])
        ispath(store_dir) || mkpath(store_dir)
    catch e
        @error "Failed to ensure storage directory exists before saving: $(dirname(STORE_PATH[]))" exception=(e, catch_backtrace())
        return # Do not proceed if directory cannot be ensured
    end

    data_to_save = Dict{String, Dict{String, Any}}()
    
    # AGENTS_LOCK must be held by the caller (e.g., persistence task or specific lifecycle functions)
    # to safely iterate over the AGENTS dictionary.
    for (id, agent_instance) in AGENTS # Iterate over the global AGENTS store
        lock(agent_instance.lock) do # Acquire individual agent's lock for consistent state
            # Serialize TaskResults
            serialized_task_results = Dict{String, Dict{String, Any}}()
            for (task_id, tr) in agent_instance.task_results
                 serialized_task_results[task_id] = Dict(
                     "task_id" => tr.task_id,
                     "status" => Int(tr.status), # Save enum as Int
                     "submitted" => string(tr.submitted), # Use UTC if not already
                     "start_time" => isnothing(tr.start_time) ? nothing : string(tr.start_time),
                     "end_time" => isnothing(tr.end_time) ? nothing : string(tr.end_time),
                    #  "input_task" => tr.input_task,
                     "output_result" => tr.output_result, # Assumes this is JSON-serializable
                     "error_details" => isnothing(tr.error_details) ? nothing : string(tr.error_details)
                 )
            end

            # Serialize pluggable memory component's data
            serialized_memory_data = nothing
            if isa(agent_instance.memory, OrderedDictAgentMemory)
                 serialized_memory_data = Dict("type"=>"ordered_dict", "data"=>collect(agent_instance.memory.data))
            # TODO: Add serialization for other AbstractAgentMemory implementations
            # elseif isa(agent_instance.memory, SomeOtherMemoryType)
            #    serialized_memory_data = Dict("type"=>"some_other_type", "data"=>agent_instance.memory.some_internal_data)
            end

            # Note: Agent queue, LLM integration instance, and Swarm connection are typically transient
            # and not serialized. They are reconstructed/re-established on load/start.

            data_to_save[id] = Dict(
                "id" => agent_instance.id,
                "name" => agent_instance.name,
                "type" => Int(agent_instance.type),
                "status" => Int(agent_instance.status),
                "created" => string(agent_instance.created), # Use UTC if not already
                "updated" => string(agent_instance.updated), # Use UTC if not already
                "config" => agent_instance.config, # AgentConfig is a struct, JSON3 should handle it
                "memory_snapshot" => serialized_memory_data, # Store memory type and its data
                "skills_state" => Dict(k => Dict("xp"=>s.xp, "last_exec"=>string(s.last_exec)) for (k,s) in agent_instance.skills),
                "task_results_snapshot" => serialized_task_results,
                # task_history is currently not persisted (re-initialized empty on load)
                "last_error_details" => isnothing(agent_instance.last_error) ? nothing : string(agent_instance.last_error),
                "last_error_timestamp_utc" => isnothing(agent_instance.last_error_timestamp) ? nothing : string(agent_instance.last_error_timestamp),
                "last_activity_utc" => string(agent_instance.last_activity)
            )
        end # Release agent_instance.lock
    end

    temp_file_path = STORE_PATH[] * ".tmp." * string(uuid4())
    try
        open(temp_file_path, "w") do io
            JSON3.write(io, data_to_save)
        end
        mv(temp_file_path, STORE_PATH[]; force=true) # Atomic move
        @debug "Agent state successfully saved to $(STORE_PATH[])"
    catch e
        @error "Failed to save agent state to $(STORE_PATH[])" exception=(e, catch_backtrace())
        isfile(temp_file_path) && try rm(temp_file_path) catch rm_e @warn "Failed to remove temp save file $temp_file_path" exception=rm_e end
    end
end

"""
    _load_state()

Loads agent states from the configured storage path.
Assumes AGENTS_LOCK is acquired by the caller before modifying the global AGENTS store.
Initializes agent-specific locks, conditions, and reconstructs pluggable components.
"""
function _load_state()
    isfile(STORE_PATH[]) || ( @info "No agent state file found at $(STORE_PATH[]). Starting fresh."; return )
    
    raw_data_from_file = nothing
    try
        raw_data_from_file = JSON3.read(read(STORE_PATH[], String)) # Read file then parse
    catch e
        @error "Error reading or parsing agent state file $(STORE_PATH[]). Starting fresh." exception=(e, catch_backtrace())
        # Optionally, attempt to load from a backup or rename the corrupt file
        # mv(STORE_PATH[], STORE_PATH[] * ".corrupt." * string(Dates.now()), force=true)
        return
    end

    num_loaded = 0
    # AGENTS_LOCK must be held by the caller (e.g., __init__)
    empty!(AGENTS) # Clear any existing in-memory agents before loading

    for (agent_id_str, agent_obj_data) in raw_data_from_file
        try
            # Reconstruct AgentConfig
            cfg_data = get(agent_obj_data, "config", Dict())
            # Coerce the raw "type" field into an AgentType enum
            raw_type = get(cfg_data, "type", CUSTOM)
            type_enum = if raw_type isa Integer
                AgentType(raw_type)
            elseif raw_type isa AbstractString
                try
                    AgentType(Symbol(raw_type))
                catch
                    CUSTOM
                end
            else
                CUSTOM
            end
            # Provide defaults for AgentConfig fields if missing from saved data
            agent_cfg = AgentConfig(
                get(cfg_data, "name", "Loaded Agent (Name Missing)"),
                type_enum,
                # abilities = get(cfg_data, "abilities", String[]),
                # chains = get(cfg_data, "chains", String[]),
                abilities = Vector{String}(get(cfg_data, "abilities", String[])),
                chains = Vector{String}(get(cfg_data, "chains", String[])),
                parameters = Dict{String,Any}(string(k)=>v for (k,v) in get(cfg_data, "parameters", Dict{String,Any}())),
                llm_config = Dict{String,Any}(string(k)=>v for (k,v) in get(cfg_data, "llm_config", Dict{String,Any}())),
                memory_config = Dict{String,Any}(string(k)=>v for (k,v) in get(cfg_data, "memory_config", Dict{String,Any}())),
                queue_config = Dict{String,Any}(string(k)=>v for (k,v) in get(cfg_data, "queue_config", Dict{String,Any}())),
                max_task_history = get(cfg_data, "max_task_history", get_config("agent.max_task_history", 100))
            )

            # Reconstruct TaskResults
            loaded_task_results = Dict{String, TaskResult}()
            task_results_snapshot = get(agent_obj_data, "task_results_snapshot", Dict())
            if isa(task_results_snapshot, Dict)
                 for (task_id_str, tr_data) in task_results_snapshot
                     try
                        submitted_time = try DateTime(get(tr_data, "submitted_time", string(now(UTC)))) catch eDateTime @warn "Parse error for submitted_time" e=eDateTime; now(UTC) end
                        start_time = haskey(tr_data, "start_time") && !isnothing(tr_data["start_time"]) ? (try DateTime(tr_data["start_time"]) catch eDateTime @warn "Parse error for start_time" e=eDateTime; nothing end) : nothing
                        end_time = haskey(tr_data, "end_time") && !isnothing(tr_data["end_time"]) ? (try DateTime(tr_data["end_time"]) catch eDateTime @warn "Parse error for end_time" e=eDateTime; nothing end) : nothing
                        
                        loaded_task_results[task_id_str] = TaskResult(
                             get(tr_data, "task_id", task_id_str),
                             Agents.TaskStatus(Int(get(tr_data, "status", Int(Agents.TASK_UNKNOWN)))),
                             submitted_time, start_time, end_time,
                            #  get(tr_data, "input_task", Dict{String, Any}()),
                             get(tr_data, "output_result", nothing),
                             haskey(tr_data, "error_details") && !isnothing(tr_data["error_details"]) ? ErrorException(string(tr_data["error_details"])) : nothing
                         )
                     catch tr_load_err
                         @warn "Error parsing state for task result '$task_id_str' in agent $agent_id_str. Skipping task result." exception=tr_load_err
                     end
                 end
            end

            # Reconstruct pluggable components using helpers from Agents.jl
            memory_component = _create_memory_component(agent_cfg.memory_config)
            memory_snapshot = get(agent_obj_data, "memory_snapshot", nothing)
            if isa(memory_component, OrderedDictAgentMemory) && isa(memory_snapshot, Dict) && get(memory_snapshot, "type", "") == "ordered_dict"
                 saved_mem_data = get(memory_snapshot, "data", [])
                 # Ensure data is in the format expected by OrderedDict constructor (Vector of Pairs)
                 if isa(saved_mem_data, AbstractVector)
                    try
                        memory_component.data = OrderedDict{String,Any}(Pair{String,Any}[Pair(p[1], p[2]) for p in saved_mem_data if isa(p, AbstractVector) && length(p)==2])
                    catch dict_err
                        @warn "Could not reconstruct OrderedDict memory for agent $agent_id_str from saved data. Memory will be empty." exception=dict_err
                    end
                 end
            # TODO: Add deserialization for other AbstractAgentMemory implementations
            end

            queue_component = _create_queue_component(agent_cfg.queue_config) # Queue state is transient
            llm_component = _create_llm_component(agent_cfg.llm_config)       # LLM instance is transient

            # Reconstruct Agent
            created_time = try DateTime(get(agent_obj_data, "created", string(now(UTC)))) catch eDateTime @warn "Parse error for created" e=eDateTime; now(UTC) end
            updated_time = try DateTime(get(agent_obj_data, "updated", string(now(UTC)))) catch eDateTime @warn "Parse error for updated" e=eDateTime; now(UTC) end
            last_activity_time = try DateTime(get(agent_obj_data, "last_activity_utc", string(updated_time))) catch eDateTime @warn "Parse error for last_activity_utc" e=eDateTime; updated_time end
            last_error_timestamp_val = haskey(agent_obj_data, "last_error_timestamp_utc") && !isnothing(agent_obj_data["last_error_timestamp_utc"]) ? (try DateTime(agent_obj_data["last_error_timestamp_utc"]) catch eDateTime @warn "Parse error for last_error_timestamp_utc" e=eDateTime; nothing end) : nothing

            # Agent status should be STOPPED on load, to be explicitly started later.
            # Unless a specific "resume_on_load" policy is implemented.
            loaded_status = Agents.STOPPED # Default to STOPPED on load
            # original_status_from_file = AgentStatus(Int(get(agent_obj_data, "status", Int(Agents.STOPPED))))
            # if original_status_from_file == Agents.RUNNING || original_status_from_file == Agents.PAUSED
            #     # Decide policy: e.g. always load as PAUSED or STOPPED
            #     loaded_status = Agents.PAUSED # Example: load as PAUSED if was running
            # else
            #     loaded_status = original_status_from_file
            # end

            agent_instance = Agent(
                agent_id_str,
                get(agent_obj_data, "name", agent_cfg.name),
                Agents.AgentType(Int(get(agent_obj_data, "type", Int(agent_cfg.type)))),
                loaded_status, # Start as STOPPED
                created_time,
                updated_time, # This will be updated if agent is started
                agent_cfg,
                memory_component,
                Dict{String,Any}[], # Task history is not persisted in this version
                Dict{String,SkillState}(), # Initialize skills, load below
                queue_component,
                loaded_task_results,
                llm_component,
                nothing, # Swarm connection is transient
                ReentrantLock(), # New lock for the loaded agent
                Condition(),     # New condition variable
                haskey(agent_obj_data, "last_error_details") && !isnothing(agent_obj_data["last_error_details"]) ? ErrorException(string(agent_obj_data["last_error_details"])) : nothing,
                last_error_timestamp_val,
                last_activity_time
            )

            # Load skill states
            skills_state_data = get(agent_obj_data, "skills_state", Dict())
            if isa(skills_state_data, Dict)
                for (skill_name, s_data) in skills_state_data
                    registered_skill = get(SKILL_REGISTRY, skill_name, nothing)
                    if registered_skill !== nothing && isa(s_data, Dict)
                        try
                            xp = Float64(get(s_data, "xp", 0.0))
                            last_exec = try DateTime(get(s_data, "last_exec", string(Dates.epoch()))) catch eDateTime @warn "Parse error for skill last_exec" e=eDateTime; Dates.epoch() end
                            agent_instance.skills[skill_name] = SkillState(registered_skill, xp, last_exec)
                        catch skill_err
                            @warn "Error parsing state for skill '$skill_name' in agent $agent_id_str. Skill state might be lost." exception=skill_err
                        end
                    elseif isnothing(registered_skill)
                        @warn "Skill '$skill_name' from saved state for agent $agent_id_str not found in SKILL_REGISTRY. Ignoring."
                    end
                end
            end

            AGENTS[agent_id_str] = agent_instance
            num_loaded += 1
            init_agent_metrics(agent_id_str) # Initialize metrics for the loaded agent

        catch e
            @error "Critical error loading agent $agent_id_str from state file. Agent skipped." exception=(e, catch_backtrace())
        end
    end # end for loop
    @info "Loaded $num_loaded agents from $(STORE_PATH[])."
end

"""
    start_persistence_task()

Starts a background task that periodically saves the agent state if auto-persist is enabled.
"""
function start_persistence_task()::Bool
    lock(PERSIST_LOCK) do
        if PERSIST_RUNNING[]
            @info "Persistence task already running."
            return true # Already running
        end
        if !get_config("storage.auto_persist", true)
            @info "Auto-persistence is disabled by configuration."
            return false # Auto-persist disabled
        end

        # Ensure config-dependent constants are up-to-date before starting task
        _update_config_dependent_constants!()
        
        if PERSIST_INTERVAL_SECONDS[] <= 0
            @warn "Persistence interval is non-positive ($(PERSIST_INTERVAL_SECONDS[])s). Auto-persistence task will not start."
            return false
        end

        PERSIST_RUNNING[] = true
        PERSIST_TASK[] = @task begin
            @info "Agent persistence task started (interval: $(PERSIST_INTERVAL_SECONDS[])s, path: $(STORE_PATH[]))"
            try
                while true
                    sleep(PERSIST_INTERVAL_SECONDS[])

                    should_run = lock(PERSIST_LOCK) do
                        PERSIST_RUNNING[]
                    end
                    if !should_run
                        break
                    end

                    lock(AGENTS_LOCK) do
                        _save_state()
                    end
                end
            catch e
                if isa(e, InterruptException)
                    @info "Persistence task interrupted."
                else
                    @error "Agent persistence task crashed!" exception=(e, catch_backtrace())
                end
            finally
                @info "Agent persistence task stopped."
                lock(PERSIST_LOCK) do # Ensure lock for state modification
                    PERSIST_RUNNING[] = false
                    PERSIST_TASK[] = nothing
                end
            end
        end
        schedule(PERSIST_TASK[])
        return true
    end
end

"""
    stop_persistence_task()

Signals the background persistence task to stop.
"""
function stop_persistence_task()::Bool
    task_to_signal = nothing
    lock(PERSIST_LOCK) do
        if !PERSIST_RUNNING[]
            @info "Persistence task is not running."
            return true # Not running, so effectively stopped
        end
        @info "Signaling agent persistence task to stop..."
        PERSIST_RUNNING[] = false # Signal the loop to stop
        task_to_signal = PERSIST_TASK[]
    end

    # If the task exists and is not done, one might try to interrupt it
    # However, simply setting PERSIST_RUNNING[] to false is often sufficient
    # as the loop checks this flag. Interrupting can be aggressive.
    # The task will clean itself up in its finally block.
    if !isnothing(task_to_signal) && !istaskdone(task_to_signal)
        @info "Persistence task will stop after its current sleep cycle or operation."
        # For a more immediate stop, one could try:
        # schedule(task_to_signal, InterruptException(), error=true)
        # But this needs careful handling in the task's catch block.
    end
    return true
end

"""
    __init__()

Module initialization:
1. Updates configuration-dependent constants like storage path.
2. Loads agent state from disk.
3. Starts the periodic persistence task if enabled in config.
"""
function __init__()
    _update_config_dependent_constants!() # Set STORE_PATH etc. based on loaded config

    # Load agent state from disk. Requires AGENTS_LOCK.
    # TODO: uncomment line
    # lock(AGENTS_LOCK) do
    #     _load_state()
    # end

    # Start the periodic persistence task if auto-persist is enabled
    if get_config("storage.auto_persist", true)
        # Run as an async task so it doesn't block module loading further
        @async start_persistence_task()
    else
        @info "Auto-persistence task not started as per configuration."
    end
    @info "Persistence module initialized. State loaded. Auto-save task status: $(PERSIST_RUNNING[])."
end

end # module Persistence
