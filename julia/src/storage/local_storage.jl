"""
LocalStorage.jl - Local file system storage provider for CutePanel.

Uses SQLite for metadata and stores data as JSON strings.
Supports optional (placeholder) encryption and compression.
"""
module LocalStorage

using SQLite, JSON3, Dates, Logging # JSON3 for consistency
using ..StorageInterface # From the file created in the same directory

export LocalStorageProvider # Export the concrete provider type

# Define the local storage provider
mutable struct LocalStorageProvider <: StorageInterface.StorageProvider
    db_path::String
    db::Union{SQLite.DB, Nothing} # Made mutable to be set by initialize_provider
    # encryption_key::Union{String, Nothing} # Placeholder, real encryption needs a secure key
    # compression_enabled::Bool # Placeholder

    # Constructor with default values, db will be Nothing until initialized
    function LocalStorageProvider(db_path::String;
                                 # encryption_key::Union{String, Nothing}=nothing,
                                 # compression_enabled::Bool=true
                                 )
        new(db_path, nothing) #, encryption_key, compression_enabled)
    end
end

"""
    initialize_provider(provider::LocalStorageProvider; config::Dict=Dict())

Initialize the local storage provider. `config` can override `db_path`.
"""
function StorageInterface.initialize_provider(provider::LocalStorageProvider; config::Dict=Dict())
    # Allow db_path to be overridden by config passed to initialize_provider
    # This is useful if the main Storage.jl module passes down app-level config.
    actual_db_path = get(config, "db_path", provider.db_path)
    # encryption_key = get(config, "encryption_key", provider.encryption_key) # If these were fields
    # compression = get(config, "compression_enabled", provider.compression_enabled)

    try
        db_dir = dirname(actual_db_path)
        if !isdir(db_dir)
            mkpath(db_dir)
            @info "LocalStorage: Created storage directory: $db_dir"
        end

        db_conn = SQLite.DB(actual_db_path)

        SQLite.execute(db_conn, """
            CREATE TABLE IF NOT EXISTS storage_metadata (
                key TEXT PRIMARY KEY,
                data_value TEXT, -- Changed from 'value' to 'data_value' to avoid SQL keyword clash
                metadata TEXT,
                created_at TEXT,
                updated_at TEXT
            )
        """)
        
        # Update the provider instance with the live DB connection and actual path
        provider.db = db_conn
        # provider.db_path = actual_db_path # If db_path itself should be mutable in provider
        
        @info "LocalStorageProvider initialized with DB at: $actual_db_path"
        return provider # Return the initialized (or modified) provider
    catch e
        @error "Error initializing local storage at $actual_db_path" exception=(e, catch_backtrace())
        rethrow(e)
    end
end

"""
    save(provider::LocalStorageProvider, key::String, data::Any; metadata::Dict{String, Any}=Dict{String, Any}())
"""
function StorageInterface.save(provider::LocalStorageProvider, key::String, data::Any; metadata::Dict{String, Any}=Dict{String, Any}())
    if isnothing(provider.db)
        error("LocalStorageProvider not initialized. Call initialize_provider first.")
    end

    try
        data_json = JSON3.write(data) # Use JSON3
        metadata_json = JSON3.write(metadata)

        # TODO: Implement real encryption if provider.encryption_key is set
        # TODO: Implement real compression if provider.compression_enabled is true

        timestamp = string(now(Dates.UTC)) # Use UTC for consistency

        # Upsert logic: Insert or Replace
        SQLite.execute(provider.db, """
            INSERT INTO storage_metadata (key, data_value, metadata, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                data_value = excluded.data_value,
                metadata = excluded.metadata,
                updated_at = excluded.updated_at;
        """, [key, data_json, metadata_json, timestamp, timestamp])
        
        return true
    catch e
        @error "Error saving data to local storage for key '$key'" exception=(e, catch_backtrace())
        return false # Or rethrow(e) depending on desired error handling
    end
end

"""
    load(provider::LocalStorageProvider, key::String)::Union{Nothing, Tuple{Any, Dict{String, Any}}}
"""
function StorageInterface.load(provider::LocalStorageProvider, key::String)::Union{Nothing, Tuple{Any, Dict{String, Any}}}
    if isnothing(provider.db)
        error("LocalStorageProvider not initialized.")
    end

    try
        stmt = SQLite.Stmt(provider.db, "SELECT data_value, metadata FROM storage_metadata WHERE key = ?")
        results = DBInterface.execute(stmt, [key])
        
        row = nothing
        for r in results # Iterate to get the first (and only expected) row
            row = r
            break
        end

        if isnothing(row)
            return nothing # Key not found
        end

        data_json = row.data_value
        metadata_json = row.metadata

        # TODO: Implement real decompression if provider.compression_enabled
        # TODO: Implement real decryption if provider.encryption_key

        # Use JSON3.read for parsing
        parsed_data = JSON3.read(data_json) 
        parsed_metadata = JSON3.read(metadata_json, Dict{String,Any}) # Ensure metadata is Dict

        return (parsed_data, parsed_metadata)
    catch e
        @error "Error loading data from local storage for key '$key'" exception=(e, catch_backtrace())
        return nothing # Or rethrow(e)
    end
end

"""
    delete_key(provider::LocalStorageProvider, key::String)::Bool
"""
function StorageInterface.delete_key(provider::LocalStorageProvider, key::String)::Bool
    if isnothing(provider.db)
        error("LocalStorageProvider not initialized.")
    end
    try
        SQLite.execute(provider.db, "DELETE FROM storage_metadata WHERE key = ?", [key])
        # SQLite.changes(provider.db) can tell you if a row was actually deleted.
        return true # Assume success even if key didn't exist, as per typical delete semantics
    catch e
        @error "Error deleting data from local storage for key '$key'" exception=(e, catch_backtrace())
        return false
    end
end

"""
    list_keys(provider::LocalStorageProvider, prefix::String="")::Vector{String}
"""
function StorageInterface.list_keys(provider::LocalStorageProvider, prefix::String="")::Vector{String}
    if isnothing(provider.db)
        error("LocalStorageProvider not initialized.")
    end
    try
        query = "SELECT key FROM storage_metadata"
        params = []
        if !isempty(prefix)
            query *= " WHERE key LIKE ?"
            push!(params, prefix * "%")
        end
        
        results = SQLite.DBInterface.execute(provider.db, query, params)
        return [String(row.key) for row in results]
    catch e
        @error "Error listing keys from local storage with prefix '$prefix'" exception=(e, catch_backtrace())
        return String[]
    end
end

# exists is inherited from StorageInterface (default uses load)

end # module LocalStorage
