# backend-julia/src/agents/AgentMetrics.jl

"""
Agent Metrics Module

Handles collecting, storing, and retrieving metrics for individual agents.
"""
module AgentMetrics

using Dates, DataStructures, Statistics, Logging

# Import necessary functions from the Config module.
# Assumes Config.jl defines "module Config" and is a sibling to this file
# within the "agents" directory/module scope.
import ..Config: get_config
import ..AgentCore: AGENTS, AGENTS_LOCK, AgentStatus, RUNNING, PAUSED

export record_metric, get_metrics, get_agent_metrics, reset_metrics, get_system_summary_metrics,
       MetricType, COUNTER, GAUGE, HISTOGRAM, SUMMARY # Export MetricType enum and its values

# Metric types
@enum MetricType begin
    COUNTER = 1  # Monotonically increasing counter (e.g., tasks_executed)
    GAUGE = 2    # Value that can go up and down (e.g., memory_usage)
    HISTOGRAM = 3 # Distribution of values (e.g., execution_time observations)
    SUMMARY = 4  # Pre-calculated summary statistics (min, max, avg, percentiles, etc.)
end

# Metric data structure
mutable struct Metric
    name::String
    type::MetricType
    # For COUNTER/GAUGE: Number
    # For HISTOGRAM: Vector{Number} (a batch of observations recorded at this timestamp)
    # For SUMMARY: Dict{String, Any} (e.g., {"count"=>10, "sum"=>100, "avg"=>10, "p95"=>20})
    value::Union{Number, Vector{Number}, Dict{String, Any}}
    timestamp::DateTime
    tags::Dict{String, String} # For adding dimensions to metrics
end

# Global metrics storage
# Structure: Dict{agent_id, Dict{metric_name, CircularBuffer{Metric}}}
const METRICS_STORE = Dict{String, Dict{String, CircularBuffer{Metric}}}()
const METRICS_LOCK = ReentrantLock() # Lock for thread-safe access to METRICS_STORE

"""
    init_agent_metrics(agent_id::String)

Initializes the metrics storage for a new agent. Typically called during agent creation.
This function is idempotent.

# Arguments
- `agent_id::String`: The unique identifier of the agent.
"""
function init_agent_metrics(agent_id::String)
    lock(METRICS_LOCK) do
        if !haskey(METRICS_STORE, agent_id)
            METRICS_STORE[agent_id] = Dict{String, CircularBuffer{Metric}}()
            @debug "Initialized metrics store for agent $agent_id"
        end
    end
end

"""
    record_metric(agent_id::String, name::String, value::Any; type::MetricType=GAUGE, tags::Dict{String, String}=Dict{String, String}())

Records a metric for a specific agent.

# Arguments
- `agent_id::String`: The ID of the agent.
- `name::String`: The name of the metric (e.g., "cpu_usage", "tasks_processed").
- `value::Any`: The value of the metric.
    - For `COUNTER`, `GAUGE`: Should be a `Number`.
    - For `HISTOGRAM`: Should be a `Vector{Number}` representing one or more observations.
    - For `SUMMARY`: Should be a `Dict{String, Any}` containing summary statistics.
- `type::MetricType`: The type of the metric (default: `GAUGE`).
- `tags::Dict{String, String}`: Optional tags (dimensions) for the metric.

# Returns
- The recorded `Metric` object, or `nothing` if metrics are disabled or input is invalid.
"""
function record_metric(agent_id::String, name::String, value::Any;
                       type::MetricType=GAUGE,
                       tags::Dict{String, String}=Dict{String, String}())
    # Check if metrics are enabled globally
    if !get_config("metrics.enabled", true)
        return nothing
    end

    # Validate value type against metric type
    if type == HISTOGRAM && !isa(value, AbstractVector{<:Number})
        @warn "Invalid value for HISTOGRAM metric '$name'. Expected Vector{<:Number}, got $(typeof(value))."
        return nothing
    elseif (type == COUNTER || type == GAUGE) && !isa(value, Number)
        @warn "Invalid value for $type metric '$name'. Expected Number, got $(typeof(value))."
        return nothing
    elseif type == SUMMARY && !isa(value, AbstractDict)
        @warn "Invalid value for SUMMARY metric '$name'. Expected Dict, got $(typeof(value))."
        return nothing
    end

    lock(METRICS_LOCK) do
        # Initialize agent metrics if not already done (defensive)
        if !haskey(METRICS_STORE, agent_id)
             init_agent_metrics(agent_id) # This also acquires METRICS_LOCK (ReentrantLock handles this)
        end

        agent_specific_metrics = METRICS_STORE[agent_id]
        # Initialize buffer for this specific metric if it's new for this agent
        if !haskey(agent_specific_metrics, name)
            retention_period_seconds = get_config("metrics.retention_period_seconds", 86400) # Default 24 hours
            collection_interval_seconds = get_config("metrics.collection_interval_seconds", 60) # Default 60 seconds
            # Ensure buffer is large enough, with a sensible minimum
            buffer_size = max(100, ceil(Int, retention_period_seconds / collection_interval_seconds))
            agent_specific_metrics[name] = CircularBuffer{Metric}(buffer_size)
            @debug "Initialized metric buffer '$name' for agent $agent_id with size $buffer_size"
        end

        # Create and store the metric
        metric_entry = Metric(name, type, value, now(UTC), tags) # Use UTC for consistency
        push!(agent_specific_metrics[name], metric_entry)
        # @debug "Recorded metric '$name' for agent $agent_id: $value, type: $type" # More detailed debug

        return metric_entry
    end
end

"""
    get_agent_metrics(agent_id::String; metric_name::Union{String, Nothing}=nothing, start_time::Union{DateTime, Nothing}=nothing, end_time::Union{DateTime, Nothing}=nothing)

Retrieves processed metrics for a specific agent. Metrics can be filtered by name and a time range.

# Arguments
- `agent_id::String`: The ID of the agent.
- `metric_name::Union{String, Nothing}`: Optional. If provided, retrieves only this specific metric.
- `start_time::Union{DateTime, Nothing}`: Optional. Filters metrics recorded on or after this time.
- `end_time::Union{DateTime, Nothing}`: Optional. Filters metrics recorded on or before this time.

# Returns
- `Dict{String, Any}`: A dictionary where keys are metric names and values are processed metric data.
  Returns an empty dictionary if the agent is not found or no matching metrics are found.
"""
function get_agent_metrics(agent_id::String;
                           metric_name::Union{String, Nothing}=nothing,
                           start_time::Union{DateTime, Nothing}=nothing,
                           end_time::Union{DateTime, Nothing}=nothing)::Dict{String, Any}
    processed_result = Dict{String, Any}()

    lock(METRICS_LOCK) do
        if !haskey(METRICS_STORE, agent_id)
            return processed_result # Agent has no metrics recorded
        end

        agent_specific_metrics = METRICS_STORE[agent_id]
        metric_names_to_process = isnothing(metric_name) ? keys(agent_specific_metrics) : [metric_name]

        for name_key in metric_names_to_process
            if haskey(agent_specific_metrics, name_key)
                # Apply time filters
                # Collect converts CircularBuffer to Vector for easier filtering
                metrics_buffer_view = collect(agent_specific_metrics[name_key])
                
                filtered_metrics_list = filter(m -> 
                    (isnothing(start_time) || m.timestamp >= start_time) &&
                    (isnothing(end_time) || m.timestamp <= end_time), 
                    metrics_buffer_view
                )

                if !isempty(filtered_metrics_list)
                    # Use the type from the latest metric entry in the filtered list for processing logic
                    # This assumes all metrics with the same name have the same type, which record_metric should enforce.
                    latest_metric_entry = filtered_metrics_list[end]
                    metric_type = latest_metric_entry.type

                    if metric_type == COUNTER || metric_type == GAUGE
                        processed_result[name_key] = Dict(
                            "current" => latest_metric_entry.value,
                            "type" => string(metric_type),
                            # History provides (timestamp, value) tuples for plotting or analysis
                            "history" => [(m.timestamp, m.value) for m in filtered_metrics_list],
                            "last_updated" => string(latest_metric_entry.timestamp) # For JSON serialization
                        )
                    elseif metric_type == HISTOGRAM
                        # For histograms, concatenate all observed values (each m.value is a Vector{Number})
                        # and compute statistics over the combined set.
                        all_observed_values = vcat(Vector{Number}[m.value for m in filtered_metrics_list if isa(m.value, AbstractVector{<:Number})]...)
                        
                        if !isempty(all_observed_values)
                            processed_result[name_key] = Dict(
                                "type" => "HISTOGRAM",
                                "count" => length(all_observed_values),
                                "min" => minimum(all_observed_values),
                                "max" => maximum(all_observed_values),
                                "mean" => mean(all_observed_values),
                                "median" => median(all_observed_values),
                                # Could add percentiles: "p95" => percentile(all_observed_values, 95)
                                "last_updated" => string(latest_metric_entry.timestamp)
                            )
                        end
                    elseif metric_type == SUMMARY
                        # For summaries, return the latest recorded summary dictionary.
                        # The assumption is that the summary was pre-calculated before being recorded.
                        processed_result[name_key] = Dict(
                            "type" => "SUMMARY",
                            "value" => latest_metric_entry.value, # This is already a Dict
                            "last_updated" => string(latest_metric_entry.timestamp)
                        )
                    end
                end
            end
        end
    end
    return processed_result
end

"""
    get_metrics(; metric_name::Union{String, Nothing}=nothing, start_time::Union{DateTime, Nothing}=nothing, end_time::Union{DateTime, Nothing}=nothing)

Retrieves metrics for all agents. Can be filtered by metric name and time range.

# Arguments
- `metric_name`, `start_time`, `end_time`: Same as for `get_agent_metrics`.

# Returns
- `Dict{String, Dict{String, Any}}`: A dictionary where keys are agent IDs, and values are
  the processed metrics for that agent (structure from `get_agent_metrics`).
"""
function get_metrics(; metric_name::Union{String, Nothing}=nothing,
                     start_time::Union{DateTime, Nothing}=nothing,
                     end_time::Union{DateTime, Nothing}=nothing)::Dict{String, Dict{String, Any}}
    all_agents_result = Dict{String, Dict{String, Any}}()
    lock(METRICS_LOCK) do
        for agent_id_key in keys(METRICS_STORE)
            agent_metrics_data = get_agent_metrics(agent_id_key;
                                             metric_name=metric_name,
                                             start_time=start_time,
                                             end_time=end_time)
            if !isempty(agent_metrics_data)
                all_agents_result[agent_id_key] = agent_metrics_data
            end
        end
    end
    return all_agents_result
end

"""
    reset_metrics(agent_id::Union{String, Nothing}=nothing)

Resets (clears) metrics for a specific agent or for all agents if `agent_id` is `nothing`.

# Arguments
- `agent_id::Union{String, Nothing}`: The ID of the agent whose metrics to reset.
  If `nothing`, metrics for all agents are reset.
"""
function reset_metrics(agent_id::Union{String, Nothing}=nothing)
    lock(METRICS_LOCK) do
        if isnothing(agent_id)
            # Reset metrics for all agents
            original_agent_count = length(METRICS_STORE)
            empty!(METRICS_STORE)
            @info "Reset metrics for all ($original_agent_count) agents."
        elseif haskey(METRICS_STORE, agent_id)
            # Reset metrics for a specific agent
            empty!(METRICS_STORE[agent_id]) # Clear the inner Dict of metric names
            # Optionally, to completely remove the agent entry if no new metrics are expected soon:
            # delete!(METRICS_STORE, agent_id)
            @info "Reset metrics for agent $agent_id."
        else
            @warn "Attempted to reset metrics for unknown or unmonitored agent $agent_id."
        end
    end
end

# No __init__ function needed for this module as it relies on Config.jl's initialization
# and its constants are defined at compile time.


"""
    get_system_summary_metrics()::Dict{String, Any}

Retrieves aggregated system-wide metrics.
"""
function get_system_summary_metrics()::Dict{String, Any}
    summary = Dict{String, Any}()

    # Agent counts
    total_agents = 0
    active_agents = 0 # RUNNING or PAUSED
    
    # This part requires access to Agents.AGENTS and Agents.AGENTS_LOCK
    # Ensure these are correctly imported or passed if AgentMetrics is truly standalone.
    # For now, assuming direct import works as per the try-catch block above.
    if @isdefined(AGENTS) && @isdefined(AGENTS_LOCK)
        lock(AGENTS_LOCK) do
            total_agents = length(AGENTS)
            for agent_instance in values(AGENTS)
                # Assuming agent_instance has a .status field of type AgentStatus
                if agent_instance.status == RUNNING || agent_instance.status == PAUSED
                    active_agents += 1
                end
            end
        end
    else
        @warn "Cannot access Agents.AGENTS for system metrics due to import issue."
    end
    summary["total_agents_managed"] = total_agents
    summary["active_agents_running_or_paused"] = active_agents

    # Aggregated metrics from METRICS_STORE
    total_tasks_executed_all_types = 0
    # Example: Sum a specific counter metric across all agents
    # This requires knowing the names of metrics that agents might record.
    # Let's assume agents record "tasks_executed_direct" and "tasks_executed_queued" as COUNTERs.

    lock(METRICS_LOCK) do
        for (agent_id, agent_metrics_map) in METRICS_STORE
            for metric_name_to_sum in ["tasks_executed_direct", "tasks_executed_queued", "skills_executed"]
                if haskey(agent_metrics_map, metric_name_to_sum)
                    metric_buffer = agent_metrics_map[metric_name_to_sum]
                    if !isempty(metric_buffer)
                        # For a COUNTER, the "current" value is the latest recorded value,
                        # which represents the total count for that agent if it's a monotonically increasing counter.
                        # If it's a gauge that resets, this logic would be different.
                        # Assuming these are true counters.
                        # We sum the latest value of these counters from each agent.
                        latest_metric_entry = last(metric_buffer) # Get the most recent entry
                        if latest_metric_entry.type == COUNTER && isa(latest_metric_entry.value, Number)
                            total_tasks_executed_all_types += latest_metric_entry.value
                        end
                    end
                end
            end
        end
    end
    summary["total_tasks_executed_across_all_agents"] = total_tasks_executed_all_types
    
    # Placeholder for actual system CPU/Memory (would require OS-specific calls or a library)
    summary["system_cpu_usage_placeholder"] = rand() 
    summary["system_memory_usage_mb_placeholder"] = rand(50:500) 

    summary["last_updated"] = string(now(UTC))
    return summary
end

end # module AgentMetrics
