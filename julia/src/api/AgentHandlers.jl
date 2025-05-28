# backend-julia/src/api/AgentHandlers.jl
module AgentHandlers

using HTTP
using ..Utils # Updated from ApiUtils to Utils, assuming Utils.jl is in the same api/ directory

# Import from the 'agents' subdirectory
import ..agents.Agents
import ..agents.Agents: AgentConfig, AgentType, TaskStatus # Specific types

# --- Agent CRUD Handlers ---

function create_agent_handler(req::HTTP.Request)
    body = Utils.parse_request_body(req) # Use Utils
    if isnothing(body)
        return Utils.error_response("Invalid or empty request body", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT) # Use Utils
    end

    try
        name = get(body, "name", "")
        type_str = get(body, "type", "CUSTOM") # Default to CUSTOM if not provided
        abilities = get(body, "abilities", String[])
        chains = get(body, "chains", String[])
        parameters = get(body, "parameters", Dict{String,Any}())
        llm_config = get(body, "llm_config", Dict{String,Any}()) # Default empty dict if not provided
        memory_config = get(body, "memory_config", Dict{String,Any}()) # Default empty dict
        queue_config = get(body, "queue_config", Dict{String,Any}()) # Default empty dict
        # Access MAX_TASK_HISTORY via the imported Agents module
        max_task_history = get(body, "max_task_history", agents.Agents.MAX_TASK_HISTORY)


        if isempty(name)
            return Utils.error_response("Agent name cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"name"))
        end

        agent_type_val = try
            # Access AgentType via the imported Agents module
            agents.Agents.AgentType(Symbol(uppercase(type_str))) # Convert string to Symbol then to Enum
        catch
            return Utils.error_response("Invalid agent type: $type_str. Must be one of $(instances(agents.Agents.AgentType))", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"type", "value_provided"=>type_str))
        end

        # Access AgentConfig via the imported Agents module
        cfg = agents.Agents.AgentConfig(name, agent_type_val; # agent_type_val is already an Enum
                          abilities=abilities, chains=chains, parameters=parameters,
                          llm_config=llm_config, memory_config=memory_config,
                          queue_config=queue_config, max_task_history=max_task_history)

        new_agent = agents.Agents.createAgent(cfg)
        return Utils.json_response(Dict("id" => new_agent.id, "name" => new_agent.name, "status" => string(new_agent.status)), 201)
    catch e
        @error "Error in create_agent_handler" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to create agent: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function list_agents_handler(req::HTTP.Request)
    query_params = HTTP.queryparams(HTTP.URI(req.target))
    filter_type_str = get(query_params, "type", nothing)
    filter_status_str = get(query_params, "status", nothing)

    filter_type = nothing
    if !isnothing(filter_type_str)
        try
            filter_type = agents.Agents.AgentType(Symbol(uppercase(filter_type_str)))
        catch
            return Utils.error_response("Invalid filter_type: $filter_type_str. Must be one of $(instances(agents.Agents.AgentType))", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"type", "value_provided"=>filter_type_str))
        end
    end

    filter_status = nothing
    if !isnothing(filter_status_str)
        try
            filter_status = agents.Agents.AgentStatus(Symbol(uppercase(filter_status_str)))
        catch
            return Utils.error_response("Invalid filter_status: $filter_status_str. Must be one of $(instances(agents.Agents.AgentStatus))", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"status", "value_provided"=>filter_status_str))
        end
    end

    try
        agents_list = agents.Agents.listAgents(filter_type=filter_type, filter_status=filter_status)
        result = [Dict("id"=>a.id, "name"=>a.name, "type"=>string(a.type), "status"=>string(a.status)) for a in agents_list]
        return Utils.json_response(result)
    catch e
        @error "Error in list_agents_handler" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to list agents: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_agent_status_handler(req::HTTP.Request, agent_id::String)
    if isempty(agent_id)
        return Utils.error_response("Agent ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id"))
    end
    try
        status_info = agents.Agents.getAgentStatus(agent_id)
        if get(status_info, "status", "") == "not_found" || get(status_info,"error", "") == "Invalid agent ID" # getAgentStatus returns this structure
            return Utils.error_response("Agent not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("agent_id" => agent_id))
        end
        return Utils.json_response(status_info)
    catch e # Catch other unexpected errors from getAgentStatus
        @error "Error in get_agent_status_handler for agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get agent status: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function update_agent_handler(req::HTTP.Request, agent_id::String)
    if isempty(agent_id)
        return Utils.error_response("Agent ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id"))
    end
    body = Utils.parse_request_body(req)
    if isnothing(body)
        return Utils.error_response("Invalid or empty request body for update", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        updated_agent = agents.Agents.updateAgent(agent_id, body)
        if isnothing(updated_agent) # updateAgent returns nothing if agent not found or if payload was invalid for update
            # Check if agent exists to differentiate between not found and bad payload
            if isnothing(agents.Agents.getAgent(agent_id))
                return Utils.error_response("Agent not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("agent_id" => agent_id))
            else
                 return Utils.error_response("Update failed. Agent found but payload might be invalid or no changes made.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("agent_id" => agent_id, "payload"=>body))
            end
        end
        return Utils.json_response(agents.Agents.getAgentStatus(agent_id)) # Return full status after update
    catch e
        @error "Error in update_agent_handler for agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to update agent: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function delete_agent_handler(req::HTTP.Request, agent_id::String)
    if isempty(agent_id)
        return Utils.error_response("Agent ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id"))
    end
    try
        deleted = agents.Agents.deleteAgent(agent_id)
        if deleted
            return Utils.json_response(Dict("message" => "Agent deleted successfully", "agent_id" => agent_id), 200)
        else
            # deleteAgent returns false if agent not found
            return Utils.error_response("Agent not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("agent_id" => agent_id))
        end
    catch e
        @error "Error in delete_agent_handler for agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to delete agent: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function clone_agent_handler(req::HTTP.Request, agent_id::String)
    if isempty(agent_id)
        return Utils.error_response("Source Agent ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id"))
    end
    body = Utils.parse_request_body(req)
    if isnothing(body) || !haskey(body, "new_name") || !isa(body["new_name"], String) || isempty(body["new_name"])
        return Utils.error_response("Request body must include a non-empty 'new_name'", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"new_name"))
    end
    new_name = body["new_name"]
    parameter_overrides = get(body, "parameter_overrides", Dict{String,Any}())

    try
        cloned_agent = agents.Agents.cloneAgent(agent_id, new_name, parameter_overrides=parameter_overrides)
        if isnothing(cloned_agent) # cloneAgent returns nothing if source agent not found or other error
            # Check if source agent exists
            if isnothing(agents.Agents.getAgent(agent_id))
                return Utils.error_response("Source agent not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("source_agent_id" => agent_id))
            else
                return Utils.error_response("Failed to clone agent. An error occurred during cloning.", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR, details=Dict("source_agent_id" => agent_id))
            end
        end
        return Utils.json_response(Dict("id" => cloned_agent.id, "name" => cloned_agent.name, "status" => string(cloned_agent.status)), 201)
    catch e
        @error "Error in clone_agent_handler for source agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to clone agent: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function bulk_delete_agents_handler(req::HTTP.Request)
    body = Utils.parse_request_body(req)
    if isnothing(body) || !haskey(body, "agent_ids") || !(body["agent_ids"] isa AbstractVector)
        return Utils.error_response("Request body must include a list of 'agent_ids'", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_ids"))
    end

    agent_ids_to_delete = body["agent_ids"]
    if isempty(agent_ids_to_delete)
        return Utils.error_response("'agent_ids' list cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_ids"))
    end

    results = []
    all_successful = true

    for agent_id in agent_ids_to_delete
        if !isa(agent_id, String) || isempty(agent_id)
            push!(results, Dict("agent_id" => agent_id, "success" => false, "error" => "Invalid agent ID format"))
            all_successful = false
            continue
        end
        try
            deleted = agents.Agents.deleteAgent(agent_id)
            if deleted
                push!(results, Dict("agent_id" => agent_id, "success" => true, "message" => "Agent deleted successfully"))
            else
                push!(results, Dict("agent_id" => agent_id, "success" => false, "error" => "Agent not found or deletion failed"))
                all_successful = false
            end
        catch e
            @error "Error deleting agent $agent_id in bulk operation" exception=(e, catch_backtrace())
            push!(results, Dict("agent_id" => agent_id, "success" => false, "error" => "Server error during deletion: $(sprint(showerror, e))"))
            all_successful = false
        end
    end

    if all_successful
        return Utils.json_response(Dict("message" => "All specified agents deleted successfully.", "results" => results), 200)
    else
        # HTTP 207 Multi-Status might be more appropriate if some succeed and some fail.
        # For simplicity, returning 200 if the operation itself completed, with detailed results.
        # Or 400 if the overall request was problematic (e.g. bad input format, though handled above).
        return Utils.json_response(Dict("message" => "Bulk delete operation completed with some failures.", "results" => results), 207) # 207 Multi-Status
    end
end


# --- Agent Lifecycle Handlers ---

function agent_lifecycle_handler(agent_id::String, action_func::Function, action_name::String)
    if isempty(agent_id)
        return Utils.error_response("Agent ID cannot be empty for $action_name", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id", "action"=>action_name))
    end
    try
        # Check if agent exists before attempting action
        current_agent_check = agents.Agents.getAgent(agent_id)
        if isnothing(current_agent_check)
            return Utils.error_response("Agent not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("agent_id" => agent_id, "action" => action_name))
        end

        success = action_func(agent_id) # Calls functions like Agents.startAgent
        
        # Re-fetch agent to get the most up-to-date status after the action
        current_agent = agents.Agents.getAgent(agent_id) 
        # This should ideally not be nothing if the check above passed and action didn't delete it (which lifecycle actions don't)
        current_status_str = isnothing(current_agent) ? "unknown_after_action" : string(current_agent.status)

        if success
            return Utils.json_response(Dict("message" => "Agent $action_name action successful", "agent_id" => agent_id, "new_status" => current_status_str))
        else
            # If action_func returns false, it implies a pre-condition was not met (e.g., agent not in correct state)
            # The underlying Agents.jl functions usually log warnings for these cases.
            return Utils.error_response("Agent $action_name action failed. Agent might not be in a state to perform this action. Current status: $current_status_str", 409, error_code="AGENT_ACTION_FAILED", details=Dict("agent_id" => agent_id, "action" => action_name, "current_status" => current_status_str)) # 409 Conflict for state issues
        end
    catch e
        @error "Error in $action_name handler for agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to $action_name agent: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

start_agent_handler(req::HTTP.Request, agent_id::String) = agent_lifecycle_handler(agent_id, agents.Agents.startAgent, "start")
stop_agent_handler(req::HTTP.Request, agent_id::String) = agent_lifecycle_handler(agent_id, agents.Agents.stopAgent, "stop")
pause_agent_handler(req::HTTP.Request, agent_id::String) = agent_lifecycle_handler(agent_id, agents.Agents.pauseAgent, "pause")
resume_agent_handler(req::HTTP.Request, agent_id::String) = agent_lifecycle_handler(agent_id, agents.Agents.resumeAgent, "resume")

# --- Agent Task Handlers ---

function execute_agent_task_handler(req::HTTP.Request, agent_id::String)
    if isempty(agent_id)
        return Utils.error_response("Agent ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id"))
    end
    task_payload = Utils.parse_request_body(req)
    if isnothing(task_payload) || !isa(task_payload, Dict)
        return Utils.error_response("Invalid or empty task payload. Must be a JSON object.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    if !haskey(task_payload, "ability") || !isa(task_payload["ability"], String) || isempty(task_payload["ability"])
        return Utils.error_response("Task payload must include a non-empty 'ability' string.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("missing_field"=>"ability"))
    end

    try
        result = agents.Agents.executeAgentTask(agent_id, task_payload)
        # executeAgentTask returns a Dict with "success", "error", "agent_id", "task_id"
        if get(result, "success", false)
            status_code = get(result, "queued", false) ? 202 : 200 # 202 Accepted if queued, 200 OK if direct
            return Utils.json_response(result, status_code)
        else
            err_msg = get(result, "error", "Task execution failed")
            details = Dict("agent_id"=>agent_id, "task_payload"=>task_payload, "raw_result"=>result)
            if occursin("Agent $agent_id not found", err_msg)
                return Utils.error_response(err_msg, 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=details)
            elseif occursin("not RUNNING or PAUSED", err_msg)
                return Utils.error_response(err_msg, 409, error_code="AGENT_NOT_READY", details=details) # 409 Conflict
            elseif occursin("Unknown ability", err_msg)
                return Utils.error_response(err_msg, 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=details)
            else # Other errors from executeAgentTask
                return Utils.error_response(err_msg, 400, error_code="TASK_EXECUTION_FAILED", details=details)
            end
        end
    catch e # Catch unexpected errors from the handler/Agents.jl call itself
        @error "Error in execute_agent_task_handler for agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to execute agent task: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function list_agent_tasks_handler(req::HTTP.Request, agent_id::String)
    if isempty(agent_id)
        return Utils.error_response("Agent ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id"))
    end
    query_params = HTTP.queryparams(HTTP.URI(req.target))
    status_filter_str = get(query_params, "status_filter", nothing)
    limit_str = get(query_params, "limit", "100")

    status_filter = nothing
    if !isnothing(status_filter_str)
        try
            status_filter = agents.Agents.TaskStatus(Symbol(uppercase(status_filter_str)))
        catch
            return Utils.error_response("Invalid status_filter: $status_filter_str. Must be one of $(instances(agents.Agents.TaskStatus))", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"status_filter", "value_provided"=>status_filter_str))
        end
    end
    limit = try parse(Int, limit_str) catch; 100 end
    if limit < 1 || limit > 1000 # Add reasonable bounds for limit
        return Utils.error_response("Limit parameter must be between 1 and 1000.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"limit", "value_provided"=>limit_str))
    end

    try
        result = agents.Agents.listAgentTasks(agent_id, status_filter=status_filter, limit=limit)
        # listAgentTasks returns a dict with "success", "error" keys or "tasks"
        if !get(result, "success", false) # Check if the underlying call failed (e.g. agent not found)
            err_msg = get(result, "error", "Failed to list tasks")
            details = Dict("agent_id"=>agent_id, "status_filter"=>status_filter_str, "limit"=>limit)
            if occursin("Agent $agent_id not found", err_msg) # Specific check based on Agents.jl implementation
                return Utils.error_response(err_msg, 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=details)
            else
                return Utils.error_response(err_msg, 500, error_code=Utils.ERROR_CODE_SERVER_ERROR, details=details) # Or 400 if it's a known bad input to listAgentTasks
            end
        end
        return Utils.json_response(result) # Already contains success and data
    catch e
        @error "Error in list_agent_tasks_handler for agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to list agent tasks: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_task_status_handler(req::HTTP.Request, agent_id::String, task_id::String)
    if isempty(agent_id) || isempty(task_id)
        return Utils.error_response("Agent ID and Task ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["agent_id", "task_id"]))
    end
    try
        result = agents.Agents.getTaskStatus(agent_id, task_id)
        # getTaskStatus returns a dict with "status" and "error" if not found
        if get(result, "status", "") == "error" 
            err_msg = get(result, "error", "Failed to get task status")
            details = Dict("agent_id"=>agent_id, "task_id"=>task_id)
            if occursin("Agent $agent_id not found", err_msg)
                return Utils.error_response(err_msg, 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=details)
            elseif occursin("Task $task_id not found", err_msg) # Specific check based on Agents.jl
                return Utils.error_response(err_msg, 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=details)
            else
                return Utils.error_response(err_msg, 500, error_code=Utils.ERROR_CODE_SERVER_ERROR, details=details) # Or 400
            end
        end
        return Utils.json_response(result)
    catch e
        @error "Error in get_task_status_handler for agent $agent_id, task $task_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get task status: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_task_result_handler(req::HTTP.Request, agent_id::String, task_id::String)
     if isempty(agent_id) || isempty(task_id)
        return Utils.error_response("Agent ID and Task ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["agent_id", "task_id"]))
    end
    try
        result = agents.Agents.getTaskResult(agent_id, task_id)
        if get(result, "status", "") == "error"
            err_msg = get(result, "error", "Failed to get task result")
            details = Dict("agent_id"=>agent_id, "task_id"=>task_id)
            if occursin("Agent $agent_id not found", err_msg)
                return Utils.error_response(err_msg, 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=details)
            elseif occursin("Task $task_id not found", err_msg)
                return Utils.error_response(err_msg, 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=details)
            else
                return Utils.error_response(err_msg, 500, error_code=Utils.ERROR_CODE_SERVER_ERROR, details=details) # Or 400
            end
        end
        return Utils.json_response(result)
    catch e
        @error "Error in get_task_result_handler for agent $agent_id, task $task_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get task result: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function cancel_task_handler(req::HTTP.Request, agent_id::String, task_id::String)
    if isempty(agent_id) || isempty(task_id)
        return Utils.error_response("Agent ID and Task ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["agent_id", "task_id"]))
    end
    try
        result = agents.Agents.cancelTask(agent_id, task_id)
        if !get(result, "success", false)
            err_msg = get(result, "error", "Failed to cancel task")
            details = Dict("agent_id"=>agent_id, "task_id"=>task_id, "raw_result"=>result)
            if occursin("Agent $agent_id not found", err_msg)
                return Utils.error_response(err_msg, 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=details)
            elseif occursin("Task $task_id not found", err_msg)
                return Utils.error_response(err_msg, 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=details)
            elseif occursin("not pending or running", err_msg) # Task in a state that cannot be cancelled
                return Utils.error_response(err_msg, 409, error_code="TASK_NOT_CANCELLABLE", details=details) # 409 Conflict
            else
                return Utils.error_response(err_msg, 400, error_code="TASK_CANCELLATION_FAILED", details=details)
            end
        end
        return Utils.json_response(result) # Contains success:true and message
    catch e
        @error "Error in cancel_task_handler for agent $agent_id, task $task_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to cancel task: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

# --- Agent Memory Handlers ---

function get_agent_memory_handler(req::HTTP.Request, agent_id::String, key::String)
    if isempty(agent_id) || isempty(key)
        return Utils.error_response("Agent ID and memory key cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["agent_id", "key"]))
    end
    try
        # First check if agent exists
        if isnothing(agents.Agents.getAgent(agent_id))
             return Utils.error_response("Agent not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("agent_id" => agent_id))
        end
        value = agents.Agents.getAgentMemory(agent_id, key)
        if isnothing(value) # Agent found, but key not found in memory
            # It's debatable if this is a 404 for the key or a 200 with null value.
            # For an API, 404 for a specific sub-resource (the key) is common.
            return Utils.error_response("Memory key not found for agent", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("agent_id" => agent_id, "key" => key))
        end
        return Utils.json_response(Dict("key" => key, "value" => value))
    catch e
        @error "Error in get_agent_memory_handler for agent $agent_id, key $key" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get agent memory: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function set_agent_memory_handler(req::HTTP.Request, agent_id::String, key::String)
    if isempty(agent_id) || isempty(key)
        return Utils.error_response("Agent ID and memory key cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["agent_id", "key"]))
    end
    body = Utils.parse_request_body(req)
    if isnothing(body) || !haskey(body, "value") # Value can be null, but key "value" must exist
        return Utils.error_response("Request body must include a 'value' field", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("missing_field"=>"value"))
    end
    value_to_set = body["value"]

    try
        # Check if agent exists before trying to set memory
        if isnothing(agents.Agents.getAgent(agent_id))
            return Utils.error_response("Agent not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("agent_id" => agent_id))
        end
        
        success = agents.Agents.setAgentMemory(agent_id, key, value_to_set)
        # setAgentMemory in Agents.jl returns true if agent found, false otherwise.
        # Since we checked agent existence above, success should be true here.
        # If it were to return false, it would imply an issue within setAgentMemory itself after agent was confirmed.
        if success
            return Utils.json_response(Dict("message" => "Memory value set successfully", "agent_id" => agent_id, "key" => key))
        else
            # This case should ideally not be reached if agent existence is pre-checked.
            # If it is, it implies an unexpected failure in setAgentMemory.
            return Utils.error_response("Failed to set memory for agent (unexpected internal error)", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR, details=Dict("agent_id" => agent_id, "key" => key))
        end
    catch e
        @error "Error in set_agent_memory_handler for agent $agent_id, key $key" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to set agent memory: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function clear_agent_memory_handler(req::HTTP.Request, agent_id::String)
    if isempty(agent_id)
        return Utils.error_response("Agent ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id"))
    end
    try
        # Check if agent exists
        if isnothing(agents.Agents.getAgent(agent_id))
            return Utils.error_response("Agent not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("agent_id" => agent_id))
        end

        success = agents.Agents.clearAgentMemory(agent_id)
        # Similar to setAgentMemory, success should be true if agent was found.
        if success
            return Utils.json_response(Dict("message" => "Agent memory cleared successfully", "agent_id" => agent_id))
        else
            return Utils.error_response("Failed to clear memory for agent (unexpected internal error)", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR, details=Dict("agent_id" => agent_id))
        end
    catch e
        @error "Error in clear_agent_memory_handler for agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to clear agent memory: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

# --- Agent Fitness Evaluation Handler ---

function evaluate_agent_fitness_handler(req::HTTP.Request, agent_id::String)
    if isempty(agent_id)
        return Utils.error_response("Agent ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id"))
    end

    payload = Utils.parse_request_body(req)
    if isnothing(payload) || !isa(payload, Dict)
        return Utils.error_response("Invalid or empty payload. Must be a JSON object.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    objective_function_id = get(payload, "objective_function_id", nothing)
    candidate_solution = get(payload, "candidate_solution", nothing)
    problem_context = get(payload, "problem_context", Dict{String,Any}()) # Default to empty if not provided

    if isnothing(objective_function_id) || !isa(objective_function_id, String) || isempty(objective_function_id)
        return Utils.error_response("Payload must include a non-empty 'objective_function_id' string.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("missing_field"=>"objective_function_id"))
    end
    if isnothing(candidate_solution) # Further type checks might be needed in Agents.jl
        return Utils.error_response("Payload must include 'candidate_solution'.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("missing_field"=>"candidate_solution"))
    end
    if !isa(problem_context, Dict)
         return Utils.error_response("'problem_context' must be a JSON object (Dict).", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"problem_context", "type_provided"=>typeof(problem_context)))
    end

    try
        # This function will be implemented in Agents.jl
        result = agents.Agents.evaluateAgentFitness(agent_id, objective_function_id, candidate_solution, problem_context)
        
        if get(result, "success", false)
            return Utils.json_response(Dict("fitness_value" => result["fitness_value"], "agent_id" => agent_id, "objective_function_id" => objective_function_id), 200)
        else
            err_msg = get(result, "error", "Fitness evaluation failed")
            details = Dict("agent_id"=>agent_id, "objective_function_id"=>objective_function_id, "raw_result"=>result)
            
            if occursin("Agent $agent_id not found", err_msg)
                return Utils.error_response(err_msg, 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=details)
            elseif occursin("not RUNNING or IDLE", err_msg) # Assuming an agent needs to be in a certain state
                return Utils.error_response(err_msg, 409, error_code="AGENT_NOT_READY", details=details)
            elseif occursin("Unknown objective function", err_msg)
                return Utils.error_response(err_msg, 400, error_code="UNKNOWN_OBJECTIVE_FUNCTION", details=details)
            elseif occursin("Invalid candidate solution format", err_msg)
                 return Utils.error_response(err_msg, 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=details)
            else
                return Utils.error_response(err_msg, 500, error_code="FITNESS_EVALUATION_FAILED", details=details)
            end
        end
    catch e
        @error "Error in evaluate_agent_fitness_handler for agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to evaluate fitness: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

end
