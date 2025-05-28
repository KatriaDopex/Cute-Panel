# julia/src/api/SwarmHandlers.jl
module SwarmHandlers

using HTTP
using ..Utils # For standardized responses
# Assuming Swarms.jl is made available via CutePanelFramework or direct using
# This might need to be `using Main.CutePanelFramework.Swarms` or similar
# depending on how CutePanelFramework exports/makes modules available.
# For now, let's assume `Swarms` and `SwarmBase` are directly accessible if `CutePanelFramework` is `using`'d.
# Corrected import path based on CutePanelFramework structure
import ..framework.CutePanelFramework.Swarms
import ..framework.CutePanelFramework.SwarmBase # For types like SwarmConfig, OptimizationProblem

function create_swarm_handler(req::HTTP.Request)
    body = Utils.parse_request_body(req)
    if isnothing(body)
        return Utils.error_response("Invalid or empty request body", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        name = get(body, "name", "")
        algo_type = get(body, "algorithm_type", "")
        algo_params = get(body, "algorithm_params", Dict{String,Any}())
        obj_desc = get(body, "objective_description", "Default Objective")
        max_iter = get(body, "max_iterations", 100)
        target_fit_val = get(body, "target_fitness", nothing) # Can be Float64 or nothing

        problem_def_data = get(body, "problem_definition", nothing)
        if isnothing(problem_def_data) || !isa(problem_def_data, Dict)
            return Utils.error_response("Missing or invalid 'problem_definition'", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"problem_definition"))
        end

        if isempty(name)
            return Utils.error_response("Swarm name cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"name"))
        end
        if isempty(algo_type)
            return Utils.error_response("Swarm 'algorithm_type' cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"algorithm_type"))
        end

        # Deserialize OptimizationProblem
        dims = get(problem_def_data, "dimensions", 0)
        bounds_data = get(problem_def_data, "bounds", [])
        is_min = get(problem_def_data, "is_minimization", true)
        
        if dims <= 0 || !isa(bounds_data, AbstractVector) || length(bounds_data) != dims
             return Utils.error_response("Invalid 'problem_definition': dimensions and bounds mismatch or missing.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"problem_definition"))
        end
        
        bounds_tuples = Vector{Tuple{Float64, Float64}}()
        for b_item in bounds_data
            if isa(b_item, AbstractVector) && length(b_item) == 2 && all(isa.(b_item, Number))
                push!(bounds_tuples, tuple(Float64(b_item[1]), Float64(b_item[2])))
            else
                return Utils.error_response("Invalid format for bounds in 'problem_definition'. Each bound must be a 2-element array of numbers.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"problem_definition.bounds"))
            end
        end

        obj_func_name = get(problem_def_data, "objective_function_name", "default_placeholder_objective")
        obj_func_name = get(problem_def_data, "objective_function_name", "default_sum_objective") # Default if not provided
        
        # Resolve the objective function using the name from the registry in Swarms.jl
        objective_function = Swarms.get_objective_function_by_name(obj_func_name)
        if objective_function == Swarms.get_objective_function_by_name("default_sum_objective") && obj_func_name != "default_sum_objective"
            # This means the requested function was not found, and it fell back to default.
            # Depending on strictness, this could be an error or a warning.
            # For now, allow fallback but it's better if API users specify valid, registered functions.
            @warn "Objective function '$obj_func_name' not found in Swarm registry, using default sum objective for swarm '$name'."
        elseif obj_func_name == "default_placeholder_objective" && objective_function == Swarms.get_objective_function_by_name("default_sum_objective")
             @warn "API create_swarm: 'objective_function_name' not provided in problem_definition, using default_sum_objective for swarm '$name'."
        end


        problem_def = SwarmBase.OptimizationProblem(dims, bounds_tuples, objective_function; is_minimization=is_min)

        config = Swarms.SwarmConfig(name, algo_type, problem_def; # Pass problem_def as positional argument
                                   algorithm_params=algo_params, 
                                   objective_desc=obj_desc, 
                                   max_iter=max_iter, 
                                   target_fit=target_fit_val)
        
        swarm = Swarms.createSwarm(config)
        status_dict = Swarms.getSwarmStatus(swarm.id) 
        return Utils.json_response(status_dict, 201)

    catch e
        if isa(e, ArgumentError) 
            @error "Error creating swarm due to invalid arguments" exception=(e, catch_backtrace())
            return Utils.error_response("Failed to create swarm: $(e.msg)", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
        else
            @error "Error in create_swarm_handler" exception=(e, catch_backtrace())
            return Utils.error_response("Failed to create swarm: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
        end
    end
end

function list_swarms_handler(req::HTTP.Request)
    query_params = HTTP.queryparams(HTTP.URI(req.target))
    filter_status_str = get(query_params, "status", nothing)
    
    filter_status_enum = nothing
    if !isnothing(filter_status_str)
        try
            # Assuming SwarmStatus enum values are like SWARM_CREATED, SWARM_RUNNING
            filter_status_enum = Swarms.SwarmStatus(Symbol(uppercase("SWARM_" * filter_status_str)))
        catch
            return Utils.error_response("Invalid status filter: $filter_status_str. Valid values are CREATED, RUNNING, STOPPED, ERROR, COMPLETED.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"status"))
        end
    end

    try
        swarms_list = Swarms.listSwarms(filter_status=filter_status_enum)
        result = [Swarms.getSwarmStatus(s.id) for s in swarms_list if !isnothing(Swarms.getSwarmStatus(s.id))]
        return Utils.json_response(result)
    catch e
        @error "Error in list_swarms_handler" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to list swarms: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_swarm_handler(req::HTTP.Request, swarm_id::String)
    if isempty(swarm_id)
        return Utils.error_response("Swarm ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"swarm_id"))
    end
    try
        status_dict = Swarms.getSwarmStatus(swarm_id)
        if isnothing(status_dict)
            return Utils.error_response("Swarm not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id))
        end
        return Utils.json_response(status_dict)
    catch e
        @error "Error in get_swarm_handler for swarm $swarm_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get swarm details for $swarm_id: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function start_swarm_handler(req::HTTP.Request, swarm_id::String)
    if isempty(swarm_id)
        return Utils.error_response("Swarm ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"swarm_id"))
    end
    try
        swarm = Swarms.getSwarm(swarm_id)
        if isnothing(swarm)
            return Utils.error_response("Swarm not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id))
        end

        success = Swarms.startSwarm(swarm_id)
        current_status_str = string(Swarms.getSwarm(swarm_id).status) # Get updated status

        if success
            return Utils.json_response(Dict("message" => "Swarm start initiated successfully.", "swarm_id" => swarm_id, "status" => current_status_str))
        else
            # startSwarm might return false if already running or in an invalid state (e.g., ERROR)
            return Utils.error_response("Failed to start swarm $swarm_id. It might be already running or in a non-startable state. Current status: $current_status_str", 409, error_code="SWARM_START_FAILED", details=Dict("swarm_id"=>swarm_id, "current_status"=>current_status_str)) # 409 Conflict
        end
    catch e
        @error "Error in start_swarm_handler for $swarm_id" exception=(e, catch_backtrace())
        return Utils.error_response("Error starting swarm $swarm_id: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function stop_swarm_handler(req::HTTP.Request, swarm_id::String)
    if isempty(swarm_id)
        return Utils.error_response("Swarm ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"swarm_id"))
    end
    try
        swarm = Swarms.getSwarm(swarm_id)
        if isnothing(swarm)
            return Utils.error_response("Swarm not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id))
        end

        success = Swarms.stopSwarm(swarm_id)
        current_status_str = string(Swarms.getSwarm(swarm_id).status)

        if success
            return Utils.json_response(Dict("message" => "Swarm stop initiated successfully.", "swarm_id" => swarm_id, "status" => current_status_str))
        else
             # stopSwarm might return false if not running or in ERROR state
            return Utils.error_response("Failed to stop swarm $swarm_id. It might not be running. Current status: $current_status_str", 409, error_code="SWARM_STOP_FAILED", details=Dict("swarm_id"=>swarm_id, "current_status"=>current_status_str))
        end
    catch e
        @error "Error in stop_swarm_handler for $swarm_id" exception=(e, catch_backtrace())
        return Utils.error_response("Error stopping swarm $swarm_id: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function add_agent_to_swarm_handler(req::HTTP.Request, swarm_id::String)
    if isempty(swarm_id)
        return Utils.error_response("Swarm ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"swarm_id"))
    end
    body = Utils.parse_request_body(req)
    if isnothing(body) || !haskey(body, "agent_id") || !isa(body["agent_id"], String) || isempty(body["agent_id"])
        return Utils.error_response("Request body must include a non-empty 'agent_id'", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"agent_id"))
    end
    agent_id = body["agent_id"]

    try
        success = Swarms.addAgentToSwarm(swarm_id, agent_id)
        if success
            swarm = Swarms.getSwarm(swarm_id) # To get updated agent count
            agent_count = isnothing(swarm) ? -1 : length(swarm.agents)
            return Utils.json_response(Dict("message" => "Agent $agent_id added to swarm $swarm_id.", "swarm_id" => swarm_id, "agent_id" => agent_id, "current_agent_count" => agent_count))
        else
            # addAgentToSwarm returns false if swarm or agent not found, or if agent already in swarm (though latter is info, not error)
            # Check specific reason
            if isnothing(Swarms.getSwarm(swarm_id))
                return Utils.error_response("Swarm $swarm_id not found.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id))
            # Corrected path to Agents.getAgent:
            # The `import ..agents.Agents` at the top makes `Agents` available directly.
            elseif isnothing(Agents.getAgent(agent_id)) 
                return Utils.error_response("Agent $agent_id not found.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("agent_id"=>agent_id))
            else # Other failure, e.g. agent already present (which addAgentToSwarm handles as success with info log)
                 return Utils.error_response("Failed to add agent $agent_id to swarm $swarm_id.", 400, error_code="AGENT_ADD_TO_SWARM_FAILED")
            end
        end
    catch e
        @error "Error in add_agent_to_swarm_handler for swarm $swarm_id, agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Error adding agent to swarm: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function remove_agent_from_swarm_handler(req::HTTP.Request, swarm_id::String, agent_id::String) # agent_id from path param
    if isempty(swarm_id) || isempty(agent_id)
        return Utils.error_response("Swarm ID and Agent ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["swarm_id", "agent_id"]))
    end
    
    try
        success = Swarms.removeAgentFromSwarm(swarm_id, agent_id)
        if success
            swarm = Swarms.getSwarm(swarm_id)
            agent_count = isnothing(swarm) ? -1 : length(swarm.agents)
            return Utils.json_response(Dict("message" => "Agent $agent_id removed from swarm $swarm_id.", "swarm_id" => swarm_id, "agent_id" => agent_id, "current_agent_count" => agent_count))
        else
            if isnothing(Swarms.getSwarm(swarm_id))
                return Utils.error_response("Swarm $swarm_id not found.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id))
            elseif !(agent_id in Swarms.getSwarm(swarm_id).agents) # Check if agent was actually in swarm
                 return Utils.error_response("Agent $agent_id not found in swarm $swarm_id.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id, "agent_id"=>agent_id))
            else
                return Utils.error_response("Failed to remove agent $agent_id from swarm $swarm_id.", 400, error_code="AGENT_REMOVE_FROM_SWARM_FAILED")
            end
        end
    catch e
        @error "Error in remove_agent_from_swarm_handler for swarm $swarm_id, agent $agent_id" exception=(e, catch_backtrace())
        return Utils.error_response("Error removing agent from swarm: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function elect_leader_handler(req::HTTP.Request, swarm_id::String)
    if isempty(swarm_id)
        return Utils.error_response("Swarm ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    # Criteria function might be passed in body, or use a default. For now, default.
    # body = Utils.parse_request_body(req) 
    # criteria_func_name = get(body, "criteria_func_name", nothing) 
    # Resolve criteria_func_name to actual function (complex, needs registry)

    try
        leader_id = Swarms.electLeader(swarm_id) # Uses default criteria for now
        if isnothing(leader_id)
            return Utils.error_response("Failed to elect leader for swarm $swarm_id (e.g., no agents).", 400, error_code="LEADER_ELECTION_FAILED")
        end
        return Utils.json_response(Dict("message"=>"Leader elected for swarm $swarm_id.", "swarm_id"=>swarm_id, "leader_id"=>leader_id))
    catch e
        @error "Error in elect_leader_handler for $swarm_id" exception=(e, catch_backtrace())
        return Utils.error_response("Error electing leader for swarm $swarm_id: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function allocate_task_handler(req::HTTP.Request, swarm_id::String)
    if isempty(swarm_id)
        return Utils.error_response("Swarm ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    body = Utils.parse_request_body(req)
    if isnothing(body) || !isa(body, Dict)
        return Utils.error_response("Request body must be a valid JSON object for task details.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    try
        task_id = Swarms.allocateTask(swarm_id, body)
        if isnothing(task_id) # Swarm not found or other issue in allocateTask
            return Utils.error_response("Failed to allocate task to swarm $swarm_id.", 400, error_code="TASK_ALLOCATION_FAILED")
        end
        return Utils.json_response(Dict("message"=>"Task allocated to swarm $swarm_id.", "swarm_id"=>swarm_id, "task_id"=>task_id), 202) # 202 Accepted
    catch e
        @error "Error in allocate_task_handler for $swarm_id" exception=(e, catch_backtrace())
        return Utils.error_response("Error allocating task to swarm $swarm_id: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function claim_task_handler(req::HTTP.Request, swarm_id::String, task_id::String)
    if isempty(swarm_id) || isempty(task_id)
        return Utils.error_response("Swarm ID and Task ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    body = Utils.parse_request_body(req)
    if isnothing(body) || !haskey(body, "agent_id") || !isa(body["agent_id"], String) || isempty(body["agent_id"])
        return Utils.error_response("Request body must include a non-empty 'agent_id'", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    agent_id = body["agent_id"]

    try
        # Swarms.claimTask returns Dict with "success" and "task" or "error"
        result = Swarms.claimTask(swarm_id, task_id, agent_id) 
        if get(result, "success", false)
            return Utils.json_response(result)
        else
            err_msg = get(result, "error", "Failed to claim task.")
            status_code = occursin("not found", err_msg) ? 404 : 400
            err_code = occursin("not found", err_msg) ? Utils.ERROR_CODE_NOT_FOUND : "TASK_CLAIM_FAILED"
            return Utils.error_response(err_msg, status_code, error_code=err_code, details=result)
        end
    catch e
        @error "Error in claim_task_handler for swarm $swarm_id, task $task_id" exception=(e, catch_backtrace())
        return Utils.error_response("Error claiming task: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function complete_task_handler(req::HTTP.Request, swarm_id::String, task_id::String)
    if isempty(swarm_id) || isempty(task_id)
        return Utils.error_response("Swarm ID and Task ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    body = Utils.parse_request_body(req)
    if isnothing(body) || !haskey(body, "agent_id") || !isa(body["agent_id"], String) || isempty(body["agent_id"]) || !haskey(body, "result")
        return Utils.error_response("Request body must include 'agent_id' and 'result'", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    agent_id = body["agent_id"]
    task_result_data = body["result"] # This can be any JSON-serializable data

    try
        # Swarms.completeTask returns Dict with "success" and "task" or "error"
        result = Swarms.completeTask(swarm_id, task_id, agent_id, task_result_data)
         if get(result, "success", false)
            return Utils.json_response(result)
        else
            err_msg = get(result, "error", "Failed to complete task.")
            status_code = occursin("not found", err_msg) ? 404 : (occursin("not assigned", err_msg) ? 403 : 400)
            err_code = occursin("not found", err_msg) ? Utils.ERROR_CODE_NOT_FOUND : (occursin("not assigned", err_msg) ? Utils.ERROR_CODE_FORBIDDEN : "TASK_COMPLETION_FAILED")
            return Utils.error_response(err_msg, status_code, error_code=err_code, details=result)
        end
    catch e
        @error "Error in complete_task_handler for swarm $swarm_id, task $task_id" exception=(e, catch_backtrace())
        return Utils.error_response("Error completing task: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_swarm_shared_state_handler(req::HTTP.Request, swarm_id::String, key::String)
    if isempty(swarm_id) || isempty(key)
        return Utils.error_response("Swarm ID and key cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["swarm_id", "key"]))
    end
    try
        swarm = Swarms.getSwarm(swarm_id)
        if isnothing(swarm)
            return Utils.error_response("Swarm not found", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id))
        end
        value = Swarms.getSharedState(swarm_id, key) # Default can be passed to getSharedState
        if isnothing(value) && !haskey(swarm.shared_data, key) # Check if key truly doesn't exist vs. value is `nothing`
            return Utils.error_response("Key '$key' not found in shared state for swarm '$swarm_id'", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id, "key"=>key))
        end
        return Utils.json_response(Dict("swarm_id"=>swarm_id, "key"=>key, "value"=>value))
    catch e
        @error "Error getting shared state for swarm $swarm_id, key $key" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get shared state: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function update_swarm_shared_state_handler(req::HTTP.Request, swarm_id::String, key::String)
    if isempty(swarm_id) || isempty(key)
        return Utils.error_response("Swarm ID and key cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["swarm_id", "key"]))
    end
    body = Utils.parse_request_body(req)
    if isnothing(body) || !haskey(body, "value") # Value itself can be null/nothing
        return Utils.error_response("Request body must include a 'value' field", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("missing_field"=>"value"))
    end
    value = body["value"]

    try
        success = Swarms.updateSharedState!(swarm_id, key, value)
        if success
            return Utils.json_response(Dict("message"=>"Shared state updated successfully", "swarm_id"=>swarm_id, "key"=>key, "value"=>value))
        else
            # This implies swarm not found from Swarms.updateSharedState!
            return Utils.error_response("Swarm not found or failed to update shared state", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id))
        end
    catch e
        @error "Error updating shared state for swarm $swarm_id, key $key" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to update shared state: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_swarm_metrics_handler(req::HTTP.Request, swarm_id::String)
    if isempty(swarm_id)
        return Utils.error_response("Swarm ID cannot be empty", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("field"=>"swarm_id"))
    end
    try
        metrics = Swarms.getSwarmMetrics(swarm_id)
        if haskey(metrics, "error") # Check if getSwarmMetrics returned an error structure
            return Utils.error_response(metrics["error"], 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("swarm_id"=>swarm_id))
        end
        return Utils.json_response(metrics)
    catch e
        @error "Error getting metrics for swarm $swarm_id" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get metrics for swarm $swarm_id: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

end # module SwarmHandlers
