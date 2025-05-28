# backend-julia/src/agents/AgentMonitor.jl

"""
Agent Monitor Module

Periodically checks the health and status of running agents,
detects stalls, and can trigger configured actions like auto-restarts.
"""
module AgentMonitor

using Dates, Logging, Base.Threads

# Import necessary modules and types
# Assumes these modules are siblings within the 'agents' directory/module scope
import ..Config: get_config
# We need access to the Agent struct, its status, and lifecycle functions
# This import style assumes Agents.jl defines "module Agents"
import ..AgentCore: Agent, AgentStatus, AGENTS, AGENTS_LOCK
import ..Agents: getAgentStatus, listAgents, startAgent

export start_monitor, stop_monitor, get_health_status, HealthStatus

# Enum for overall system/agent health
@enum HealthStatus begin
    HEALTHY = 1
    DEGRADED = 2 # Some agents might be in error or stalled
    UNHEALTHY = 3 # Critical issues, many agents failing
    UNKNOWN = 4
end

# --- Monitor State ---
const MONITOR_TASK = Ref{Union{Task, Nothing}}(nothing)
const MONITOR_RUNNING = Ref{Bool}(false)
const MONITOR_LOCK = ReentrantLock() # Lock for MONITOR_RUNNING and MONITOR_TASK

# Cache for last health status to avoid re-computation on every API call
const LAST_HEALTH_SNAPSHOT = Ref{Dict{String, Any}}(Dict())
const SNAPSHOT_LOCK = ReentrantLock()

"""
    _check_agent_health(agent::Agent)

Checks the health of a single agent.
Returns a Dict with health information for this agent.
"""
function _check_agent_health(agent::Agent)::Dict{String, Any}
    # This function assumes the caller might not hold agent.lock,
    # so it should rely on functions like getAgentStatus that handle locking.
    status_info = getAgentStatus(agent.id) # getAgentStatus handles agent.lock

    is_stalled = false
    max_stall_seconds = get_config("agent.max_stall_seconds", 300)
    
    # Check for stall only if agent is supposed to be running or initializing
    if agent.status == Agents.RUNNING || agent.status == Agents.INITIALIZING
        time_since_last_activity = Dates.value(now(UTC) - agent.last_activity) / 1000 # in seconds
        if time_since_last_activity > max_stall_seconds
            is_stalled = true
            @warn "Agent $(agent.name) ($(agent.id)) appears stalled. Last activity: $(agent.last_activity) ($(round(time_since_last_activity, digits=1))s ago)."
            # Optionally, record a metric for stalled agents via AgentMetrics
            # AgentMetrics.record_metric(agent.id, "agent_stalled_status", 1; type=AgentMetrics.GAUGE)
        end
    end

    health_details = Dict(
        "id" => agent.id,
        "name" => agent.name,
        "status" => status_info["status"], # string representation from getAgentStatus
        "is_stalled" => is_stalled,
        "last_activity" => string(agent.last_activity),
        "uptime_seconds" => status_info["uptime_seconds"],
        "last_error" => status_info["last_error"]
    )
    return health_details
end

"""
    _perform_health_check()

Performs a health check on all registered agents and updates the health snapshot.
"""
function _perform_health_check()
    @debug "Performing system-wide agent health check..."
    num_agents_total = 0
    num_agents_running = 0
    num_agents_error = 0
    num_agents_stalled = 0
    
    agent_health_reports = Dict{String, Any}()

    # Use listAgents to get a snapshot of current agents.
    # listAgents handles AGENTS_LOCK correctly.
    all_agents_list = listAgents() # Gets a Vector{Agent}
    num_agents_total = length(all_agents_list)

    for agent_instance in all_agents_list
        # It's important that _check_agent_health uses functions that
        # correctly handle locking for individual agent state if needed.
        # `agent_instance` here is a copy of the Agent struct.
        # If _check_agent_health needs the most up-to-date mutable state,
        # it should re-fetch the agent or use status functions that lock.
        # getAgentStatus already does this.
        
        # We pass the agent_instance which contains its ID and other immutable parts.
        # _check_agent_health primarily uses getAgentStatus(agent_instance.id)
        # which fetches the current state of the agent.
        report = _check_agent_health(agent_instance)
        agent_health_reports[agent_instance.id] = report

        if report["status"] == string(Agents.RUNNING) # Compare with string representation
            num_agents_running += 1
        elseif report["status"] == string(Agents.ERROR)
            num_agents_error += 1
        end
        if report["is_stalled"]
            num_agents_stalled += 1
        end

        # Auto-restart logic (optional)
        if (report["status"] == string(Agents.ERROR) || report["is_stalled"]) && get_config("agent.auto_restart", false)
            @warn "Auto-restarting agent $(agent_instance.name) ($(agent_instance.id)) due to status: $(report["status"]), stalled: $(report["is_stalled"])"
            try
                # Ensure stopAgent is called first if it's stalled but not stopped.
                # startAgent should handle the logic of starting a stopped/errored agent.
                Agents.stopAgent(agent_instance.id) # Attempt to gracefully stop if needed
                success = Agents.startAgent(agent_instance.id) # startAgent handles status checks
                if success
                    @info "Agent $(agent_instance.name) restarted successfully."
                    # AgentMetrics.record_metric(agent_instance.id, "agent_auto_restarts", 1; type=AgentMetrics.COUNTER)
                else
                    @error "Failed to auto-restart agent $(agent_instance.name)."
                end
            catch e
                @error "Exception during auto-restart of agent $(agent_instance.name)" exception=(e, catch_backtrace())
            end
        end
    end

    overall_status = HEALTHY
    if num_agents_error > 0 || num_agents_stalled > 0
        overall_status = DEGRADED
    end
    # Define more sophisticated logic for UNHEALTHY if needed (e.g., >50% agents in error)
    if num_agents_total > 0 && (num_agents_error + num_agents_stalled) > num_agents_total / 2
        overall_status = UNHEALTHY
    elseif num_agents_total == 0 && num_agents_error == 0 # No agents, no errors
         overall_status = HEALTHY # Or perhaps UNKNOWN/IDLE depending on desired semantics
    end


    snapshot_data = Dict(
        "overall_status" => string(overall_status),
        "timestamp" => string(now(UTC)),
        "total_agents" => num_agents_total,
        "running_agents" => num_agents_running,
        "error_agents" => num_agents_error,
        "stalled_agents" => num_agents_stalled,
        "agent_details" => agent_health_reports # Dict of individual agent health reports
    )

    lock(SNAPSHOT_LOCK) do
        LAST_HEALTH_SNAPSHOT[] = snapshot_data
    end
    @info "Health check complete. Overall: $(overall_status), Total: $num_agents_total, Running: $num_agents_running, Error: $num_agents_error, Stalled: $num_agents_stalled"
end


"""
    monitor_loop()

The main loop for the agent monitor task. Periodically calls `_perform_health_check`.
"""
function monitor_loop()
    monitor_interval = get_config("agent.monitor_interval_seconds", 30)
    if monitor_interval <= 0
        @warn "Agent monitor interval is <= 0 (value: $monitor_interval). Monitor will not run periodically."
        # Ensure MONITOR_RUNNING is set to false if we decide not to loop.
        lock(MONITOR_LOCK) do
            MONITOR_RUNNING[] = false # Stop the loop if interval is invalid
        end
        return
    end

    @info "Agent monitor task started. Check interval: $(monitor_interval)s"
    try
        while true
            running = false
            lock(MONITOR_LOCK) do
                running = MONITOR_RUNNING[]
            end

            if !running
                break
            end

            _perform_health_check()
            sleep(monitor_interval)
        end
    catch e
        # Allow InterruptException to cleanly stop the task during shutdown
        if isa(e, InterruptException)
            @info "Agent monitor task interrupted."
        else
            @error "Agent monitor task crashed!" exception=(e, catch_backtrace())
        end
    finally
        @info "Agent monitor task stopped."
        lock(MONITOR_LOCK) do # Ensure lock for state modification
            MONITOR_RUNNING[] = false
            MONITOR_TASK[] = nothing
        end
    end
end

"""
    start_monitor()::Bool

Starts the agent monitoring background task if not already running and if enabled in config.
"""
function start_monitor()::Bool
    if !get_config("agent.monitor_enabled", true) # Add a config option to disable monitor
        @info "Agent monitor is disabled by configuration."
        return false
    end

    lock(MONITOR_LOCK) do
        if MONITOR_RUNNING[]
            @warn "Agent monitor task is already running."
            return false
        end
        
        monitor_interval = get_config("agent.monitor_interval_seconds", 30)
        if monitor_interval <= 0
            @warn "Agent monitor interval is non-positive ($monitor_interval seconds). Monitor will not start."
            return false
        end

        MONITOR_RUNNING[] = true
        MONITOR_TASK[] = @task monitor_loop()
        schedule(MONITOR_TASK[])
        return true
    end
end

"""
    stop_monitor()::Bool

Stops the agent monitoring background task.
"""
function stop_monitor()::Bool
    task_to_stop = nothing
    lock(MONITOR_LOCK) do
        if !MONITOR_RUNNING[]
            @warn "Agent monitor task is not running."
            return false
        end
        MONITOR_RUNNING[] = false # Signal the loop to stop
        task_to_stop = MONITOR_TASK[]
    end

    # Attempt to interrupt and wait for the task to finish
    if !isnothing(task_to_stop) && !istaskdone(task_to_stop)
        try
            @info "Attempting to interrupt agent monitor task..."
            schedule(task_to_stop, InterruptException(), error=true)
            # Wait for a short period, but don't block indefinitely
            # yield() # Give the task a chance to process the interrupt
            # For more robust stopping, you might need a timed wait or check istaskdone in a loop.
            # For now, we've signaled it. The finally block in monitor_loop will clean up.
        catch e
            @error "Error while trying to interrupt monitor task" exception=e
        end
    end
    @info "Agent monitor stop signal sent."
    return true
end

"""
    get_health_status()::Dict{String, Any}

Retrieves the last recorded health snapshot of the agent system.
"""
function get_health_status()::Dict{String, Any}
    lock(SNAPSHOT_LOCK) do
        if isempty(LAST_HEALTH_SNAPSHOT[])
            # If no snapshot yet, perform an initial check or return UNKNOWN
            # For simplicity, let's return UNKNOWN if called before first check.
            # Or, trigger a check: _perform_health_check() here, but that might take time.
            return Dict(
                "overall_status" => string(UNKNOWN),
                "timestamp" => string(now(UTC)),
                "message" => "No health snapshot available yet. Monitor might be starting or not run."
            )
        end
        return deepcopy(LAST_HEALTH_SNAPSHOT[]) # Return a copy to prevent external modification
    end
end

"""
    __init__()

Module initialization function. Starts the monitor task automatically if enabled.
"""
function __init__()
    # Automatically start the monitor when the module is loaded if enabled
    # This ensures the monitor runs when the application starts.
    if get_config("agent.monitor_enabled", true) && get_config("agent.monitor_autostart", true)
        # Run as an async task to avoid blocking module loading if start_monitor takes time
        # or if there are delays in its initial setup.
        @async begin
            sleep(get_config("agent.monitor_initial_delay_seconds", 5)) # Optional delay
            start_monitor()
        end
    else
        @info "Agent monitor auto-start disabled by configuration."
    end
end

end # module AgentMonitor
