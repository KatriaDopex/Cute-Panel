"""
    Storage interface for CutePanel

This module defines the interface for storage providers in CutePanel.
All concrete storage providers should implement these methods.
"""
module StorageInterface

export StorageProvider, initialize_provider, save, load, delete_key, list_keys, exists

"""
    StorageProvider

Abstract type for all storage providers.
"""
abstract type StorageProvider end

"""
    initialize_provider(provider::StorageProvider; config::Dict=Dict())

Initialize the storage provider. This might involve setting up connections,
creating directories, or initializing databases.
The `config` dictionary can hold provider-specific settings.
Should return the initialized provider or throw an error on failure.
"""
function initialize_provider(provider::StorageProvider; config::Dict=Dict())
    error("`initialize_provider` not implemented for $(typeof(provider))")
end

"""
    save(provider::StorageProvider, key::String, data::Any; metadata::Dict{String, Any}=Dict{String, Any}())

Save data to storage with the given key and optional metadata.
Returns `true` on success, `false` or throws error on failure.
"""
function save(provider::StorageProvider, key::String, data::Any; metadata::Dict{String, Any}=Dict{String, Any}())
    error("`save` not implemented for $(typeof(provider))")
end

"""
    load(provider::StorageProvider, key::String)::Union{Nothing, Tuple{Any, Dict{String, Any}}}

Load data and its metadata from storage using the key.
Returns `nothing` if the key is not found.
Returns a tuple `(data, metadata)` if found.
"""
function load(provider::StorageProvider, key::String)::Union{Nothing, Tuple{Any, Dict{String, Any}}}
    error("`load` not implemented for $(typeof(provider))")
end

"""
    delete_key(provider::StorageProvider, key::String)::Bool

Delete data from storage associated with the key.
Returns `true` if deletion was successful or key didn't exist, `false` on failure.
"""
function delete_key(provider::StorageProvider, key::String)::Bool # Renamed from delete to delete_key to avoid conflict with Base.delete!
    error("`delete_key` not implemented for $(typeof(provider))")
end

"""
    list_keys(provider::StorageProvider, prefix::String="")::Vector{String}

List keys in storage, optionally filtered by a prefix.
"""
function list_keys(provider::StorageProvider, prefix::String="")::Vector{String} # Renamed from list to list_keys
    error("`list_keys` not implemented for $(typeof(provider))")
end

"""
    exists(provider::StorageProvider, key::String)::Bool

Check if a key exists in the storage.
"""
function exists(provider::StorageProvider, key::String)::Bool
    # Default implementation using load, can be overridden for efficiency
    return !isnothing(load(provider, key))
end

end # module StorageInterface
