"""
Storage.jl - Main module for pluggable storage solutions in CutePanel.

Provides a unified interface to various storage backends like local file system (SQLite-backed),
Arweave, and potentially others for document/vector storage.
"""
module Storage

using Logging, Dates, JSON3 # JSON3 for consistency if used by providers
# Base path for StorageInterface and concrete providers
include("storage_interface.jl")
using .StorageInterface
# Export main interface types and functions
export StorageProvider, initialize_provider, save, load, delete_key, list_keys, exists 

# Include concrete provider implementations
include("local_storage.jl")
using .LocalStorage
export LocalStorageProvider # Re-export concrete provider type

# Placeholder for Arweave and Document storage (if they are to be included directly)
# include("arweave_storage.jl")
# using .ArweaveStorage
# export ArweaveStorageProvider

# include("document_storage.jl")
# using .DocumentStorage
# export DocumentStorageProvider, search_documents # search_documents is specific to DocumentStorage

# --- Global Default Provider ---
const DEFAULT_STORAGE_PROVIDER = Ref{Union{StorageProvider, Nothing}}(nothing)
const STORAGE_SYSTEM_INITIALIZED = Ref{Bool}(false)

"""
    initialize_storage_system(; provider_type::Symbol=:local, config::Dict=Dict())

Initializes the storage system with a specific provider and sets it as the default.
This is the main entry point for setting up storage for the application.

# Arguments
- `provider_type::Symbol`: The type of storage provider to initialize (e.g., :local, :arweave).
- `config::Dict`: Configuration dictionary specific to the provider.
                  For :local, might include "db_path".
                  For :arweave, might include "api_url", "wallet_file".

# Returns
- The initialized `StorageProvider` instance, or `nothing` on failure.
"""
function initialize_storage_system(; provider_type::Symbol=:local, config::Dict=Dict())::Union{StorageProvider, Nothing}
    if STORAGE_SYSTEM_INITIALIZED[] && !isnothing(DEFAULT_STORAGE_PROVIDER[])
        @warn "Storage system already initialized with provider: $(typeof(DEFAULT_STORAGE_PROVIDER[])). Re-initializing with $provider_type."
        # Optionally, add logic to tear down the old provider if necessary
    end

    provider_instance = nothing
    try
        if provider_type == :local
            # db_path for LocalStorageProvider can be passed in config dict
            db_path_val = get(config, "db_path", joinpath(homedir(), ".cutepanel", "default_cutepanel_storage.sqlite"))
            provider_instance = LocalStorageProvider(db_path_val)
            initialize_provider(provider_instance; config=config) # Pass full config for any other options
        # elseif provider_type == :arweave
        #     provider_instance = ArweaveStorageProvider() # Constructor might take specific args from config
        #     initialize_provider(provider_instance; config=config)
        # elseif provider_type == :document
        #     # DocumentStorageProvider might wrap another provider, e.g., local or Arweave
        #     base_provider_type = get(config, "base_provider_type", :local)
        #     base_config = get(config, "base_provider_config", Dict())
        #     base_provider = initialize_storage_system(provider_type=base_provider_type, config=base_config) # Recursive call
        #     if isnothing(base_provider) error("Failed to initialize base provider for DocumentStorage.") end
        #     provider_instance = DocumentStorageProvider(base_provider)
        #     initialize_provider(provider_instance; config=config)
        else
            error("Unsupported storage provider type: $provider_type")
        end

        if !isnothing(provider_instance)
            DEFAULT_STORAGE_PROVIDER[] = provider_instance
            STORAGE_SYSTEM_INITIALIZED[] = true
            @info "Storage system initialized successfully with default provider: $provider_type."
        else
            @error "Failed to initialize provider: $provider_type. Storage system not fully initialized."
            STORAGE_SYSTEM_INITIALIZED[] = false # Ensure it's marked as not ready
        end
    catch e
        @error "Error initializing storage system with provider $provider_type" exception=(e, catch_backtrace())
        DEFAULT_STORAGE_PROVIDER[] = nothing
        STORAGE_SYSTEM_INITIALIZED[] = false
        # rethrow(e) # Or handle more gracefully
    end
    return DEFAULT_STORAGE_PROVIDER[]
end

"""
    get_default_storage_provider()::StorageProvider

Retrieves the currently configured default storage provider.
Errors if the system has not been initialized.
"""
function get_default_storage_provider()::StorageProvider
    if !STORAGE_SYSTEM_INITIALIZED[] || isnothing(DEFAULT_STORAGE_PROVIDER[])
        error("Storage system has not been initialized or default provider is not set. Call initialize_storage_system() first.")
    end
    return DEFAULT_STORAGE_PROVIDER[]
end

# --- Convenience functions using the default provider ---
# These mirror the StorageInterface but operate on the global default.

function save_default(key::String, data::Any; metadata::Dict{String, Any}=Dict{String, Any}())
    provider = get_default_storage_provider()
    return save(provider, key, data; metadata=metadata)
end

function load_default(key::String)::Union{Nothing, Tuple{Any, Dict{String, Any}}}
    provider = get_default_storage_provider()
    return load(provider, key)
end

function delete_key_default(key::String)::Bool
    provider = get_default_storage_provider()
    return delete_key(provider, key)
end

function list_keys_default(prefix::String="")::Vector{String}
    provider = get_default_storage_provider()
    return list_keys(provider, prefix)
end

function exists_default(key::String)::Bool
    provider = get_default_storage_provider()
    return exists(provider, key)
end

# TODO: Add search_default if DocumentStorageProvider is integrated and set as default.
# function search_default(query::String; limit::Int=10, offset::Int=0)
#     provider = get_default_storage_provider()
#     if isa(provider, DocumentStorageProvider)
#         return search_documents(provider, query; limit=limit, offset=offset)
#     else
#         error("Default storage provider does not support search. It's a $(typeof(provider)).")
#     end
# end


function __init__()
    # Default initialization can be done here, or left to the main application startup.
    # For example, to ensure a local provider is always available if no other config:
    # if !STORAGE_SYSTEM_INITIALIZED[]
    #     @info "Storage.jl __init__: Auto-initializing with default :local provider."
    #     initialize_storage_system(provider_type=:local) 
    #     # This path might need to come from a global app config if available at this stage
    # end
    @info "Storage.jl module loaded. Call initialize_storage_system() to set up a provider."
end

end # module Storage
