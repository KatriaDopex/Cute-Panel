module Config

export load, get_value

# Default configuration
const DEFAULT_CONFIG = Dict(
    "server" => Dict(
        "host" => "localhost",
        "port" => 8052,
        "workers" => 4,
        "log_level" => "info"
    ),
    "storage" => Dict(
        "local_db_path" => joinpath(homedir(), ".cutepanel", "cutepanel.sqlite"),
        "arweave_wallet_file" => get(ENV, "ARWEAVE_WALLET_FILE", ""),
        "arweave_gateway" => get(ENV, "ARWEAVE_GATEWAY", "arweave.net"),
        "arweave_port" => parse(Int, get(ENV, "ARWEAVE_PORT", "443")),
        "arweave_protocol" => get(ENV, "ARWEAVE_PROTOCOL", "https"),
        "arweave_timeout" => parse(Int, get(ENV, "ARWEAVE_TIMEOUT", "20000")),
        "arweave_logging" => parse(Bool, get(ENV, "ARWEAVE_LOGGING", "false"))
    ),
    "blockchain" => Dict(
        "default_chain" => "ethereum",
        "rpc_urls" => Dict(
            "ethereum" => "https://mainnet.infura.io/v3/YOUR_API_KEY",
            "polygon" => "https://polygon-rpc.com",
            "solana" => "https://api.mainnet-beta.solana.com"
        ),
        "max_gas_price" => 100.0,
        "max_slippage" => 0.01,
        "supported_chains" => ["ethereum", "polygon", "solana"]
    ),
    "swarm" => Dict(
        "default_algorithm" => "DE",
        "default_population_size" => 50,
        "max_iterations" => 1000,
        "parallel_evaluation" => true
    ),
    "security" => Dict(
        "rate_limit" => 100,  # requests per minute
        "max_request_size" => 1048576,  # 1MB
        "enable_authentication" => true, # Enabled by default
        "api_keys" => ["default-secret-key-please-change"] # List of valid API keys
    ),
    "bridge" => Dict(
        "port" => 8052,
        "host" => "localhost",
        "bridge_api_url" => "http://localhost:3001/api/v1"
    ),

    "wormhole" => Dict(
        "enabled" => true,
        "network" => "testnet",
        "networks" => Dict(
            "ethereum" => Dict(
                "rpcUrl" => "https://goerli.infura.io/v3/your-infura-key",
                "enabled" => true
            ),
            "solana" => Dict(
                "rpcUrl" => "https://api.devnet.solana.com",
                "enabled" => true
            )
        )
    ),
    "logging" => Dict(
        "level" => "info",
        "format" => "json",
        "retention_days" => 7
    )
)

# Configuration object with dot notation access
struct Configuration
    data::Dict{String, Any}

    # Constructor that allows dot notation access to nested dictionaries
    function Configuration(data::Dict)
        new(convert(Dict{String, Any}, data))
    end

    # Allow dot notation access
    function Base.getproperty(config::Configuration, key::Symbol)
        key_str = String(key)
        if key_str == "data"
            return getfield(config, :data)
        elseif haskey(config.data, key_str)
            value = config.data[key_str]
            if value isa Dict{String, Any}
                return Configuration(value)
            else
                return value
            end
        else
            error("Configuration key not found: $key_str")
        end
    end

    # Check if a key exists
    function Base.haskey(config::Configuration, key::Symbol)
        key_str = String(key)
        return haskey(config.data, key_str)
    end
end

"""
    load(config_path=nothing)

Load configuration from environment variables and optionally from a TOML file.
Environment variables take precedence over file configuration.
"""
function load(config_path=nothing)
    # Start with default configuration
    config_data = deepcopy(DEFAULT_CONFIG)

    # Load from file if provided
    if !isnothing(config_path) && isfile(config_path)
        try
            file_config = Dict{String, Any}()
            # In a real implementation, you would use TOML.parsefile here
            # For now, we'll just use the default config
            merge_configs!(config_data, file_config)
        catch e
            @warn "Error loading configuration file: $e"
        end
    elseif isfile(joinpath(@__DIR__, "config.toml"))
        try
            file_config = Dict{String, Any}()
            # In a real implementation, you would use TOML.parsefile here
            # For now, we'll just use the default config
            merge_configs!(config_data, file_config)
        catch e
            @warn "Error loading default configuration file: $e"
        end
    end

    # Override with environment variables
    override_from_env!(config_data)

    return Configuration(config_data)
end

"""
    merge_configs!(target, source)

Recursively merge source configuration into target.
"""
function merge_configs!(target::Dict, source::Dict)
    for (key, value) in source
        if haskey(target, key) && target[key] isa Dict && value isa Dict
            merge_configs!(target[key], value)
        else
            target[key] = value
        end
    end
end

"""
    override_from_env!(config)

Override configuration values from environment variables.
Environment variables should be in the format CUTEPANEL_SECTION_KEY.
"""
function override_from_env!(config::Dict)
    for (env_key, env_value) in ENV
        if startswith(env_key, "CUTEPANEL_")
            parts = split(env_key[9:end], "_")
            if length(parts) >= 2
                section = lowercase(parts[1])
                key = lowercase(join(parts[2:end], "_"))

                if haskey(config, section) && haskey(config[section], key)
                    # Convert value to the appropriate type
                    original_value = config[section][key]
                    if original_value isa Bool
                        config[section][key] = lowercase(env_value) in ["true", "1", "yes"]
                    elseif original_value isa Integer
                        config[section][key] = parse(Int, env_value)
                    elseif original_value isa AbstractFloat
                        config[section][key] = parse(Float64, env_value)
                    else
                        config[section][key] = env_value
                    end
                end
            end
        end
    end
end

"""
    get_value(config::Configuration, path::String, default=nothing)

Get a configuration value by path (e.g., "server.port").
Returns the default value if the path doesn't exist.
"""
function get_value(config::Configuration, path::String, default=nothing)
    parts = split(path, ".")
    current = config

    for part in parts
        if !haskey(current, Symbol(part))
            return default
        end
        current = getproperty(current, Symbol(part))
    end

    return current
end

end # module
