# backend-julia/src/agents/Config.jl

"""
Configuration Management Module

Handles loading, getting, and setting configuration values from TOML files,
environment variables, and providing defaults.
"""
module Config

using TOML, Logging

export load_config, get_config, set_config

# Environment variable prefix for overrides
const ENV_VAR_PREFIX = "CUTEPANEL_"

# Default configuration values
const DEFAULT_CONFIG = Dict{String, Any}(
    "api" => Dict{String, Any}(
        "host" => "0.0.0.0",
        "port" => 8000
    ),
    "storage" => Dict{String, Any}(
        "path" => joinpath(@__DIR__, "..", "..", "data", "agents_state.json"), # Assuming Config.jl is in src/agents/, so ../../data/
        "backup_enabled" => true,
        "backup_count" => 5,
        "auto_persist" => true,
        "persist_interval_seconds" => 60
    ),
    "agent" => Dict{String, Any}(
        "max_task_history" => 100,
        "xp_decay_rate" => 0.999,
        "default_sleep_ms" => 1000,
        "paused_sleep_ms" => 500,
        "auto_restart" => false,
        "monitor_enabled" => true,
        "monitor_autostart" => true,
        "monitor_interval_seconds" => 30,
        "monitor_initial_delay_seconds" => 5,
        "max_stall_seconds" => 300
    ),
    "metrics" => Dict{String, Any}(
        "enabled" => true,
        "collection_interval_seconds" => 60,
        "retention_period_seconds" => 86400 # 24 hours
    ),
    "swarm" => Dict{String, Any}(
        "enabled" => false,
        "backend" => "none", # Options: none, redis, nats, zeromq
        "connection_string" => "", # e.g., "redis://localhost:6379"
        "default_topic_prefix" => "cutepanel.swarm"
    ),
    "llm" => Dict{String, Any}( # Placeholder for global LLM defaults
        "default_provider" => "openai",
        "default_model" => "gpt-4o-mini",
        "api_key_env_vars" => Dict( # Document common ENV var names for API keys
            "openai" => "OPENAI_API_KEY",
            "anthropic" => "ANTHROPIC_API_KEY",
            # Add others as needed
        )
    )
)

# Current configuration (initialized with a deepcopy of defaults)
const CURRENT_CONFIG = deepcopy(DEFAULT_CONFIG)
const CONFIG_LOCK = ReentrantLock() # For thread-safe modification of CURRENT_CONFIG

"""
    _construct_env_var_name(key::String)::String

Constructs an environment variable name from a dot-separated config key.
Example: "agent.max_task_history" -> "CUTEPANEL_AGENT_MAX_TASK_HISTORY"
"""
function _construct_env_var_name(key::String)::String
    return uppercase(ENV_VAR_PREFIX * replace(key, "." => "_"))
end

"""
    load_config(config_path::String="")

Loads configuration from a TOML file, merging it with defaults.
Searches default locations if `config_path` is empty.
Default locations:
1. `project_root/config/agents.toml`
2. `~/.cutepanel/config/agents.toml`

# Arguments
- `config_path::String`: Optional path to a specific configuration TOML file.

# Returns
- `true` if a configuration file was found and loaded successfully, `false` otherwise.
"""
function load_config(config_path::String="")::Bool
    actual_config_path = config_path

    if isempty(actual_config_path)
        # Default paths:
        # 1. Relative to this file: ../../config/agents.toml (assuming src/agents/Config.jl)
        #    This resolves to project_root/config/agents.toml
        path_in_project = joinpath(@__DIR__, "..", "..", "config", "agents.toml")
        # 2. User's home directory
        path_in_home = joinpath(homedir(), ".cutepanel", "config", "agents.toml")

        if isfile(path_in_project)
            actual_config_path = path_in_project
        elseif isfile(path_in_home)
            actual_config_path = path_in_home
        end
    end

    if !isempty(actual_config_path) && isfile(actual_config_path)
        try
            @info "Loading configuration from: $actual_config_path"
            config_data_from_file = TOML.parsefile(actual_config_path)
            
            lock(CONFIG_LOCK) do
                # Reset CURRENT_CONFIG to defaults before merging, to ensure clean load
                empty!(CURRENT_CONFIG)
                merge!(CURRENT_CONFIG, deepcopy(DEFAULT_CONFIG))
                _recursive_merge!(CURRENT_CONFIG, config_data_from_file)
            end
            @info "Successfully loaded and merged configuration from $actual_config_path"
            return true
        catch e
            @error "Failed to load or parse configuration from $actual_config_path. Using defaults." exception=(e, catch_backtrace())
            # Ensure CURRENT_CONFIG is still the default if loading fails
            lock(CONFIG_LOCK) do
                if !isequal(CURRENT_CONFIG, DEFAULT_CONFIG) # Check if it was partially modified
                    empty!(CURRENT_CONFIG)
                    merge!(CURRENT_CONFIG, deepcopy(DEFAULT_CONFIG))
                end
            end
            return false
        end
    else
        @info "No external configuration file found at specified or default locations. Using default configuration."
        # Ensure CURRENT_CONFIG is the default if no file is loaded
        lock(CONFIG_LOCK) do
            if !isequal(CURRENT_CONFIG, DEFAULT_CONFIG)
                empty!(CURRENT_CONFIG)
                merge!(CURRENT_CONFIG, deepcopy(DEFAULT_CONFIG))
            end
        end
        return false # No file loaded, but defaults are active
    end
end

"""
    _recursive_merge!(target::Dict, source::Dict)

Recursively merges `source` Dict into `target` Dict.
Values in `source` overwrite values in `target`.
"""
function _recursive_merge!(target::Dict{String, Any}, source::Dict)
    for (key, src_val) in source
        if isa(src_val, Dict) && haskey(target, key) && isa(target[key], Dict)
            _recursive_merge!(target[key], src_val) # Recurse for nested Dictionaries
        else
            target[key] = src_val # Set/overwrite value
        end
    end
end

"""
    get_config(key::String, default_value::Any=nothing)

Retrieves a configuration value.
Checks environment variables first (e.g., CUTEPANEL_AGENT_MAX_TASK_HISTORY for "agent.max_task_history"),
then the loaded TOML configuration, then programmatic defaults.

# Arguments
- `key::String`: The configuration key using dot notation (e.g., "agent.max_task_history").
- `default_value::Any`: The value to return if the key is not found anywhere.

# Returns
- The configuration value, or `default_value`. The type might be converted.
"""
function get_config(key::String, default_value::Any=nothing)
    env_var_name = _construct_env_var_name(key)
    env_val_str = get(ENV, env_var_name, nothing)

    # Determine the target type from the default_value, or if not provided, from DEFAULT_CONFIG
    target_type_from_default = default_value !== nothing ? typeof(default_value) : nothing
    
    # If ENV var is set, try to use and parse it
    if env_val_str !== nothing
        # Try to parse env_val_str to the type of default_value or a common type
        parsed_env_val = _try_parse_to_type(env_val_str, target_type_from_default)
        if parsed_env_val !== nothing # Successfully parsed
            return parsed_env_val
        else
            @warn "Environment variable $env_var_name is set to '$env_val_str' but could not be parsed to the expected type. Ignoring."
        end
    end

    # If no ENV var or parsing failed, check CURRENT_CONFIG (which includes TOML and defaults)
    parts = split(key, ".")
    current_dict_level = lock(CONFIG_LOCK) do # Read access to CURRENT_CONFIG
        deepcopy(CURRENT_CONFIG) # Work on a copy for thread safety during traversal
    end

    for part in parts[1:end-1]
        if haskey(current_dict_level, part) && isa(current_dict_level[part], Dict)
            current_dict_level = current_dict_level[part]
        else
            return default_value # Key path not found, return overall default
        end
    end

    # Get the value from the deepest level found in CURRENT_CONFIG, or use default_value
    # The value from CURRENT_CONFIG already has its type from TOML parsing or DEFAULT_CONFIG
    final_value = get(current_dict_level, parts[end], default_value)
    
    # Final type coercion if default_value was provided and types differ
    # (This is mostly for when default_value is provided AND different from what's in DEFAULT_CONFIG for that key)
    if default_value !== nothing && final_value !== nothing && typeof(final_value) != typeof(default_value)
        coerced_value = _try_parse_to_type(string(final_value), typeof(default_value)) # Coerce using string representation
        return coerced_value !== nothing ? coerced_value : final_value # Return coerced if successful, else original final_value
    end

    return final_value
end

"""
    _try_parse_to_type(val_str::String, target_type::Union{Type, Nothing})

Attempts to parse `val_str` to `target_type`.
Returns the parsed value or `nothing` if parsing fails or `target_type` is `Nothing`.
"""
function _try_parse_to_type(val_str::String, target_type::Union{Type, Nothing})
    isnothing(target_type) && return val_str # If no target type, return as string (or could try to infer)

    try
        if target_type <: Integer
            return parse(Int, val_str) # Or a specific Int type like Int64
        elseif target_type <: AbstractFloat
            return parse(Float64, val_str) # Or a specific Float type
        elseif target_type == Bool
            lc_val = lowercase(val_str)
            if lc_val == "true"
                return true
            elseif lc_val == "false"
                return false
            else
                # Try parsing as number for 0/1
                parsed_num = tryparse(Int, lc_val)
                if parsed_num == 1 return true end
                if parsed_num == 0 return false end
                return nothing # Could not parse as bool
            end
        elseif target_type <: AbstractString # Already a string, or needs to be string
            return val_str 
        # Add more types as needed (e.g., Dates, custom types)
        else
            @warn "Unsupported target type for parsing environment variable or config value: $target_type for value '$val_str'"
            return val_str # Fallback to string if type is unknown for parsing
        end
    catch e
        @warn "Failed to parse '$val_str' to type $target_type" exception=(e, catch_backtrace())
        return nothing # Parsing failed
    end
end


"""
    set_config(key::String, value::Any)

Sets a configuration value at runtime using dot notation (e.g., "agent.max_task_history").
This modifies the `CURRENT_CONFIG` in memory. It does NOT write back to the TOML file.
Creates nested dictionaries if necessary.

# Arguments
- `key::String`: The configuration key.
- `value::Any`: The value to set.

# Returns
- The set value.
"""
function set_config(key::String, value::Any)
    lock(CONFIG_LOCK) do
        parts = split(key, ".")
        current = CURRENT_CONFIG

        for part in parts[1:end-1]
            if !haskey(current, part) || !isa(current[part], Dict)
                current[part] = Dict{String, Any}() # Create nested dict if needed
            end
            current = current[part]
        end
        
        # Attempt to convert `value` to match existing type if possible, or store as is
        original_default_value_at_key = _get_from_dict_path(DEFAULT_CONFIG, parts)

        if original_default_value_at_key !== nothing && typeof(value) != typeof(original_default_value_at_key)
            parsed_value = _try_parse_to_type(string(value), typeof(original_default_value_at_key))
            if parsed_value !== nothing
                current[parts[end]] = parsed_value
                return parsed_value
            end
        end
        # If no original default or parsing failed, set the value as is
        current[parts[end]] = value
        return value
    end
end

"""
Helper to get a value from a nested Dict using a path of keys.
Returns nothing if path is not found.
"""
function _get_from_dict_path(d::Dict, path_parts::Vector{SubString{String}})
    current = d
    for part in path_parts[1:end-1]
        if haskey(current, part) && isa(current[part], Dict)
            current = current[part]
        else
            return nothing
        end
    end
    return get(current, path_parts[end], nothing)
end


# Load configuration automatically when the module is loaded.
function __init__()
    try
        load_config() # Attempt to load from file
    catch e
        # This catch is a safeguard, load_config itself logs errors.
        @error "Critical error during initial configuration loading in __init__." exception=(e, catch_backtrace())
        # Ensure CURRENT_CONFIG is at least the default state.
        lock(CONFIG_LOCK) do
            global CURRENT_CONFIG = deepcopy(DEFAULT_CONFIG)
        end
    end
end

end # module Config
