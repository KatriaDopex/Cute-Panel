# julia/src/api/PriceFeedHandlers.jl
module PriceFeedHandlers

using HTTP, Logging, Dates # Added Dates
using ..Utils # For standardized responses
import ..framework.CutePanelFramework.PriceFeed
import ..framework.CutePanelFramework.PriceFeedBase

# In a real application, you'd have a way to manage configured price feed instances.
# For now, we might create them on-the-fly based on request or use a default.
# This is a simplified approach. A better way would be to pre-configure instances.
const DEFAULT_PRICE_FEEDS = Dict{String, PriceFeedBase.AbstractPriceFeed}()
const DEFAULT_PRICE_FEEDS_LOCK = ReentrantLock()

function _get_or_create_feed_instance(provider_name::String, params::Dict)::Union{PriceFeedBase.AbstractPriceFeed, Nothing}
    # This is a placeholder for a more robust feed instance management.
    # It creates a new instance on every call if not cached, which is not ideal for production.
    # A better system would pre-configure feeds or have a more persistent cache.
    
    lock(DEFAULT_PRICE_FEEDS_LOCK) do
        # Construct a more specific cache key based on relevant config parameters
        # Relevant params might include chain_id, rpc_url (for chainlink), api_key (for others)
        # This helps differentiate instances of the same provider type with different configs.
        
        # Extract key parameters for cache key generation
        # Ensure consistent types for cache key components (e.g., string for chain_id)
        chain_id_str = string(get(params, "chain_id", provider_name == "chainlink" ? "1" : "default_chain"))
        api_key_param = get(params, "api_key", "")
        rpc_url_param = get(params, "rpc_url", "") # Relevant for chainlink or custom RPC-based feeds
        base_url_param = get(params, "base_url", "") # Relevant for HTTP API based feeds

        # Create a composite cache key. Hashing could be used for very long/complex keys.
        # For now, a delimited string.
        cache_key_parts = [
            lowercase(provider_name),
            "chain:$(chain_id_str)",
            # Only include api_key/rpc_url/base_url in key if they are non-empty,
            # as they might not be applicable to all providers or might use defaults.
            # However, if they *are* provided, they define a distinct instance.
        ]
        !isempty(api_key_param) && push!(cache_key_parts, "apikeyhash:" * string(hash(api_key_param))) # Hash API key
        !isempty(rpc_url_param) && push!(cache_key_parts, "rpcurl:" * rpc_url_param)
        !isempty(base_url_param) && push!(cache_key_parts, "baseurl:" * base_url_param)
        
        cache_key = join(cache_key_parts, "_")

        if haskey(DEFAULT_PRICE_FEEDS, cache_key) && !isnothing(DEFAULT_PRICE_FEEDS[cache_key])
            # TODO: A deeper check could compare all `params` with the cached instance's actual config.
            # For now, if key matches, assume config matches. This relies on a good cache_key.
            @debug "Returning cached price feed instance for key: $cache_key"
            return DEFAULT_PRICE_FEEDS[cache_key]
        end

        @debug "Creating new price feed instance for key: $cache_key"
        # Default config parameters if not provided in request
        # These should ideally come from a secure application configuration file for production.
        
        # Use extracted params for consistency, falling back to defaults if they were empty
        final_rpc_url = !isempty(rpc_url_param) ? rpc_url_param : (provider_name == "chainlink" ? "https://mainnet.infura.io/v3/YOUR_INFURA_KEY" : "")
        final_chain_id_parsed = tryparse(Int, chain_id_str)
        final_chain_id = !isnothing(final_chain_id_parsed) ? final_chain_id_parsed : (provider_name == "chainlink" ? 1 : nothing)

        config_name_param = get(params, "config_name", provider_name * "_" * chain_id_str) # More unique default name

        config_dict = Dict{Symbol, Any}(
            :name => config_name_param, 
            :api_key => api_key_param, # Already extracted
            :base_url => base_url_param, # Already extracted
            :rpc_url => final_rpc_url,
            :chain_id => final_chain_id
        )
        
        # Handle cache_duration separately as it's not part of the cache key logic directly
        cache_duration_param = get(params, "cache_duration", "60") # Default to string "60"
        parsed_cache_duration = tryparse(Int, string(cache_duration_param)) # Ensure it's string before parse
        config_dict[:cache_duration] = isnothing(parsed_cache_duration) ? 60 : parsed_cache_duration


        # Remove keys with empty string values if the PriceFeedConfig constructor handles them as optional,
        # but ensure :name is always present. Also, chain_id can be nothing for some providers.
        # rpc_url, api_key, base_url might be legitimately empty if not used by a provider.
        final_config_params = Dict{Symbol, Any}()
        for (k,v) in config_dict
            if k == :name || k == :cache_duration # Always include these
                final_config_params[k] = v
            elseif k == :chain_id # Include if not nothing
                 !isnothing(v) && (final_config_params[k] = v)
            elseif isa(v, String) && !isempty(v) # Include non-empty strings
                final_config_params[k] = v
            elseif !isa(v, String) && !isnothing(v) # Include other non-nothing, non-string types
                final_config_params[k] = v
            end
        end
        
        try
            config_obj = PriceFeedBase.PriceFeedConfig(;final_config_params...)
            instance = PriceFeed.create_price_feed(provider_name, config_obj)
            DEFAULT_PRICE_FEEDS[cache_key] = instance
            @info "Created and cached new price feed instance for $provider_name with key $cache_key"
            return instance
        catch e
            @error "Failed to create price feed instance for $provider_name with key $cache_key" error=e params=final_config_params
            return nothing
        end
    end
end


function list_providers_handler(req::HTTP.Request)
    try
        providers = PriceFeed.list_available_price_feed_providers()
        return Utils.json_response(Dict("available_providers" => providers))
    catch e
        @error "Error in list_providers_handler" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to list price feed providers", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_feed_info_handler(req::HTTP.Request, provider_name::String)
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target)))) # Convert to Dict{String,String}
    
    feed_instance = _get_or_create_feed_instance(provider_name, query_params)
    if isnothing(feed_instance)
        return Utils.error_response("Price feed provider '$provider_name' not found or failed to initialize.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("provider_name"=>provider_name))
    end
    
    try
        info = PriceFeedBase.get_price_feed_info(feed_instance)
        return Utils.json_response(info)
    catch e
        @error "Error getting info for feed $provider_name" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to get info for price feed '$provider_name'", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function list_supported_pairs_handler(req::HTTP.Request, provider_name::String)
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    feed_instance = _get_or_create_feed_instance(provider_name, query_params)
    if isnothing(feed_instance)
        return Utils.error_response("Price feed provider '$provider_name' not found or failed to initialize.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("provider_name"=>provider_name))
    end

    try
        pairs_tuples = PriceFeedBase.list_supported_pairs(feed_instance)
        formatted_pairs = ["$(p[1])/$(p[2])" for p in pairs_tuples]
        return Utils.json_response(Dict("provider_name" => provider_name, "supported_pairs" => formatted_pairs))
    catch e
        @error "Error listing pairs for feed $provider_name" exception=(e, catch_backtrace())
        return Utils.error_response("Failed to list supported pairs for '$provider_name'", 500, error_code=Utils.ERROR_CODE_SERVER_ERROR)
    end
end

function get_latest_price_handler(req::HTTP.Request, provider_name::String)
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    base_asset = get(query_params, "base_asset", "")
    quote_asset = get(query_params, "quote_asset", "")

    if isempty(base_asset) || isempty(quote_asset)
        return Utils.error_response("Missing 'base_asset' or 'quote_asset' query parameters.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT, details=Dict("fields"=>["base_asset", "quote_asset"]))
    end

    feed_instance = _get_or_create_feed_instance(provider_name, query_params)
    if isnothing(feed_instance)
        return Utils.error_response("Price feed provider '$provider_name' not found or failed to initialize.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("provider_name"=>provider_name))
    end

    try
        price_point = PriceFeedBase.get_latest_price(feed_instance, base_asset, quote_asset)
        result = Dict(
            "provider" => provider_name,
            "base_asset" => uppercase(base_asset),
            "quote_asset" => uppercase(quote_asset),
            "timestamp" => string(price_point.timestamp),
            "price" => price_point.price,
            "volume" => price_point.volume,
            "open" => price_point.open, # field name in PricePoint struct
            "high" => price_point.high, # field name in PricePoint struct
            "low" => price_point.low,   # field name in PricePoint struct
            "close" => price_point.close  # field name in PricePoint struct
        )
        return Utils.json_response(result)
    catch e
        @error "Error getting latest price for $base_asset/$quote_asset from $provider_name" exception=(e, catch_backtrace())
        if occursin("not found in registry", string(e)) || occursin("Unsupported pair", string(e)) || occursin("No Chainlink feed found", string(e))
             return Utils.error_response("Pair $base_asset/$quote_asset not supported by $provider_name or not found.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND, details=Dict("pair"=>"$base_asset/$quote_asset"))
        end
        return Utils.error_response("Failed to get latest price for $base_asset/$quote_asset from $provider_name: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR)
    end
end

function get_historical_prices_handler(req::HTTP.Request, provider_name::String)
    query_params = Dict(pairs(HTTP.queryparams(HTTP.URI(req.target))))
    base_asset = get(query_params, "base_asset", "")
    quote_asset = get(query_params, "quote_asset", "")
    interval = get(query_params, "interval", "1d")
    limit_str = get(query_params, "limit", "100")
    start_time_str = get(query_params, "start_time", nothing) # ISO8601 string
    end_time_str = get(query_params, "end_time", nothing)     # ISO8601 string

    if isempty(base_asset) || isempty(quote_asset)
        return Utils.error_response("Missing 'base_asset' or 'quote_asset' query parameters.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    limit = tryparse(Int, limit_str)
    if isnothing(limit) || limit <= 0
        return Utils.error_response("Invalid 'limit' parameter. Must be a positive integer.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    start_time_dt = isnothing(start_time_str) ? nothing : try DateTime(start_time_str, ISODateTimeFormat) catch; nothing end
    end_time_dt = isnothing(end_time_str) ? nothing : try DateTime(end_time_str, ISODateTimeFormat) catch; nothing end

    if !isnothing(start_time_str) && isnothing(start_time_dt)
        return Utils.error_response("Invalid 'start_time' format. Use ISO8601.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end
    if !isnothing(end_time_str) && isnothing(end_time_dt)
        return Utils.error_response("Invalid 'end_time' format. Use ISO8601.", 400, error_code=Utils.ERROR_CODE_INVALID_INPUT)
    end

    feed_instance = _get_or_create_feed_instance(provider_name, query_params)
    if isnothing(feed_instance)
        return Utils.error_response("Price feed provider '$provider_name' not found or failed to initialize.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND)
    end

    try
        price_data_obj = PriceFeedBase.get_historical_prices(feed_instance, base_asset, quote_asset; 
                                                            interval=interval, limit=limit, 
                                                            start_time=start_time_dt, end_time=end_time_dt)
        
        # Convert PriceData object to a JSON-friendly Dict
        points_list = [
            Dict("timestamp"=>string(p.timestamp), "price"=>p.price, "volume"=>p.volume, 
                 "open"=>p.open, "high"=>p.high, "low"=>p.low, "close"=>p.close) 
            for p in price_data_obj.points
        ]
        result = Dict(
            "provider" => provider_name,
            "base_asset" => price_data_obj.base_asset,
            "quote_asset" => price_data_obj.quote_asset,
            "source_name" => price_data_obj.source_name,
            "interval" => price_data_obj.interval,
            "points" => points_list
        )
        return Utils.json_response(result)
    catch e
        @error "Error getting historical prices for $base_asset/$quote_asset from $provider_name" exception=(e, catch_backtrace())
        if occursin("not found in registry", string(e)) || occursin("Unsupported pair", string(e))
             return Utils.error_response("Pair $base_asset/$quote_asset not supported by $provider_name or not found.", 404, error_code=Utils.ERROR_CODE_NOT_FOUND)
        end
        return Utils.error_response("Failed to get historical prices: $(sprint(showerror, e))", 500, error_code=Utils.ERROR_CODE_EXTERNAL_SERVICE_ERROR)
    end
end

end # module PriceFeedHandlers
